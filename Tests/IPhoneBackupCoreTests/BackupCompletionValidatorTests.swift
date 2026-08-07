import XCTest
@testable import IPhoneBackupCore

/// Fixtures only ever live in a temporary directory. Nothing here may read or
/// write the developer's real backup folder or cloud storage — a test that
/// touched a 50 GB archive would be worse than no test.
class TemporaryDirectoryTestCase: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iphonebackup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// Builds a backup directory shaped like a real one. Defaults reproduce the
    /// state observed on the development machine.
    @discardableResult
    func makeBackup(
        named name: String = "00000000-000000000000FFFF",
        snapshotState: String? = "finished",
        backupState: String = "new",
        date: Date? = Date(timeIntervalSince1970: 1_785_943_354),
        includeManifest: Bool = true,
        manifestAsDirectory: Bool = false,
        includeInfo: Bool = true
    ) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let snapshotState {
            var status: [String: Any] = [
                "SnapshotState": snapshotState,
                "BackupState": backupState,
                "IsFullBackup": false,
                "Version": "3.3",
                "UUID": "00000000-0000-0000-0000-000000000001",
            ]
            if let date { status["Date"] = date }
            let data = try PropertyListSerialization.data(
                fromPropertyList: status, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("Status.plist"))
        }

        if includeManifest {
            let manifest = dir.appendingPathComponent("Manifest.db")
            if manifestAsDirectory {
                try FileManager.default.createDirectory(
                    at: manifest, withIntermediateDirectories: true)
            } else {
                try Data("sqlite placeholder".utf8).write(to: manifest)
            }
        }

        if includeInfo {
            let info: [String: Any] = [
                "Device Name": "Test iPhone",
                "Product Version": "26.0",
                "Last Backup Date": date ?? Date(timeIntervalSince1970: 0),
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("Info.plist"))
        }

        return dir
    }
}

final class BackupCompletionValidatorTests: TemporaryDirectoryTestCase {

    private let validator = BackupCompletionValidator()

    func testParsesStatusPlistInTheShapeObservedOnRealHardware() throws {
        let dir = try makeBackup()
        let status = try XCTUnwrap(validator.readStatus(in: dir))

        XCTAssertEqual(status.snapshotState, "finished")
        XCTAssertEqual(status.backupState, "new")
        XCTAssertEqual(status.isFullBackup, false)
        XCTAssertEqual(status.version, "3.3")
        XCTAssertNotNil(status.date)
        XCTAssertNotNil(status.uuid)
    }

    func testAcceptsFinishedSnapshot() throws {
        let dir = try makeBackup()
        guard case .success(let status) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a finished backup with a readable manifest must validate")
        }
        XCTAssertEqual(status.snapshotState, "finished")
    }

    /// The value is not documented API, so its casing must not be load-bearing.
    func testAcceptsFinishedRegardlessOfCase() throws {
        let dir = try makeBackup(named: "case-test", snapshotState: "Finished")
        guard case .success = validator.validateCompletion(directory: dir) else {
            return XCTFail("SnapshotState comparison must be case-insensitive")
        }
    }

    func testRejectsSnapshotThatIsNotFinished() throws {
        let dir = try makeBackup(named: "in-progress", snapshotState: "new")
        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("an unfinished backup must not validate")
        }
        XCTAssertEqual(reason, .snapshotNotFinished(state: "new"))
    }

    func testRejectsMissingStatusPlist() throws {
        let dir = try makeBackup(named: "no-status", snapshotState: nil)
        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a backup with no Status.plist must not validate")
        }
        XCTAssertEqual(reason, .statusPlistUnreadable)
    }

    func testRejectsMissingManifest() throws {
        let dir = try makeBackup(named: "no-manifest", includeManifest: false)
        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a backup with no Manifest.db must not validate")
        }
        XCTAssertEqual(reason, .manifestMissing)
    }

    /// A directory named Manifest.db satisfies "exists" but is not a usable
    /// database, so the check has to test for a regular file specifically.
    func testRejectsManifestThatIsADirectory() throws {
        let dir = try makeBackup(named: "dir-manifest", manifestAsDirectory: true)
        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a directory named Manifest.db must not count as a manifest")
        }
        XCTAssertEqual(reason, .manifestMissing)
    }

    // MARK: Stability

    func testStableMetadataConfirmsCompletion() throws {
        let dir = try makeBackup(named: "stable")
        let clock = ImmediateClock()

        guard case .success = validator.confirmStable(
            directory: dir, quietPeriod: 60, clock: clock
        ) else {
            return XCTFail("untouched metadata must confirm as stable")
        }
        // The quiet period must actually be requested, not silently skipped.
        XCTAssertEqual(clock.requestedWaits, [60])
    }

    /// The case that motivates the whole check: on real hardware Info.plist kept
    /// growing for 2m42s after SnapshotState already read "finished".
    func testGrowingInfoPlistDuringQuietPeriodIsRejected() throws {
        let dir = try makeBackup(named: "still-writing")

        final class GrowingClock: QuietPeriodClock {
            let target: URL
            init(target: URL) { self.target = target }
            func wait(_ interval: TimeInterval) {
                // Simulates Apple still writing while we wait.
                try? Data(repeating: 0, count: 4096).write(to: target)
            }
        }
        let clock = GrowingClock(target: dir.appendingPathComponent("Info.plist"))

        guard case .failure(let reason) = validator.confirmStable(
            directory: dir, quietPeriod: 60, clock: clock
        ) else {
            return XCTFail("metadata that changes during the quiet period must be rejected")
        }
        XCTAssertEqual(reason, .metadataStillChanging(fields: ["Info.plist"]))
    }

    /// A new backup starting during the quiet window flips the state back; the
    /// re-check after waiting is what catches it.
    func testSnapshotLeavingFinishedDuringQuietPeriodIsRejected() throws {
        let dir = try makeBackup(named: "restarted")

        final class RestartClock: QuietPeriodClock {
            let dir: URL
            init(dir: URL) { self.dir = dir }
            func wait(_ interval: TimeInterval) {
                let status: [String: Any] = ["SnapshotState": "new", "BackupState": "new"]
                if let data = try? PropertyListSerialization.data(
                    fromPropertyList: status, format: .xml, options: 0) {
                    try? data.write(to: dir.appendingPathComponent("Status.plist"))
                }
            }
        }

        let result = validator.confirmStable(
            directory: dir, quietPeriod: 60, clock: RestartClock(dir: dir))
        guard case .failure = result else {
            return XCTFail("a backup that restarted during the quiet period must be rejected")
        }
    }

    func testFingerprintNamesOnlyTheFilesThatMoved() throws {
        let dir = try makeBackup(named: "fingerprint")
        let before = validator.fingerprint(directory: dir)

        try Data(repeating: 1, count: 128).write(to: dir.appendingPathComponent("Manifest.db"))
        let after = validator.fingerprint(directory: dir)

        XCTAssertEqual(before.changedFields(comparedTo: after), ["Manifest.db"])
    }
}
