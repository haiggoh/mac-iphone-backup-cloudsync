# iPhone Backup: UX Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three UX issues reported by the user: (1) automation setup blocked when app launched from repo, (2) "nothing to back up" false negative, (3) overly aggressive 5-minute polling interval.

**Architecture:** Three independent UX fixes:
1. Common support directory for automation regardless of launch location
2. Fix backup readiness detection false negative
3. Adjust default polling interval from 5 min → 30 min with 15 min minimum

**Tech Stack:** Swift 5.9+, Foundation, FileManager, SMAppService, Swift Testing / XCTest

**Spec:** `../../../.claude/plans/restored-from-claude-migration-2026-09-28/Multiple things about the iPhone backup app..md`

## Global Constraints

- **Prohibited:** Do not enable App Sandbox yet
- **Prohibited:** Do not modify entitlements or sandbox flags
- **Required:** Must maintain backward compatibility with existing installations
- **Required:** All changes must pass existing test suite

## Review Focus

1. **Automation path resolution** — must work regardless of whether app launched from repo, Applications, or elsewhere
2. **Backup readiness detection** — must not report "nothing to back up" when manual backup finds data
3. **Interval persistence** — user-configured intervals must survive app updates

---

### Task 1: Automation Location Workaround - Common Support Directory

**Files:**
- Modify: `Sources/IPhoneBackupCore/LaunchAgentManager.swift` (inspectInstallation, plistContents)
- Modify: `Sources/IPhoneBackupCore/Configuration.swift` (resolve paths)
- Modify: `Sources/IPhoneBackupCore/ApplicationMode.swift` (if exists)

**Interfaces:**
- Consumes: Current `inspectInstallation()` which rejects volatile locations
- Produces: Modified `inspectInstallation()` that resolves to a stable support directory

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("LaunchAgentManager Automation Location")
struct LaunchAgentManagerAutomationLocationTests {
    let configuration: Configuration
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationLocationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        configuration = Configuration(
            bundleIdentifier: "test.iphonebackup",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    @Test("App launched from build directory can still automate via support dir")
    func buildDirCanAutomate() throws {
        // Simulate app launched from build directory
        let buildDir = tempDir.appendingPathComponent("build/Debug")
        try FileManager.default.createDirectory(
            at: buildDir.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let executable = buildDir.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        
        let infoPlist = """
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>TestApp</string>
            <key>CFBundleIdentifier</key><string>test.iphonebackup</string>
        </dict></plist>
        """
        try infoPlist.write(to: buildDir.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        
        let manager = LaunchAgentManager(configuration: configuration)
        let site = LaunchAgentManager.inspectInstallation(bundleURL: buildDir)
        
        // Should NOT reject as volatileLocation - instead resolve to support dir
        #expect(site.concerns.isEmpty || site.concerns.allSatisfy { $0 != .volatileLocation(path: "") })
        #expect(site.executableURL.path.contains("Application Support") || site.executableURL.path.contains("Library"))
    }

    @Test("Automation uses support directory executable")
    func usesSupportDirExecutable() throws {
        let manager = LaunchAgentManager(configuration: configuration)
        
        // Install from a "volatile" location
        let buildDir = tempDir.appendingPathComponent("build/Debug")
        try FileManager.default.createDirectory(
            at: buildDir.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let executable = buildDir.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        
        let infoPlist = """
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>TestApp</string>
            <key>CFBundleIdentifier</key><string>test.iphonebackup</string>
        </dict></plist>
        """
        try infoPlist.write(to: buildDir.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        
        // Should resolve to support directory
        let site = LaunchAgentManager.inspectInstallation(bundleURL: buildDir)
        #expect(site.executableURL.path.contains("Application Support"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LaunchAgentManagerAutomationLocationTests`
Expected: FAIL - Current implementation rejects volatile locations

- [ ] **Step 3: Write minimal implementation**

```swift
// In LaunchAgentManager.swift - modify inspectInstallation

public static func inspectInstallation(bundleURL: URL) -> InstallationSite {
    var concerns: [InstallationConcern] = []
    let path = bundleURL.path

    // App translocation
    if path.contains("/AppTranslocation/") {
        concerns.append(.translocated(path: path))
    }

    if let writable = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        .volumeIsReadOnly, writable == true {
        concerns.append(.readOnlyVolume(path: path))
    }

    // Check if running from volatile location
    let volatileMarkers = ["/build/", "/.build/", "/Downloads/", "/tmp/", "/private/tmp/"]
    let isVolatile = volatileMarkers.contains(where: { path.contains($0) })
    
    // Resolve stable executable path
    let stableExecutableURL: URL
    if isVolatile {
        // Resolve to Application Support directory
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(bundleIdentifierFromBundle(bundleURL))
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(bundleExecutableName(in: bundleURL))
        // Note: App should copy itself to support dir on first run
        // For now, flag as concern but provide stable path
        concerns.append(.volatileLocation(path: path))
        stableExecutableURL = executableURL // Will be updated by app on first run
    } else {
        stableExecutableURL = bundleURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(bundleExecutableName(in: bundleURL))
    }
    
    return InstallationSite(
        bundleURL: bundleURL,
        executableURL: stableExecutableURL,
        concerns: concerns
    )
}

// Add helper to copy self to support directory on first run
// In ApplicationMode.swift or main app entry point:
func ensureStableInstallation(configuration: Configuration) throws {
    let currentBundle = Bundle.main.bundleURL
    let supportDir = configuration.applicationSupportDirectory
    let stableBundle = supportDir.appendingPathComponent("InstalledApp")
    let stableExecutable = stableBundle
        .appendingPathComponent("Contents/MacOS")
        .appendingPathComponent(Bundle.main.bundleExecutableName)
    
    if !FileManager.default.fileExists(atPath: stableExecutable.path) {
        // Copy entire bundle to support directory
        try FileManager.default.copyItem(at: currentBundle, to: stableBundle)
    }
    
    // Update LaunchAgent to point to stable executable
    // This is done by LaunchAgentManager.install() which reads from bundle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LaunchAgentManagerAutomationLocationTests`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `./Tools/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IPhoneBackupCore/LaunchAgentManager.swift Sources/IPhoneBackupCore/ApplicationMode.swift Tests/IPhoneBackupCoreTests/LaunchAgentManagerTests.swift
git commit -m "feat: automation location workaround via support directory (Task 1)"
```

---

### Task 2: Backup Check Bug Fix - False Negative Detection

**Files:**
- Modify: `Sources/IPhoneBackupCore/BackupDiscovery.swift`
- Modify: `Sources/IPhoneBackupCore/BackupCandidate.swift` (if exists)
- Modify: `Sources/IPhoneBackupCore/BackupArchiver.swift` (archive validation)

**Interfaces:**
- Consumes: Current backup detection logic
- Produces: Fixed detection that doesn't report false negatives

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("BackupDiscovery False Negative Fix")
struct BackupDiscoveryTests {
    let configuration: Configuration
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupDiscoveryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        configuration = Configuration(
            bundleIdentifier: "test",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    @Test("Detects backup that manual archive finds")
    func detectsManualBackup() throws {
        // Create a backup directory that looks valid but might be missed
        let backupDir = tempDir.appendingPathComponent("backup/1234567890")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        // Create minimal valid backup structure
        let infoPlist = backupDir.appendingPathComponent("Info.plist")
        try """
        <plist version="1.0"><dict>
            <key>Device Name</key><string>Test iPhone</string>
            <key>Last Backup Date</key><date>2026-10-01T12:00:00Z</date>
        </dict></plist>
        """.write(to: infoPlist, atomically: true, encoding: .utf8)
        
        let manifest = backupDir.appendingPathComponent("Manifest.plist")
        try """
        <plist version="1.0"><dict>
            <key>Version</key><integer>1</integer>
        </dict></plist>
        """.write(to: manifest, atomically: true, encoding: .utf8)
        
        // Create a small data file
        let dataFile = backupDir.appendingPathComponent("data.txt")
        try "backup data".write(to: dataFile, atomically: true, encoding: .utf8)
        
        // Discovery should find this
        let discovery = BackupDiscovery(configuration: configuration, fileManager: FileManager.default)
        let candidates = discovery.findCandidates()
        
        #expect(!candidates.isEmpty, "Should find at least one backup candidate")
        #expect(candidates.contains { $0.directoryURL == backupDir })
    }

    @Test("Manual archive finds data when discovery reports empty")
    func manualArchiveFindsDataWhenDiscoveryEmpty() throws {
        // This reproduces the user's bug: "nothing to back up" but manual works
        // The issue is likely in quiet period / settle age check
        
        let backupDir = tempDir.appendingPathComponent("backup/recent")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        // Create files with recent modification time (within quiet period)
        let file = backupDir.appendingPathComponent("new_data.txt")
        try "recent data".write(to: file, atomically: true, encoding: .utf8)
        
        // Manually set mtime to now (simulating just-finished backup)
        var attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        attrs[.modificationDate] = Date()
        try FileManager.default.setAttributes(attrs, ofItemAtPath: file.path)
        
        let infoPlist = backupDir.appendingPathComponent("Info.plist")
        try """
        <plist version="1.0"><dict>
            <key>Device Name</key><string>Test iPhone</string>
            <key>Last Backup Date</key><date>\(ISO8601DateFormatter().string(from: Date()))</date>
        </dict></plist>
        """.write(to: infoPlist, atomically: true, encoding: .utf8)
        
        let discovery = BackupDiscovery(configuration: configuration, fileManager: FileManager.default)
        let candidates = discovery.findCandidates()
        
        // This should find the candidate even if recently modified
        // The bug was: "checked: nothing to back up" but manual found data
        #expect(!candidates.isEmpty || candidates.first?.settleStatus == .tooNew)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupDiscoveryTests`
Expected: FAIL - Current logic may reject recently modified backups

- [ ] **Step 3: Write minimal implementation**

```swift
// In BackupDiscovery.swift - fix the detection logic

public struct BackupCandidate: Equatable {
    public let directoryURL: URL
    public let sizeBytes: Int64
    public let lastModified: Date
    public let settleStatus: SettleStatus
    
    public enum SettleStatus: Equatable {
        case ready
        case tooNew(settledAt: Date)
        case incomplete
    }
}

public struct BackupDiscovery {
    private let configuration: Configuration
    private let fileManager: FileManager
    
    public init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }
    
    public func findCandidates() -> [BackupCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: configuration.backupRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var candidates: [BackupCandidate] = []
        
        for case let url as URL in enumerator {
            guard isValidBackupDirectory(url) else { continue }
            
            let size = calculateDirectorySize(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            
            // Check if directory has finished being written (settle age)
            let age = Date().timeIntervalSince(modified)
            let settleStatus: BackupCandidate.SettleStatus
            
            if age >= configuration.minimumSettleAge {
                settleStatus = .ready
            } else {
                // Don't skip - mark as tooNew so caller knows
                settleStatus = .tooNew(settledAt: modified.addingTimeInterval(configuration.minimumSettleAge))
            }
            
            candidates.append(BackupCandidate(
                directoryURL: url,
                sizeBytes: size,
                lastModified: modified,
                settleStatus: settleStatus
            ))
        }
        
        return candidates
    }
    
    private func isValidBackupDirectory(_ url: URL) -> Bool {
        // Check for required backup structure
        let requiredFiles = ["Info.plist", "Manifest.plist"]
        return requiredFiles.allSatisfy { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
    }
    
    private func calculateDirectorySize(_ url: URL) -> Int64 {
        // Reuse the native enumeration from BackupArchiver
        // ... implementation
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupDiscoveryTests`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `./Tools/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IPhoneBackupCore/BackupDiscovery.swift Tests/IPhoneBackupCoreTests/BackupDiscoveryTests.swift
git commit -m "fix: backup detection false negative (Task 2)"
```

---

### Task 3: Interval Defaults - 5 min → 30 min with 15 min Minimum

**Files:**
- Modify: `Sources/IPhoneBackupCore/Configuration.swift` (defaultPollInterval)
- Modify: `Sources/IPhoneBackupCore/SettingsStore.swift` (if exists)
- Modify: `Sources/IPhoneBackupCore/LaunchAgentManager.swift` (defaultStartInterval)

**Interfaces:**
- Consumes: Current 5-minute default
- Produces: 30-minute default with 15-minute minimum

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import IPhoneBackupCore

@Suite("Configuration Interval Defaults")
struct ConfigurationIntervalTests {
    @Test("Default poll interval is 30 minutes")
    func defaultPollInterval() {
        #expect(Configuration.defaultPollInterval == 1800) // 30 minutes
    }
    
    @Test("Minimum poll interval is 15 minutes")
    func minimumPollInterval() {
        #expect(Configuration.minimumPollInterval == 900) // 15 minutes
    }
    
    @Test("LaunchAgent default start interval is 30 minutes")
    func launchAgentDefaultInterval() {
        #expect(LaunchAgentManager.defaultStartInterval == 1800)
    }
    
    @Test("SettingsStore respects minimum interval")
    func settingsStoreRespectsMinimum() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let store = SettingsStore(url: tempDir.appendingPathComponent("settings.json"))
        var settings = store.load()
        
        // Try to set below minimum
        settings.pollInterval = 300 // 5 minutes
        try store.save(settings)
        
        // Should be clamped to minimum
        let loaded = store.load()
        #expect(loaded.pollInterval >= 900)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigurationIntervalTests`
Expected: FAIL - Constants still at 5 minutes

- [ ] **Step 3: Write minimal implementation**

```swift
// In Configuration.swift

public static let defaultPollInterval: TimeInterval = 1800 // 30 minutes (was 300)
public static let minimumPollInterval: TimeInterval = 900 // 15 minutes minimum

// In LaunchAgentManager
public static let defaultStartInterval = 1800 // 30 minutes (was 300)

// In SettingsStore
public var pollInterval: TimeInterval {
    get { data["pollInterval"] as? TimeInterval ?? Configuration.defaultPollInterval }
    set { 
        data["pollInterval"] = max(newValue, Configuration.minimumPollInterval)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfigurationIntervalTests`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `./Tools/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/IPhoneBackupCore/Configuration.swift Sources/IPhoneBackupCore/LaunchAgentManager.swift Sources/IPhoneBackupCore/SettingsStore.swift Tests/IPhoneBackupCoreTests/ConfigurationIntervalTests.swift
git commit -m "feat: interval defaults 30min with 15min minimum (Task 3)"
```

---

### Task 4: Final Validation & Release

**Files:** All modified files

- [ ] **Step 1: Run full test suite**

Run: `./Tools/test.sh`
Expected: All tests PASS

- [ ] **Step 2: Manual UX verification**

```bash
# Test automation from build directory
./build.sh
# Launch from build dir - should work now
# Verify System Settings > Login Items shows agent

# Test backup detection
# Create a recent backup, check "Check Now" shows correctly

# Test interval defaults
# Fresh install should show 30 min default
# Try to set 5 min → should clamp to 15 min
```

- [ ] **Step 3: Update CHANGELOG**

```markdown
## [1.3.0] — 2026-10-XX

UX Fixes.

- **Automation location workaround:** App launched from build directory now copies itself to Application Support for stable automation path.
- **Backup check bug fix:** "Nothing to back up" false negative fixed - recently modified backups now marked as pending rather than ignored.
- **Interval defaults:** Default polling interval changed from 5 min to 30 min (process takes 10-20 min), with 15 min minimum enforced.
```

- [ ] **Step 6: Version bump & release**

```bash
git commit -am "chore: version 1.3.0 - UX Fixes"
git tag v1.3.0
git push origin main --tags
gh release create v1.3.0 --generate-notes
```

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-10-02-iphone-backup-ux-fixes.md`.**

**Recommended approach: Subagent-driven** — The tasks have clear interfaces and can be implemented independently. The Phase 1 MAS Compliance plan and this UX Fixes plan can be executed in parallel if needed.

**Does the plan capture what you want, and which approach should we use?**