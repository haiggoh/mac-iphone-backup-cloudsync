import XCTest
@testable import IPhoneBackupCore

final class BackupDiscoveryTests: TemporaryDirectoryTestCase {

    private func configuration(backupRoot: URL) -> Configuration {
        Configuration(
            bundleIdentifier: "io.github.haiggoh.iphonebackup.tests",
            backupRoot: backupRoot,
            stagingRoot: root.appendingPathComponent("staging"),
            applicationSupportDirectory: root.appendingPathComponent("support")
        )
    }

    private func discovery(backupRoot: URL) -> BackupDiscovery {
        BackupDiscovery(configuration: configuration(backupRoot: backupRoot))
    }

    // MARK: Classifying why the root could not be read

    /// A folder that genuinely does not exist.
    func testAbsentRootIsReportedAsMissing() {
        let absent = root.appendingPathComponent("no-such-folder")

        guard case .failure(let problem) = discovery(backupRoot: absent).discover() else {
            return XCTFail("a non-existent backup root must fail")
        }
        XCTAssertEqual(problem, .backupRootMissing(path: absent.path))
    }

    /// The case that matters in the field, and the one `try?` could not distinguish.
    ///
    /// On a real Mac, `~/Library/Application Support/MobileSync/Backup` without Full
    /// Disk Access behaves like this: the directory is plainly there, `stat` succeeds,
    /// and only `opendir` is refused. Reported as unreadable it sends the user to the
    /// permissions pane; reported as missing or empty it sends them hunting for
    /// backups that exist and are simply blocked.
    func testUnreadableRootIsReportedAsUnreadableNotMissing() throws {
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        // root can read anything, so this can only be verified as a normal user.
        try XCTSkipIf(getuid() == 0, "runs as root; permission denial cannot be simulated")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        }

        // Precondition: the folder is visibly present, which is exactly why
        // fileExists cannot be used to classify this.
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))

        guard case .failure(let problem) = discovery(backupRoot: blocked).discover() else {
            return XCTFail("an unreadable backup root must fail")
        }
        XCTAssertEqual(problem, .backupRootUnreadable(path: blocked.path))
    }

    /// Readable and genuinely empty is a third, distinct state: no error, no
    /// candidates, and nothing to blame on permissions.
    func testEmptyReadableRootSucceedsWithNoCandidates() throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        guard case .success(let result) = discovery(backupRoot: empty).discover() else {
            return XCTFail("an empty but readable root is not a failure")
        }
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(result.directoriesSeen, 0)
    }

    // MARK: Selection

    func testPicksNewestCompleteBackupAndRecordsRejections() throws {
        let backupRoot = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 1_786_000_000)
        let newer = Date(timeIntervalSince1970: 1_786_100_000)

        try writeBackup(in: backupRoot, named: "aaa-older", date: older)
        try writeBackup(in: backupRoot, named: "bbb-newer", date: newer)
        // Deliberately unfinished, and deliberately the alphabetically last entry, so
        // that ordering by name rather than by completion date would pick it.
        try writeBackup(in: backupRoot, named: "zzz-unfinished", date: newer,
                        snapshotState: "uploading")

        guard case .success(let result) = discovery(backupRoot: backupRoot).discover() else {
            return XCTFail("discovery should succeed")
        }

        XCTAssertEqual(result.directoriesSeen, 3)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.first?.directoryName, "bbb-newer")
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections.first?.directoryName, "zzz-unfinished")
        XCTAssertEqual(result.rejections.first?.reason, .snapshotNotFinished(state: "uploading"))
        XCTAssertTrue(result.hasMultipleDevices)
    }

    /// One malformed backup must not hide a good one — the reason each directory is
    /// judged independently.
    func testAMalformedBackupDoesNotHideAValidOne() throws {
        let backupRoot = root.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // No Status.plist at all.
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try writeBackup(in: backupRoot, named: "good",
                        date: Date(timeIntervalSince1970: 1_786_100_000))

        guard case .success(let result) = discovery(backupRoot: backupRoot).discover() else {
            return XCTFail("discovery should succeed")
        }
        XCTAssertEqual(result.candidates.map(\.directoryName), ["good"])
        XCTAssertEqual(result.rejections.first?.reason, .statusPlistUnreadable)
    }

    func testNewestUnprocessedSkipsAlreadyRecordedBackups() throws {
        let backupRoot = root.appendingPathComponent("processed")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 1_786_000_000)
        let newer = Date(timeIntervalSince1970: 1_786_100_000)
        try writeBackup(in: backupRoot, named: "older", date: older)
        try writeBackup(in: backupRoot, named: "newer", date: newer)

        let subject = discovery(backupRoot: backupRoot)
        guard case .success(let result) = subject.discover() else {
            return XCTFail("discovery should succeed")
        }

        let store = BackupStateStore(url: root.appendingPathComponent("state.json"))
        let newest = try XCTUnwrap(subject.newestUnprocessed(in: result, store: store))
        XCTAssertEqual(newest.directoryName, "newer")

        try store.recordArchive(candidate: newest, archiveFilename: "a.zip", archiveSize: 2_000_000)

        // With the newest recorded, the next-newest becomes the candidate rather than
        // the run silently repeating itself.
        let next = try XCTUnwrap(subject.newestUnprocessed(in: result, store: store))
        XCTAssertEqual(next.directoryName, "older")
    }

    // MARK: Helper

    private func writeBackup(
        in parent: URL, named name: String, date: Date, snapshotState: String = "finished"
    ) throws {
        let dir = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let status: [String: Any] = [
            "SnapshotState": snapshotState,
            "BackupState": "new",
            "Date": date,
            "UUID": "00000000-0000-0000-0000-000000000000",
        ]
        try PropertyListSerialization
            .data(fromPropertyList: status, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Status.plist"))

        try Data("manifest".utf8).write(to: dir.appendingPathComponent("Manifest.db"))
        try PropertyListSerialization
            .data(fromPropertyList: ["Device Name": "Test iPhone"], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Info.plist"))
    }
}
