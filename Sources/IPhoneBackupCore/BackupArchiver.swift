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

    public init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Cancels a running archive. Safe to call from another thread.
    public func cancel() {
        process?.terminate()
    }

    /// Measures the source with `du`, which is slow on a few hundred thousand
    /// files and so belongs off any interactive path.
    public func sourceSizeBytes(of directory: URL) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", directory.path]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return 0 }
        // Read before waiting: a full pipe buffer with nobody draining it would
        // deadlock, which is a mistake this codebase has made before.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        let firstField = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        return (Int64(firstField) ?? 0) * 1024
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
        isCancelled: @escaping () -> Bool = { false }
    ) -> Result<ArchiveOutcome, RunFailure> {

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

        let staged = configuration.stagingRoot.appendingPathComponent(archiveFilename)
        try? fileManager.removeItem(at: staged)

        // ditto's stderr goes to a file, never to an unread pipe: it can emit a
        // great many warnings on a large tree and a full pipe would deadlock.
        let logURL = configuration.stagingRoot
            .appendingPathComponent("ditto-\(UUID().uuidString).log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return .failure(.stagingUnavailable("could not create the archive log"))
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -c -k writes a genuine zip64. `tar -czf` with a .zip name — the original
        // mistake — writes a gzip stream no zip reader can open.
        task.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            candidate.directoryURL.path, staged.path,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = logHandle

        let started = Date()
        do {
            try task.run()
        } catch {
            try? logHandle.close()
            try? fileManager.removeItem(at: logURL)
            return .failure(.archiveToolFailed(
                exitCode: -1, stderrTail: "could not start ditto: \(error)"))
        }
        process = task

        // Prevents *idle* sleep for the duration. It cannot prevent sleep from the
        // lid being closed — no assertion can — but that is survivable: with
        // hibernatemode 3 the machine keeps RAM powered, so ditto is suspended
        // rather than killed and resumes on wake with its file handle intact.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "Archiving an iPhone backup"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let expected = Double(sourceBytes) * Self.expectedCompressionRatio

        // Throughput is measured over a recent window rather than since the start,
        // and a gap far longer than the poll interval is treated as the machine
        // having slept. Dividing by total wall-clock across a sleep would report a
        // collapsed transfer rate and a wildly inflated time remaining for a job
        // that is in fact running at full speed.
        let sleepGapThreshold: TimeInterval = 15
        var windowStart = Date()
        var windowStartBytes: Int64 = 0
        var lastSample = Date()
        var activeElapsed: TimeInterval = 0

        while task.isRunning {
            Thread.sleep(forTimeInterval: 1.5)
            if isCancelled() { task.terminate() }
            guard let attributes = try? fileManager.attributesOfItem(atPath: staged.path),
                  let written = (attributes[.size] as? NSNumber)?.int64Value
            else { continue }

            let now = Date()
            let sinceLastSample = now.timeIntervalSince(lastSample)

            if sinceLastSample > sleepGapThreshold {
                // Discard the gap: restart the measurement window and do not count
                // the slept time as elapsed.
                windowStart = now
                windowStartBytes = written
            } else {
                activeElapsed += sinceLastSample
            }
            lastSample = now

            let windowSeconds = now.timeIntervalSince(windowStart)
            let windowBytes = written - windowStartBytes
            let rate = windowSeconds >= 3 && windowBytes > 0
                ? Double(windowBytes) / windowSeconds
                : 0

            var remaining: TimeInterval?
            if rate > 0 {
                let seconds = (expected - Double(written)) / rate
                // Reject absurd estimates rather than show "3 days left" because a
                // sample happened to land during a slow patch.
                if seconds > 0, seconds < 86_400 { remaining = seconds }
            }

            progress?(ArchiveProgress(
                bytesWritten: written,
                expectedBytes: Int64(expected),
                elapsed: activeElapsed,
                bytesPerSecond: rate,
                estimatedRemaining: remaining
            ))
        }

        task.waitUntilExit()
        try? logHandle.close()
        process = nil

        let stderrTail = Self.tail(of: logURL, lines: 4, fileManager: fileManager)
        try? fileManager.removeItem(at: logURL)

        if isCancelled() {
            try? fileManager.removeItem(at: staged)
            return .failure(.archiveToolFailed(exitCode: task.terminationStatus,
                                               stderrTail: "cancelled"))
        }

        guard task.terminationStatus == 0 else {
            // A partial archive is worse than none: it looks like a backup.
            try? fileManager.removeItem(at: staged)
            return .failure(.archiveToolFailed(
                exitCode: task.terminationStatus, stderrTail: stderrTail))
        }

        let size = (try? fileManager.attributesOfItem(atPath: staged.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size >= Self.minimumPlausibleArchiveBytes else {
            try? fileManager.removeItem(at: staged)
            return .failure(.archiveImplausiblySmall(bytes: size))
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                // Only reachable under .replace, i.e. after explicit confirmation.
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: staged, to: finalURL)
        } catch {
            // The archive is intact — say where, so the work is not lost.
            return .failure(.finalMoveFailed(
                String(describing: error), stagedArchivePath: staged.path))
        }

        return .success(ArchiveOutcome(
            finalURL: finalURL,
            sizeBytes: size,
            duration: Date().timeIntervalSince(started)
        ))
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
