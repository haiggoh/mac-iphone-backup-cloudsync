import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("BackupArchiver sourceSizeBytes")
struct BackupArchiverSourceSizeTests {
    let archiver = BackupArchiver(configuration: .testConfiguration)
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourceSizeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test("counts actual file bytes for flat directory")
    func countsActualBytesFlat() throws {
        // Create test files with known sizes
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let data = Data(count: 10_000) // 10 KB
        try data.write(to: file1)
        try data.write(to: file2)

        // Native implementation counts actual file bytes
        let native = try archiver.sourceSizeBytes(of: tempDir)
        // Should equal total actual bytes (2 * 10_000 = 20_000)
        #expect(native == 20_000)
    }

    @Test("counts actual file bytes for nested directory")
    func countsActualBytesNested() throws {
        let subdir = tempDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file1 = subdir.appendingPathComponent("nested.txt")
        let data = Data(count: 5_000)
        try data.write(to: file1)

        let native = try archiver.sourceSizeBytes(of: tempDir)
        // Should equal actual bytes (5_000)
        #expect(native == 5_000)
    }

    @Test("skips symlinks")
    func skipsSymlinks() throws {
        let target = tempDir.appendingPathComponent("target.txt")
        let data = Data(count: 100_000)
        try data.write(to: target)

        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let native = try archiver.sourceSizeBytes(of: tempDir)
        // Should count only the target file (100_000), not the symlink
        #expect(native == 100_000)
    }

    @Test("throws CancellationError on cancel")
    func throwsOnCancel() async throws {
        // Create large directory tree
        let largeDir = tempDir.appendingPathComponent("large")
        try FileManager.default.createDirectory(at: largeDir, withIntermediateDirectories: true)
        for i in 0..<10_000 {
            let file = largeDir.appendingPathComponent("file\(i).txt")
            try Data(count: 1_000).write(to: file)
        }

        let archiver = BackupArchiver(configuration: .testConfiguration)
        await #expect(throws: CancellationError.self) {
            Task {
                // Cancel immediately after starting
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                archiver.cancel()
            }
            try archiver.sourceSizeBytes(of: largeDir)
        }
    }
}

private func duOutput(_ url: URL) throws -> Int64 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    task.arguments = ["-sk", url.path]
    let output = Pipe()
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    let firstField = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
    return (Int64(firstField) ?? 0) * 1024
}

extension Configuration {
    static var testConfiguration: Configuration {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return Configuration(
            bundleIdentifier: "test",
            backupRoot: tempDir,
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }
}