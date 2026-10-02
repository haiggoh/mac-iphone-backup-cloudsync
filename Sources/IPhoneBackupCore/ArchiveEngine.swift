import Foundation

/// Protocol for archive backends. Allows swapping ditto for AppleArchive in the future.
public protocol ArchiveEngine: Sendable {
    /// Creates an archive from a source directory.
    /// - Parameters:
    ///   - sourceDirectory: The directory to archive (will be the root inside the archive)
    ///   - destinationDirectory: Where to write the archive file
    ///   - archiveName: Name of the archive file (e.g., "backup.zip")
    /// - Returns: URL of the created archive
    func archive(
        sourceDirectory: URL,
        destinationDirectory: URL,
        archiveName: String
    ) async throws -> URL
}

/// Default implementation using system `ditto` (zip64 format).
public final class DittoArchiveEngine: ArchiveEngine, @unchecked Sendable {
    private let configuration: Configuration
    private let fileManager: FileManager

    public init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func archive(
        sourceDirectory: URL,
        destinationDirectory: URL,
        archiveName: String
    ) async throws -> URL {
        let outputURL = destinationDirectory.appendingPathComponent(archiveName)

        // Clean up any existing
        try? fileManager.removeItem(at: outputURL)

        let logURL = configuration.stagingRoot
            .appendingPathComponent("ditto-\(UUID().uuidString).log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw ArchiveError.logCreationFailed
        }
        defer {
            try? logHandle.close()
            try? fileManager.removeItem(at: logURL)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            sourceDirectory.path, outputURL.path
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = logHandle

        do {
            try task.run()
        } catch {
            throw ArchiveError.toolStartFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let stderr = Self.tail(of: logURL, lines: 4, fileManager: self.fileManager)
                    continuation.resume(throwing: ArchiveError.toolFailed(
                        exitCode: process.terminationStatus, stderrTail: stderr))
                }
            }
        }

        // Verify output
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ArchiveError.outputMissing
        }

        return outputURL
    }

    private static func tail(of url: URL, lines: Int, fileManager: FileManager) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }
}

public enum ArchiveError: Error {
    case logCreationFailed
    case toolStartFailed
    case toolFailed(exitCode: Int32, stderrTail: String)
    case outputMissing
}