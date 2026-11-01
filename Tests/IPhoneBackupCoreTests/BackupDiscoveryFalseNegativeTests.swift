import XCTest
@testable import IPhoneBackupCore

final class BackupDiscoveryFalseNegativeTests: TemporaryDirectoryTestCase {

    private func configuration() -> Configuration {
        Configuration(
            bundleIdentifier: "test",
            backupRoot: root.appendingPathComponent("backup"),
            stagingRoot: root.appendingPathComponent("staging"),
            applicationSupportDirectory: root.appendingPathComponent("support"),
            destinationSubdirectory: "_iPhone-BU",
            minimumSettleAge: 900 // 15 minutes for testing
        )
    }

    // MARK: - Test Helpers

    private func makeValidBackup(at url: URL, modificationAge: TimeInterval = 3600) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Create required backup files
        let statusPlist = """
        <plist version="1.0"><dict>
            <key>SnapshotState</key><string>finished</string>
            <key>BackupState</key><string>new</string>
            <key>Date</key><date>\(Date().addingTimeInterval(-modificationAge).ISO8601Format())</date>
            <key>UUID</key><string>\(UUID().uuidString)</string>
            <key>IsFullBackup</key><false/>
            <key>Version</key><string>3.3</string>
        </dict></plist>
        """
        try statusPlist.write(to: url.appendingPathComponent("Status.plist"), atomically: true, encoding: .utf8)

        let manifest = url.appendingPathComponent("Manifest.db")
        try "manifest".write(to: manifest, atomically: true, encoding: .utf8)

        let infoPlist = """
        <plist version="1.0"><dict>
            <key>Device Name</key><string>Test iPhone</string>
            <key>Last Backup Date</key><date>\(Date().addingTimeInterval(-modificationAge).ISO8601Format())</date>
        </dict></plist>
        """
        try infoPlist.write(to: url.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // Touch files to set modification time
        let targetDate = Date().addingTimeInterval(-modificationAge)
        for name in ["Status.plist", "Manifest.db", "Info.plist"] {
            let file = url.appendingPathComponent(name)
            try FileManager.default.setAttributes([.modificationDate: targetDate], ofItemAtPath: file.path)
        }
    }

    // MARK: - Tests

    /// Regression for waypoint iphone-backup-jetzt-pruefen: the manual UI and the
    /// automatic check must share ONE selection (BackupDiscovery.newestUnprocessed), so
    /// they can never disagree about whether work exists.
    func testCheckAndManualSelectionAgree() throws {
        let config = configuration()
        let validator = BackupCompletionValidator()
        let discovery = BackupDiscovery(configuration: config, validator: validator)
        let store = BackupStateStore(url: root.appendingPathComponent("state.json"))

        // A backup exists and is NOT yet recorded: both paths must see it.
        let backupDir = root.appendingPathComponent("backup/device1")
        try makeValidBackup(at: backupDir)
        var result = try XCTUnwrap(discovery.discover().get())
        let picked = try XCTUnwrap(discovery.newestUnprocessed(in: result, store: store))
        let controller = AutomaticRunController(
            configuration: config, discovery: discovery, validator: validator,
            locator: CloudRootLocator(), archiver: BackupArchiver(configuration: config),
            store: store, lock: ProcessLock(url: config.lockURL), logger: AppLogger(subsystem: "test"))
        // no cloud root is configured, so check() is .configurationRequired here —
        // anything but .nothingToDo proves the check saw the unrecorded backup
        if case .nothingToDo = controller.check() {
            XCTFail("check must see the unrecorded backup")
        }

        // Record it as archived: both paths must now agree there is nothing new.
        try store.recordArchive(candidate: picked, archiveFilename: "a.zip", archiveSize: 1)
        result = try XCTUnwrap(discovery.discover().get())
        XCTAssertNil(discovery.newestUnprocessed(in: result, store: store),
                     "manual selection must respect the recorded identity")
        if case .nothingToDo = controller.check() {
            // expected
        } else {
            XCTFail("check and manual must agree: nothing to do once recorded")
        }

        // A NEWER backup in the same directory (incremental backups reuse it) gets a new
        // identity: both paths must find it — never a silent nothing-to-do.
        try makeValidBackup(at: backupDir, modificationAge: 60)
        result = try XCTUnwrap(discovery.discover().get())
        let newer = try XCTUnwrap(discovery.newestUnprocessed(in: result, store: store))
        XCTAssertNotEqual(newer.identity, picked.identity)
        if case .nothingToDo = controller.check() {
            XCTFail("newer backup must not produce a silent nothing-to-do")
        }
    }

    func testDetectsRecentBackupAsCandidate() throws {
        // Create a backup that was modified recently (within minimumSettleAge)
        let backupDir = root.appendingPathComponent("backup/recent")
        try makeValidBackup(at: backupDir, modificationAge: 300) // 5 minutes ago

        let config = configuration()
        let discovery = BackupDiscovery(configuration: config)
        let result = try discovery.discover().get()

        // Should find the backup as a candidate
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = result.candidates[0]
        XCTAssertTrue(candidate.directoryURL.path.hasSuffix(backupDir.lastPathComponent),
                     "Candidate should point to the backup directory, got: \(candidate.directoryURL.path)")
    }

    func testManualArchiveFindsDataWhenDiscoveryReportsEmpty() throws {
        // Reproduce the user's bug: "nothing to back up" but manual archive works
        // The issue: recently modified backup is rejected, so discovery returns no candidates

        // Create a backup that was just modified (within quiet period)
        let backupDir = root.appendingPathComponent("backup/just-finished")
        try makeValidBackup(at: backupDir, modificationAge: 60) // 1 minute ago

        let config = configuration()
        let discovery = BackupDiscovery(configuration: config)
        let result = try discovery.discover().get()

        // Should NOT have zero candidates - should find the backup but mark it appropriately
        XCTAssertGreaterThan(result.candidates.count, 0, "Should find the recent backup as a candidate")
        let candidate = result.candidates[0]
        XCTAssertTrue(candidate.directoryURL.path.hasSuffix(backupDir.lastPathComponent),
                      "Candidate should point to the backup directory, got: \(candidate.directoryURL.path)")
    }

    func testOldBackupStillDetected() throws {
        // Old backup (well past settle age) should work as before
        let backupDir = root.appendingPathComponent("backup/old")
        try makeValidBackup(at: backupDir, modificationAge: 7200) // 2 hours ago

        let config = configuration()
        let discovery = BackupDiscovery(configuration: config)
        let result = try discovery.discover().get()

        XCTAssertEqual(result.candidates.count, 1)
        let candidate = result.candidates[0]
        XCTAssertTrue(candidate.directoryURL.path.hasSuffix(backupDir.lastPathComponent),
                      "Candidate should point to the backup directory, got: \(candidate.directoryURL.path)")
    }
}

extension Date {
    var ISO8601Format: String {
        ISO8601DateFormatter().string(from: self)
    }
}