import XCTest
@testable import IPhoneBackupCore

/// Guards the contract that lets the UI show a legible message instead of a raw enum
/// dump: every outcome has a code, and no code can ever carry a payload.
///
/// The bug these exist to prevent shipped once. The Automation section rendered
/// `String(describing:)` of the outcome, so a user saw
/// `configurationRequired(IPhoneBackupCore.ConfigurationProblem.backupRootUnreadable(
/// path: "/Users/<name>/Library/Application Support/MobileSync/Backup"))` — unlocalized,
/// and with their home path in it. `code` is the fix, and its whole value is that it
/// cannot contain that payload.
final class RunOutcomeCodeTests: XCTestCase {

    /// Every case, with payloads chosen to be obviously identifying. If a payload ever
    /// leaks into a code, these values make it unmistakable.
    private var everyOutcome: [AutomaticRunResult] {
        [
            .archived(URL(fileURLWithPath: "/Users/someone/Cloud/_iPhone-BU/backup.zip")),
            .nothingToDo,
            .alreadyRunning,
            .incompleteBackup(.snapshotNotFinished(state: "uploading")),
            .incompleteBackup(.manifestMissing),
            .incompleteBackup(.manifestUnreadable),
            .incompleteBackup(.statusPlistUnreadable),
            .incompleteBackup(.metadataStillChanging(fields: ["Info.plist"])),
            .incompleteBackup(.noCompletionDate),
            .incompleteBackup(.watchedFileEmpty(name: "Manifest.db")),
            .incompleteBackup(.stillSettling(newestAge: 10, required: 900)),
            .deferred(.insufficientBattery(secondsRemaining: 600, secondsNeeded: 1800)),
            .configurationRequired(.multipleCloudRootsNeedSelection(
                displayNames: ["OneDrive-Contoso", "OneDrive-Personal"])),
            .configurationRequired(.noCloudRootFound),
            .configurationRequired(.configuredCloudRootMissing(
                path: "/Volumes/Backups/_iPhone-BU")),
            .configurationRequired(.backupRootMissing(
                path: "/Users/someone/Library/Application Support/MobileSync/Backup")),
            .configurationRequired(.backupRootUnreadable(
                path: "/Users/someone/Library/Application Support/MobileSync/Backup")),
            .failed(.archiveToolFailed(exitCode: 1, stderrTail: "ditto: /Users/someone/x")),
            .failed(.archiveImplausiblySmall(bytes: 12)),
            .failed(.insufficientFreeSpace(availableBytes: 1, requiredBytes: 2)),
            .failed(.stagingUnavailable("/Users/someone/.iphone-backup-staging")),
            .failed(.finalMoveFailed("EXDEV", stagedArchivePath: "/Users/someone/staged.zip")),
            .failed(.stateWriteFailed("/Users/someone/Library/state.json")),
            .failed(.archiveAlreadyExistsWithoutState(
                path: "/Users/someone/Cloud/_iPhone-BU/backup.zip")),
        ]
    }

    func testEveryOutcomeHasANonEmptyCode() {
        for outcome in everyOutcome {
            XCTAssertFalse(outcome.code.isEmpty,
                           "no code for \(String(describing: outcome))")
        }
    }

    /// The point of the whole mechanism. A code is a lookup key and an on-disk value; a
    /// path, a device name or an account in one would be both a privacy leak and an
    /// unmatchable localization key.
    func testNoCodeCarriesItsPayload() {
        for outcome in everyOutcome {
            let code = outcome.code
            XCTAssertFalse(code.contains("/"), "code contains a path: \(code)")
            XCTAssertFalse(code.contains("someone"), "code contains a username: \(code)")
            XCTAssertFalse(code.contains("Contoso"), "code contains an account: \(code)")
            XCTAssertFalse(code.contains("("), "code looks interpolated: \(code)")
            XCTAssertFalse(code.contains("\""), "code looks interpolated: \(code)")
            XCTAssertFalse(code.contains(" "), "code contains a space: \(code)")
        }
    }

    /// Codes are how a stored record is understood later, so two different outcomes
    /// sharing one would silently show the wrong message for the rest of time.
    func testCodesAreDistinctPerCase() {
        let codes = everyOutcome.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count,
                       "duplicate codes in \(codes.sorted())")
    }

    /// The prefix is what groups outcomes for the UI, and it is part of the on-disk
    /// format. Asserting the literal strings is deliberate: a rename should fail here
    /// rather than quietly orphan every stored record and localization key.
    func testCodesUseTheDocumentedPrefixes() {
        XCTAssertEqual(AutomaticRunResult.nothingToDo.code, "nothingToDo")
        XCTAssertEqual(AutomaticRunResult.alreadyRunning.code, "alreadyRunning")
        XCTAssertEqual(
            AutomaticRunResult.incompleteBackup(.manifestMissing).code,
            "incomplete.manifestMissing")
        XCTAssertEqual(
            AutomaticRunResult.configurationRequired(.backupRootUnreadable(path: "/x")).code,
            "configuration.backupRootUnreadable")
        XCTAssertEqual(
            AutomaticRunResult.failed(.insufficientFreeSpace(
                availableBytes: 0, requiredBytes: 1)).code,
            "failed.insufficientFreeSpace")
        XCTAssertEqual(
            AutomaticRunResult.deferred(.insufficientBattery(
                secondsRemaining: nil, secondsNeeded: 1)).code,
            "deferred.insufficientBattery")
    }

    /// A code must not change with its payload, or a stored record would not match the
    /// same outcome seen live.
    func testCodeIsIndependentOfPayload() {
        let a = AutomaticRunResult.configurationRequired(.backupRootUnreadable(path: "/one"))
        let b = AutomaticRunResult.configurationRequired(.backupRootUnreadable(path: "/two"))
        XCTAssertEqual(a.code, b.code)
    }
}

/// The stored half of the same contract.
final class LastRunCodePersistenceTests: XCTestCase {
    private var tempDir: URL!
    private var store: BackupStateStore!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
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

    func testRecordRunPersistsTheCode() throws {
        let outcome = AutomaticRunResult.configurationRequired(
            .backupRootUnreadable(path: "/Users/someone/Library"))
        try store.recordRun(
            summary: String(describing: outcome),
            code: outcome.code,
            wasSuccess: outcome.isSuccess,
            wasAutomatic: true)

        let last = try XCTUnwrap(store.lastRun())
        XCTAssertEqual(last.code, "configuration.backupRootUnreadable")
        XCTAssertFalse(last.wasSuccess)
        // The developer-facing detail is still kept — it is what a bug report needs.
        XCTAssertTrue(last.summary.contains("backupRootUnreadable"))
    }

    /// A version-2 file has a `lastRun` with no `code`. It must still decode, and the
    /// missing code must read as absent rather than as an empty string, because the UI
    /// distinguishes "no details recorded" from a known outcome.
    func testVersion2RecordWithoutCodeStillDecodes() throws {
        let legacy = """
        {
          "version" : 2,
          "records" : [],
          "lastRun" : {
            "at" : "2026-08-10T00:19:00Z",
            "summary" : "configurationRequired(...)",
            "wasSuccess" : false,
            "wasAutomatic" : true
          }
        }
        """
        try legacy.write(to: storeURL, atomically: true, encoding: .utf8)

        let state = store.load()
        // Forward migration adopts the current version without discarding anything.
        XCTAssertEqual(state.version, ProcessedState.currentVersion)
        let last = try XCTUnwrap(state.lastRun)
        XCTAssertNil(last.code)
        XCTAssertFalse(last.wasSuccess)
        XCTAssertEqual(last.summary, "configurationRequired(...)")
    }

    func testLastRunRoundTripsThroughDisk() throws {
        let written = LastRun(
            at: Date(timeIntervalSince1970: 1_000_000),
            summary: "nothingToDo",
            code: "nothingToDo",
            wasSuccess: true,
            wasAutomatic: true)
        var state = store.load()
        state.lastRun = written
        try store.save(state)

        XCTAssertEqual(store.lastRun(), written)
    }
}
