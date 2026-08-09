import XCTest
@testable import IPhoneBackupCore

final class BackupStateStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: BackupStateStore!
    private var storeURL: URL!

    override func setUpWithError() throws {
        let uniqueName = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("state.json")
        store = BackupStateStore(url: storeURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
        store = nil
        storeURL = nil
        tempDir = nil
    }

    private func candidate(_ name: String, date: Date) -> BackupCandidate {
        BackupCandidate(directoryURL: URL(fileURLWithPath: "/tmp/x"), directoryName: name,
                        completionDate: date, dateSource: .statusPlist)
    }

    func testLoadEmptyState() throws {
        let state = store.load()
        XCTAssertEqual(state.version, ProcessedState.currentVersion)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertNil(state.lastErrorNotice)
    }

    func testSaveLoadRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let record = ProcessedArchive(
            sourceIdentity: "test@2001-09-07_01-46-40",
            completionDate: date,
            dateSource: .statusPlist,
            origin: .archived,
            archiveFilename: "backup.ab",
            archiveSize: 12345,
            completedAt: date
        )
        let state = ProcessedState(records: [record])
        try store.save(state)

        let loaded = store.load()
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records[0], record)
    }

    func testLoadGarbageReturnsEmptyAndPreservesFile() throws {
        let garbage = "this is not json"
        try garbage.write(to: storeURL, atomically: true, encoding: .utf8)

        let state = store.load()
        XCTAssertEqual(state.version, ProcessedState.currentVersion)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertNil(state.lastErrorNotice)

        let contents = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertEqual(contents, garbage)
    }

    func testRecordArchiveStoresCorrectly() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let c = candidate("mybackup", date: date)
        try store.recordArchive(candidate: c, archiveFilename: "backup.ab", archiveSize: 100)

        let record = try XCTUnwrap(store.record(for: c.identity))
        XCTAssertEqual(record.origin, .archived)
        XCTAssertEqual(record.archiveFilename, "backup.ab")
        XCTAssertEqual(record.archiveSize, 100)
        XCTAssertTrue(store.hasProcessed(identity: c.identity))
    }

    func testRecordArchiveIdempotent() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let c = candidate("mybackup", date: date)
        try store.recordArchive(candidate: c, archiveFilename: "backup.ab", archiveSize: 100)
        try store.recordArchive(candidate: c, archiveFilename: "backup2.ab", archiveSize: 200)

        let state = store.load()
        let records = state.records.filter { $0.sourceIdentity == c.identity }
        XCTAssertEqual(records.count, 1)
        // Last write wins, deliberately. Re-archiving the same backup means the
        // file on disk is now the newer one, so keeping the earlier filename would
        // leave the state pointing at something that may no longer exist.
        XCTAssertEqual(records[0].archiveFilename, "backup2.ab")
        XCTAssertEqual(records[0].archiveSize, 200)
    }

    func testRecordArchiveTwoDifferentCandidates() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let c1 = candidate("backup1", date: date1)
        let c2 = candidate("backup2", date: date2)

        try store.recordArchive(candidate: c1, archiveFilename: "b1.ab", archiveSize: 100)
        try store.recordArchive(candidate: c2, archiveFilename: "b2.ab", archiveSize: 200)

        let state = store.load()
        XCTAssertEqual(state.records.count, 2)
        XCTAssertTrue(store.hasProcessed(identity: c1.identity))
        XCTAssertTrue(store.hasProcessed(identity: c2.identity))
    }

    func testBaselineStoresCorrectly() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let c = candidate("mybackup", date: date)
        try store.baseline(candidates: [c])

        let record = try XCTUnwrap(store.record(for: c.identity))
        XCTAssertEqual(record.origin, .baselinedAtFirstEnable)
        XCTAssertNil(record.archiveFilename)
        XCTAssertNil(record.archiveSize)
        XCTAssertTrue(store.hasProcessed(identity: c.identity))
    }

    func testBaselineDoesNotOverwriteArchived() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let c = candidate("mybackup", date: date)
        try store.recordArchive(candidate: c, archiveFilename: "backup.ab", archiveSize: 100)
        try store.baseline(candidates: [c])

        // Assert uniqueness FIRST. record(for:) returns the first match, so without
        // this a baseline that wrongly appended a duplicate would still look
        // correct — mutation testing caught exactly that blind spot.
        let all = store.load().records.filter { $0.sourceIdentity == c.identity }
        XCTAssertEqual(all.count, 1, "baseline must not append a second record")

        let record = try XCTUnwrap(store.record(for: c.identity))
        XCTAssertEqual(record.origin, .archived)
        XCTAssertNotNil(record.archiveFilename)
        XCTAssertEqual(record.archiveFilename, "backup.ab")
    }

    func testRecordForUnknownIdentity() throws {
        XCTAssertNil(store.record(for: "unknown"))
    }

    func testShouldNotifyTrueWhenNothingNotified() throws {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(store.shouldNotify(errorSignature: "sig1", now: now))
    }

    func testShouldNotifyFalseWithinWindow() throws {
        let now = Date(timeIntervalSince1970: 1000)
        try store.noteNotified(errorSignature: "sig1", now: now)
        let later = Date(timeIntervalSince1970: 1000 + 100)
        XCTAssertFalse(store.shouldNotify(errorSignature: "sig1", now: later, suppressFor: 3600))
    }

    func testShouldNotifyTrueAfterWindow() throws {
        let now = Date(timeIntervalSince1970: 1000)
        try store.noteNotified(errorSignature: "sig1", now: now)
        let farFuture = Date(timeIntervalSince1970: 1000 + 3601)
        XCTAssertTrue(store.shouldNotify(errorSignature: "sig1", now: farFuture, suppressFor: 3600))
    }

    func testShouldNotifyTrueForDifferentSignature() throws {
        let now = Date(timeIntervalSince1970: 1000)
        try store.noteNotified(errorSignature: "sig1", now: now)
        let later = Date(timeIntervalSince1970: 1000 + 100)
        XCTAssertTrue(store.shouldNotify(errorSignature: "sig2", now: later, suppressFor: 3600))
    }

    func testClearErrorNoticeResetsNotification() throws {
        let now = Date(timeIntervalSince1970: 1000)
        try store.noteNotified(errorSignature: "sig1", now: now)
        try store.clearErrorNotice()
        let later = Date(timeIntervalSince1970: 1000 + 100)
        XCTAssertTrue(store.shouldNotify(errorSignature: "sig1", now: later, suppressFor: 3600))
    }
}