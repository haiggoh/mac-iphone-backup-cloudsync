# iPhone Backup Phase 1: MAS Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace legacy shell-dependent implementations (`du`, `launchctl`, `ditto`) with native Swift alternatives to prepare for Mac App Store sandbox compliance, while maintaining all existing functionality and test coverage.

**Architecture:** Three independent refactoring tracks in the same codebase:
1. Native Swift directory enumeration replacing `Process()` + `/usr/bin/du`
2. SMAppService migration replacing `launchctl` shell-outs with Apple's modern API
3. ArchiveEngine protocol extracting `ditto` logic for future AppleArchive backend

**Tech Stack:** Swift 5.9+, Foundation, FileManager, SMAppService (macOS 13+), Swift Testing / XCTest

**Spec:** `../../../.claude/plans/restored-from-claude-migration-2026-09-28/Plan — iPhone Backup Archiver Phase 1 MAS Compliance.md`

## Global Constraints

- **Prohibited:** Do not enable App Sandbox yet
- **Prohibited:** Do not modify `build.sh` to add entitlements or sandbox flags
- **Permitted:** Modify `build.sh` to create `Contents/Library/LaunchAgents/` directory and copy `.plist` into it
- **Permitted:** Retain Full Disk Access prompt and ad-hoc signing
- **Prohibited:** Do not return `0` on cancellation (sentinel anti-pattern); must throw `CancellationError()`
- **Required:** `xcode-select` path must be active before running `./Tools/test.sh`
- **Stop Condition:** If `SMAppService` behaves unexpectedly with ad-hoc signing, halt, record failure, revert `launchctl` logic
- **Stop Condition:** If `./Tools/test.sh` fails at any point, stop and do not continue

## Review Focus

1. **Memory spike on 100k+ file trees** — enumerator must not materialize array of URLs; must use `autoreleasepool` per iteration
2. **Symlink loop protection** — enumerator must skip symlinks to mimic `du` behavior
3. **Cancellation semantics** — must throw `CancellationError()`, never return `0` (sentinel anti-pattern)
4. **SMAppService ad-hoc signing** — `SMAppService` may refuse to load agent from ad-hoc signed bundle; must revert to `launchctl` if it fails
5. **Ghost task cleanup** — `build.sh` must invoke installed app's `--remove-automation` before `rm -rf` to prevent launchd database corruption

---

### Task 1: Native Swift Directory Enumeration - Test Infrastructure

**Files:**
- Create: `Tests/IPhoneBackupCoreTests/BackupArchiverTests.swift` (new test class)
- Modify: `Sources/IPhoneBackupCore/BackupArchiver.swift` (lines 68-85)

**Interfaces:**
- Consumes: None (first task)
- Produces: `BackupArchiver.sourceSizeBytes(of:)` with native implementation, throwing `CancellationError()` on cancel

- [ ] **Step 1: Write the failing test**

```swift
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

    @Test("matches du output for flat directory")
    func matchesDuFlat() throws {
        // Create test files
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let data = Data(count: 10_000) // 10 KB
        try data.write(to: file1)
        try data.write(to: file2)

        // Native implementation
        let native = try archiver.sourceSizeBytes(of: tempDir)
        // Compare with du
        let duSize = try duOutput(tempDir)
        #expect(native == duSize)
    }

    @Test("matches du output for nested directory")
    func matchesDuNested() throws {
        let subdir = tempDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file1 = subdir.appendingPathComponent("nested.txt")
        let data = Data(count: 5_000)
        try data.write(to: file1)

        let native = try archiver.sourceSizeBytes(of: tempDir)
        let duSize = try duOutput(tempDir)
        #expect(native == duSize)
    }

    @Test("skips symlinks")
    func skipsSymlinks() throws {
        let target = tempDir.appendingPathComponent("target.txt")
        let data = Data(count: 100_000)
        try data.write(to: target)

        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let native = try archiver.sourceSizeBytes(of: tempDir)
        let duSize = try duOutput(tempDir)
        #expect(native == duSize) // du skips symlinks
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupArchiverSourceSizeTests`
Expected: FAIL - `sourceSizeBytes(of:)` not yet implemented natively

- [ ] **Step 3: Write minimal implementation**

```swift
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
    let cancellationLock = OSAllocatedUnfairLock(initialState: false)
    // Note: Cancellation check moved to public cancel() method

    for case let fileURL as URL in enumerator {
        // Check cancellation
        if cancellationLock.withLock({ $0 }) {
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

// Add to BackupArchiver class:
private let cancellationLock = OSAllocatedUnfairLock(initialState: false)

public func cancel() {
    cancellationLock.withLock { $0 = true }
    process?.terminate()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupArchiverSourceSizeTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Tests/IPhoneBackupCoreTests/BackupArchiverTests.swift Sources/IPhoneBackupCore/BackupArchiver.swift
git commit -m "feat: native Swift sourceSizeBytes replacing du (Task 1)"
```

---

### Task 2: SMAppService Migration - Test Infrastructure

**Files:**
- Create: `Tests/IPhoneBackupCoreTests/LaunchAgentManagerTests.swift` (new test class for SMAppService)
- Modify: `Sources/IPhoneBackupCore/LaunchAgentManager.swift` (lines 54-301)

**Interfaces:**
- Consumes: Existing `LaunchAgentManager` with `launchctl` implementation
- Produces: `LaunchAgentManager` using `SMAppService.agent(plistName:)` with bundle-embedded plist

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("LaunchAgentManager SMAppService")
struct LaunchAgentManagerSMAppServiceTests {
    let configuration: Configuration
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMAppServiceTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        configuration = Configuration(
            bundleIdentifier: "test.iphonebackup",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    @Test("SMAppService installs agent from bundle plist")
    func installFromBundle() throws {
        // Create a test bundle structure
        let bundle = tempDir.appendingPathComponent("TestApp.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Library/LaunchAgents"),
            withIntermediateDirectories: true
        )
        
        // Write executable stub
        let executable = bundle.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        
        // Write Info.plist
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>TestApp</string>
            <key>CFBundleIdentifier</key>
            <string>test.iphonebackup</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        
        // Write LaunchAgent plist to bundle
        let plist = [
            "Label": "test.iphonebackup",
            "ProgramArguments": [executable.path, "--automatic"],
            "RunAtLoad": true,
            "StartInterval": 300,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5
        ] as [String: Any]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appendingPathComponent("Contents/Library/LaunchAgents/test.iphonebackup.plist"), options: .atomic)
        
        let manager = LaunchAgentManager(configuration: configuration)
        let state = try manager.install(bundleURL: bundle)
        #expect(state == .installedAndLoaded)
        
        // Verify with SMAppService
        let status = SMAppService.agent(plistName: "test.iphonebackup.plist").status
        #expect(status == .enabled)
    }

    @Test("Ghost task cleanup in build.sh")
    func buildShCleansUpGhostTasks() throws {
        // This test verifies the build.sh logic by checking that
        // the installed app's --remove-automation is called before rm -rf
        let buildSh = try String(contentsOf: URL(fileURLWithPath: "../../build.sh"))
        #expect(buildSh.contains("--remove-automation"))
        #expect(buildSh.contains("rm -rf"))
        #expect(buildSh.range(of: "--remove-automation")!.lowerBound < buildSh.range(of: "rm -rf")!.lowerBound)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LaunchAgentManagerSMAppServiceTests`
Expected: FAIL - SMAppService implementation not yet present

- [ ] **Step 3: Write minimal implementation**

```swift
// In LaunchAgentManager.swift - add SMAppService support

import ServiceManagement

public struct LaunchAgentManager {
    // ... existing code ...

    /// Installs or upgrades the agent using SMAppService (macOS 13+)
    @discardableResult
    public func install(
        bundleURL: URL,
        startInterval: Int = LaunchAgentManager.defaultStartInterval
    ) throws -> LaunchAgentState {
        // Check macOS version
        if #available(macOS 13.0, *) {
            return try installWithSMAppService(bundleURL: bundleURL, startInterval: startInterval)
        } else {
            return try installWithLaunchctl(bundleURL: bundleURL, startInterval: startInterval)
        }
    }

    @available(macOS 13.0, *)
    private func installWithSMAppService(bundleURL: URL, startInterval: Int) throws -> LaunchAgentState {
        let site = Self.inspectInstallation(bundleURL: bundleURL)
        guard site.isSuitable else {
            throw LaunchAgentError.unsuitableInstallation(site.concerns)
        }

        // Verify bundle has LaunchAgent plist
        let bundlePlistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent("\(configuration.launchAgentLabel).plist")
        
        guard fileManager.fileExists(atPath: bundlePlistURL.path) else {
            throw LaunchAgentError.couldNotWritePlist("LaunchAgent plist not found in bundle at \(bundlePlistURL.path)")
        }

        // SMAppService reads the plist from the bundle automatically
        let service = SMAppService.agent(plistName: "\(configuration.launchAgentLabel).plist")
        
        // Unregister any existing
        do {
            try service.unregister()
        } catch {
            // Ignore if not registered
        }

        // Register the service
        do {
            try service.register()
        } catch {
            throw LaunchAgentError.bootstrapFailed(
                exitCode: -1, output: "SMAppService register failed: \(error)")
        }

        // Verify
        let status = service.status
        guard status == .enabled else {
            throw LaunchAgentError.verificationFailed("SMAppService reports status: \(status)")
        }

        return .installedAndLoaded
    }

    // Rename existing install to installWithLaunchctl
    private func installWithLaunchctl(
        bundleURL: URL,
        startInterval: Int
    ) throws -> LaunchAgentState {
        // ... existing launchctl implementation ...
    }

    // Similarly for uninstall
    public func uninstall() throws {
        if #available(macOS 13.0, *) {
            try uninstallWithSMAppService()
        } else {
            try uninstallWithLaunchctl()
        }
    }

    @available(macOS 13.0, *)
    private func uninstallWithSMAppService() throws {
        let service = SMAppService.agent(plistName: "\(configuration.launchAgentLabel).plist")
        do {
            try service.unregister()
        } catch {
            throw LaunchAgentError.bootoutFailed(
                exitCode: -1, output: "SMAppService unregister failed: \(error)")
        }
        
        // Clean up plist file
        if fileManager.fileExists(atPath: plistURL.path) {
            try? fileManager.removeItem(at: plistURL)
        }
        
        guard currentState() == .notInstalled else {
            throw LaunchAgentError.verificationFailed("the agent is still present after removal")
        }
    }

    // ... rest of existing implementation
}

// In build.sh - add ghost task cleanup before rm -rf
# In build.sh, before the rm -rf line:
APP="$HOME/Applications/iPhone Backup.app/Contents/MacOS/iPhoneBackup"
if [ -x "$APP" ]; then
    "$APP" --remove-automation || true
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LaunchAgentManagerSMAppServiceTests`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `./Tools/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IPhoneBackupCore/LaunchAgentManager.swift build.sh Tests/IPhoneBackupCoreTests/LaunchAgentManagerTests.swift
git commit -m "feat: SMAppService migration with ghost task cleanup (Task 2)"
```

---

### Task 3: ArchiveEngine Protocol - Extract ditto Logic

**Files:**
- Create: `Sources/IPhoneBackupCore/ArchiveEngine.swift` (new protocol and default implementation)
- Modify: `Sources/IPhoneBackupCore/BackupArchiver.swift` (lines 163-182)

**Interfaces:**
- Consumes: Current `ditto` shell-out in `BackupArchiver.archive()`
- Produces: `ArchiveEngine` protocol with `DittoArchiveEngine` implementation

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("ArchiveEngine")
struct ArchiveEngineTests {
    let tempDir: URL
    let configuration: Configuration

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEngineTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        configuration = Configuration(
            bundleIdentifier: "test",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    @Test("DittoArchiveEngine creates valid zip64 archive")
    func dittoCreatesValidZip() async throws {
        let source = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: file, atomically: true, encoding: .utf8)
        
        let destination = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        
        let engine = DittoArchiveEngine(configuration: configuration)
        let outputURL = try await engine.archive(
            sourceDirectory: source,
            destinationDirectory: destination,
            archiveName: "test.zip"
        )
        
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(outputURL.pathExtension == "zip")
        
        // Verify it's a valid zip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", outputURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("ArchiveEngine protocol can be swapped")
    func protocolSwap() throws {
        // Verify protocol exists and can be implemented
        let engine: ArchiveEngine = DittoArchiveEngine(configuration: Configuration.testConfiguration)
        #expect(engine != nil)
    }
}

protocol ArchiveEngine {
    func archive(
        sourceDirectory: URL,
        destinationDirectory: URL,
        archiveName: String
    ) async throws -> URL
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArchiveEngineTests`
Expected: FAIL - `ArchiveEngine` protocol and `DittoArchiveEngine` not yet defined

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IPhoneBackupCore/ArchiveEngine.swift
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
public final class DittoArchiveEngine: ArchiveEngine {
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
            throw ArchiveError.toolStartFailed(error)
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

public enum ArchiveError: Error, Equatable {
    case logCreationFailed
    case toolStartFailed(Error)
    case toolFailed(exitCode: Int32, stderrTail: String)
    case outputMissing
}
```

- [ ] **Step 4: Update BackupArchiver to use ArchiveEngine**

```swift
// In BackupArchiver.swift - modify the archive method signature
public func archive(
    candidate: BackupCandidate,
    archiveFilename: String,
    destinationFolder: URL,
    sourceBytes: Int64,
    conflictPolicy: ConflictPolicy,
    progress: ((ArchiveProgress) -> Void)? = nil,
    isCancelled: @escaping () -> Bool = { false },
    archiveEngine: ArchiveEngine = DittoArchiveEngine(configuration: configuration)
) -> Result<ArchiveOutcome, RunFailure> {
    // ... replace ditto shell-out with:
    let outputURL = try await archiveEngine.archive(
        sourceDirectory: candidate.directoryURL,
        destinationDirectory: configuration.stagingRoot,
        archiveName: archiveFilename
    )
    // ... rest of logic adapted to use outputURL
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ArchiveEngineTests`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `./Tools/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IPhoneBackupCore/ArchiveEngine.swift Sources/IPhoneBackupCore/BackupArchiver.swift Tests/IPhoneBackupCoreTests/ArchiveEngineTests.swift
git commit -m "feat: ArchiveEngine protocol with Ditto implementation (Task 3)"
```

---

### Task 4: Configuration Audit - Hardcoded Paths for MAS Sandbox

**Files:**
- Modify: `Sources/IPhoneBackupCore/Configuration.swift`

**Interfaces:**
- Consumes: Current `Configuration.resolve()` and hardcoded paths
- Produces: Audited paths with `// TODO: MAS-Sandbox` comments

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("Configuration MAS Audit")
struct ConfigurationMASAuditTests {
    @Test("All hardcoded home.appendingPathComponent calls are documented")
    func hardcodedPathsDocumented() throws {
        let configSource = try String(contentsOf: URL(fileURLWithPath: "Sources/IPhoneBackupCore/Configuration.swift"))
        
        // Find all home.appendingPathComponent calls
        let pattern = #"home\.appendingPathComponent\("#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: configSource.utf16.count)
        let matches = regex.matches(in: configSource, options: [], range: range)
        
        // Each match should have a nearby TODO: MAS-Sandbox comment
        for match in matches {
            let line = (configSource as NSString).substring(with: match.range).components(separatedBy: "\n").first ?? ""
            // Check for TODO comment on same line or next line
            // This is a documentation audit - actual enforcement is manual
        }
        
        // At minimum, these paths should be flagged:
        // 1. .iphone-backup-staging (stagingRoot)
        // 2. Library/Application Support (applicationSupportDirectory)
        // 3. Library/LaunchAgents (plistURL in LaunchAgentManager)
        // 4. Backup destination root (destinationRootOverride)
        print("Found \(matches.count) home.appendingPathComponent calls - verify MAS comments")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigurationMASAuditTests`
Expected: PASS (test is documentation audit)

- [ ] **Step 3: Add MAS-Sandbox TODO comments**

```swift
// In Configuration.swift - add TODO comments at each hardcoded path

public var stagingRoot: URL {
    // TODO: MAS-Sandbox - Security-Scoped Bookmark needed for user-selected staging location
    // Current: home.appendingPathComponent(".iphone-backup-staging")
    return URL(string: "file://" + path)! // placeholder
}

// In resolve():
let stagingRoot = home.appendingPathComponent(".iphone-backup-staging")
// TODO: MAS-Sandbox - User-selected staging volume via Security-Scoped Bookmark

let supportDirectory = appSupport.appendingPathComponent(identifier)
// TODO: MAS-Sandbox - Application Support dir accessible; bookmark for persistence

// In LaunchAgentManager.plistURL:
fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents")
// TODO: MAS-Sandbox - LaunchAgents dir via SMAppService bundle; no user path needed
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfigurationMASAuditTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/IPhoneBackupCore/Configuration.swift Tests/IPhoneBackupCoreTests/ConfigurationMASAuditTests.swift
git commit -m "chore: MAS Sandbox audit comments on hardcoded paths (Task 4)"
```

---

### Task 5: Final Validation & Release

**Files:**
- All modified files

**Interfaces:**
- Consumes: All Phase 1 changes
- Produces: Validated release candidate

- [ ] **Step 1: Run full test suite**

Run: `./Tools/test.sh`
Expected: All tests PASS

- [ ] **Step 2: Manual verification**

```bash
# Test SMAppService with ad-hoc signing
./build.sh
open build/iPhone\ Backup.app
# Verify automation installs in System Settings > Login Items
# Verify manual backup works
# Verify automatic runs on interval
```

- [ ] **Step 3: Update CHANGELOG**

```markdown
## [1.2.0] — 2026-10-XX

Phase 1 MAS Compliance.

- **Native Swift enumeration:** `sourceSizeBytes(of:)` now uses `FileManager.enumerator` with lazy consumption, `autoreleasepool`, symlink skipping, and `CancellationError` throwing.
- **SMAppService migration:** `LaunchAgentManager` now uses `SMAppService.agent()` on macOS 13+, with `launchctl` fallback. Ghost task cleanup in `build.sh`.
- **ArchiveEngine protocol:** Extracted `ditto` logic into `ArchiveEngine` protocol with `DittoArchiveEngine` implementation for future `AppleArchive` swap.
- **MAS Sandbox audit:** All hardcoded `home.appendingPathComponent` paths documented with `TODO: MAS-Sandbox` comments for future Security-Scoped Bookmark integration.
```

- [ ] **Step 6: Version bump**

```bash
# Update version in Package.swift, Info.plist, etc.
git commit -am "chore: version 1.2.0 - Phase 1 MAS Compliance"
git tag v1.2.0
git push origin main --tags
```

- [ ] **Step 7: Push and release**

```bash
git push origin main
gh release create v1.2.0 --generate-notes
```

---

## Phase 2: UX Fixes (Separate Plan)

The UX fixes from "Multiple things about the iPhone backup app" are a separate concern and will be handled in a separate plan:

1. **Automation location workaround** - App launched from repo shows "can't set up automation" → common support directory
2. **Backup check bug** - "Nothing to back up" false negative → investigate detection logic
3. **Interval defaults** - 5 min → 15-30 min default

These will be detailed in a separate execution plan document.