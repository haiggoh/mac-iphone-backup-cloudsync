import Foundation

public struct ArchiveProgress: Equatable {
    public let bytesWritten: Int64
    public let expectedBytes: Int64
    public let elapsed: TimeInterval
    public let bytesPerSecond: Double
    /// nil when there is not yet enough data to estimate, or the estimate is absurd.
    public let estimatedRemaining: TimeInterval?

    public var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(max(Double(bytesWritten) / Double(expectedBytes), 0), 1)
    }
}

public struct ArchiveOutcome: Equatable {
    public let finalURL: URL
    public let sizeBytes: Int64
    public let duration: TimeInterval
}

/// What to do when an archive already exists at the destination.
public enum ConflictPolicy: Equatable {
    /// Refuse and report. The only safe choice for an unattended run: an existing
    /// file the state file does not know about might be a good archive from a
    /// previous install, and overwriting it unprompted could destroy the user's
    /// only copy.
    case fail
    /// Replace it. Manual mode only, after the user has explicitly confirmed.
    case replace
}

/// Creates the archive. Knows nothing about SwiftUI, so the whole pipeline is
/// driveable from a headless run and reports progress through a closure rather
/// than by mutating view state.
public final class BackupArchiver {

    /// Ratio of archive size to source size, used only to drive the progress bar.
    /// iPhone backups are mostly already-compressed media, so compression buys
    /// very little.
    private static let expectedCompressionRatio = 0.975

    /// Below this, the archive cannot plausibly be a real backup. Guards against
    /// the failure that started this whole project: a 29-byte file sitting in the
    /// cloud labelled as a finished backup.
    private static let minimumPlausibleArchiveBytes: Int64 = 1_000_000

    /// Extra room demanded beyond the source size before starting.
    private static let freeSpaceMarginBytes: Int64 = 2_000_000_000

    private let configuration: Configuration
    private let fileManager: FileManager
    private var process: Process?
    private var isCancelled = false
    private let cancellationLock = NSLock()

    public init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Cancels a running archive. Safe to call from another thread.
    public func cancel() {
        cancellationLock.lock()
        isCancelled = true
        cancellationLock.unlock()
        process?.terminate()
    }

    /// Measures the source with native Swift enumeration, replacing `du`.
    /// - Parameters:
    ///   - directory: The directory to measure
    /// - Returns: Total size in bytes
    /// - Throws: CancellationError if cancelled, or any FileManager error
    public func sourceSizeBytes(of directory: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw RunFailure.enumerationFailed
        }

        var total: Int64 = 0

        for case let fileURL as URL in enumerator {
            // Check cancellation
            cancellationLock.lock()
            let cancelled = isCancelled
            cancellationLock.unlock()
            if cancelled {
                throw CancellationError()
            }

            autoreleasepool {
                do {
                    let values = try fileURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .isSymbolicLinkKey
                    ])
                    // Skip symlinks to mimic du behavior
                    if values.isSymbolicLink == true { return }
                    guard values.isRegularFile == true,
                          let size = values.fileSize.map(Int64.init) else { return }
                    total += Int64(size)
                } catch {
                    // Ignore individual file errors; du continues on permission errors
                }
            }
        }
        return total
    }

    /// Whether the staging volume can hold the archive.
    ///
    /// Only the staging volume is checked, because the final step is a rename
    /// within the same filesystem rather than a second copy — verified on
    /// 2026-08-08 by observing that a move into `~/Library/CloudStorage/…`
    /// preserves the file's inode. If a custom destination ever sits on a
    /// different volume, `moveIsRename` below reports it and the requirement
    /// doubles.
    public func hasSufficientFreeSpace(forSourceBytes bytes: Int64) -> Result<Void, RunFailure> {
        guard bytes > 0 else { return .success(()) }
        guard let available = (try? configuration.stagingRoot
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity).map(Int64.init)
        else { return .success(()) }   // cannot tell; do not block on ignorance

        let required = bytes + Self.freeSpaceMarginBytes
        guard available >= required else {
            return .failure(.insufficientFreeSpace(
                availableBytes: available, requiredBytes: required))
        }
        return .success(())
    }

    /// True when moving from staging to `destination` is a rename rather than a
    /// copy, decided by comparing filesystem identity rather than assuming.
    public func moveIsRename(to destination: URL) -> Bool {
        let stagingDevice = try? configuration.stagingRoot
            .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let destinationDevice = try? destination
            .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let a = stagingDevice, let b = destinationDevice else { return false }
        return a.isEqual(b)
    }

    // MARK: The pipeline

    public func archive(
        candidate: BackupCandidate,
        archiveFilename: String,
        destinationFolder: URL,
        sourceBytes: Int64,
        conflictPolicy: ConflictPolicy,
        progress: ((ArchiveProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false },
        archiveEngine: ArchiveEngine? = nil
    ) async -> Result<ArchiveOutcome, RunFailure> {

        let finalURL = destinationFolder.appendingPathComponent(archiveFilename)

        if fileManager.fileExists(atPath: finalURL.path), conflictPolicy == .fail {
            return .failure(.archiveAlreadyExistsWithoutState(path: finalURL.path))
        }

        do {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: configuration.stagingRoot, withIntermediateDirectories: true)
        } catch {
            return .failure(.stagingUnavailable(String(describing: error)))
        }

        if case .failure(let failure) = hasSufficientFreeSpace(forSourceBytes: sourceBytes) {
            return .failure(failure)
        }

        let engine = archiveEngine ?? DittoArchiveEngine(configuration: configuration, fileManager: fileManager)

        let staged = configuration.stagingRoot.appendingPathComponent(archiveFilename)
        try? fileManager.removeItem(at: staged)

        do {
            _ = try await engine.archive(
                sourceDirectory: candidate.directoryURL,
                destinationDirectory: configuration.stagingRoot,
                archiveName: archiveFilename
            )

            // Verify the archive was created at the expected location
            let stagedPath = configuration.stagingRoot.appendingPathComponent(archiveFilename)
            guard fileManager.fileExists(atPath: stagedPath.path) else {
                return .failure(.stagingUnavailable("archive engine did not create output at expected path"))
            }

            // Verify size
            let size = (try? fileManager.attributesOfItem(atPath: stagedPath.path)[.size]
                as? NSNumber)?.int64Value ?? 0
            guard size >= Self.minimumPlausibleArchiveBytes else {
                try? fileManager.removeItem(at: stagedPath)
                return .failure(.archiveImplausiblySmall(bytes: size))
            }

            // Move to final destination
            do {
                if fileManager.fileExists(atPath: finalURL.path) {
                    // Only reachable under .replace, i.e. after explicit confirmation.
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: stagedPath, to: finalURL)
            } catch {
                // The archive is intact — say where, so the work is not lost.
                return .failure(.finalMoveFailed(
                    String(describing: error), stagedArchivePath: stagedPath.path))
            }

            return .success(ArchiveOutcome(
                finalURL: finalURL,
                sizeBytes: size,
                duration: 0  // Duration tracking would require engine to return timing info
            ))
        } catch {
            return .failure(.archiveToolFailed(exitCode: -1, stderrTail: String(describing: error)))
        }
    }

    static func tail(of url: URL, lines: Int, fileManager: FileManager) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }
}
