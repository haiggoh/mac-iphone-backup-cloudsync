import XCTest
@testable import IPhoneBackupCore

/// Regression tests for the behaviour observed on real hardware on 2026-08-07,
/// while a backup ran over Wi-Fi. Recorded transitions:
///
///     11:14:56  SnapshotState = uploading
///     11:35:00  SnapshotState = moving
///     11:35:03  SnapshotState = removing   (Manifest.db grew by ~700 KB)
///     11:35:06  SnapshotState = finished
///     11:38:59  Info.plist truncated to 0 bytes      <- 3m53s AFTER "finished"
///     11:39:02  Info.plist rewritten, 57,925,376 bytes
///
/// Two conclusions, both of which invalidated the original design:
///
/// 1. `SnapshotState == finished` is not sufficient. There is a window minutes
///    later in which Info.plist is empty, so an archive taken on that signal alone
///    contains a 0-byte Info.plist and cannot be restored — while every other
///    signal reports success.
/// 2. A 60-second two-sample quiet period is not sufficient either. Sampling at
///    11:35:06 and 11:36:06 sees no change, because both samples fall in the lull
///    *before* the rewrite.
///
/// What does hold is requiring the newest write to be older than the longest
/// observed lag, plus rejecting zero-length files outright.
final class LateRewriteRegressionTests: TemporaryDirectoryTestCase {

    private let validator = BackupCompletionValidator()

    /// 11:38:59 in the timeline above.
    func testZeroLengthInfoPlistIsRejectedEvenWhenStateSaysFinished() throws {
        let dir = try makeBackup(named: "zero-info")
        try Data().write(to: dir.appendingPathComponent("Info.plist"))

        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a 0-byte Info.plist must be rejected despite SnapshotState=finished")
        }
        XCTAssertEqual(reason, .watchedFileEmpty(name: "Info.plist"))
    }

    func testZeroLengthManifestIsRejected() throws {
        let dir = try makeBackup(named: "zero-manifest")
        try Data().write(to: dir.appendingPathComponent("Manifest.db"))

        guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
            return XCTFail("a 0-byte Manifest.db must be rejected")
        }
        XCTAssertEqual(reason, .watchedFileEmpty(name: "Manifest.db"))
    }

    /// The states discovered by observation. None of them is `finished`, so all
    /// must be refused — the point being that an unrecognised state is refused by
    /// default rather than optimistically accepted.
    func testEveryObservedNonFinishedStateIsRefused() throws {
        for state in ["uploading", "moving", "removing", "new", "somethingNobodyHasSeenYet"] {
            let dir = try makeBackup(named: "state-\(state)", snapshotState: state)
            guard case .failure(let reason) = validator.validateCompletion(directory: dir) else {
                return XCTFail("SnapshotState=\(state) must not be treated as complete")
            }
            XCTAssertEqual(reason, .snapshotNotFinished(state: state))
        }
    }

    // MARK: The settle-age gate

    func testRecentlyWrittenBackupIsNotYetSettled() throws {
        let dir = try makeBackup(named: "just-written")
        // Fixtures are written now, so the newest mtime is ~0 seconds old.
        guard case .failure(let reason) = validator.confirmSettled(
            directory: dir, minimumAge: 360
        ) else {
            return XCTFail("a backup written seconds ago must not count as settled")
        }
        guard case .stillSettling(let age, let required) = reason else {
            return XCTFail("expected stillSettling, got \(reason)")
        }
        XCTAssertLessThan(age, 60)
        XCTAssertEqual(required, 360)
    }

    func testBackupUntouchedForLongEnoughIsSettled() throws {
        let dir = try makeBackup(named: "old-enough")
        // Rather than sleeping, ask the question as if it were later.
        let later = Date().addingTimeInterval(600)

        guard case .success = validator.confirmSettled(
            directory: dir, minimumAge: 360, now: later
        ) else {
            return XCTFail("nothing written for 10 minutes must count as settled")
        }
    }

    /// The decisive test. Reproduces the real timeline: at 11:36:06 the backup says
    /// finished, nothing has changed for a minute, and the naive checks all pass —
    /// yet the truncation is still three minutes away. Only the settle-age gate
    /// refuses, and refusing is correct.
    func testTheExactWindowThatWouldHaveProducedACorruptArchive() throws {
        let dir = try makeBackup(named: "the-trap")

        let finishedAt = Date(timeIntervalSince1970: 1_786_095_306)   // 11:35:06
        let naiveDecisionPoint = finishedAt.addingTimeInterval(60)    // 11:36:06

        // Make the fixture look as it did at 11:35:06.
        for name in BackupCompletionValidator.watchedFiles {
            try FileManager.default.setAttributes(
                [.modificationDate: finishedAt],
                ofItemAtPath: dir.appendingPathComponent(name).path)
        }

        // Completion: passes. It really did say finished.
        guard case .success = validator.validateCompletion(directory: dir) else {
            return XCTFail("precondition: the fixture should look complete")
        }

        // Two-sample stability with an immediate clock: also passes, because
        // nothing changes during the lull. This is exactly why it was not enough.
        guard case .success = validator.confirmStable(
            directory: dir, quietPeriod: 60, clock: ImmediateClock()
        ) else {
            return XCTFail("precondition: the quiet period alone does pass here")
        }

        // The gate that actually saves the archive.
        guard case .failure(let reason) = validator.confirmReadyToArchive(
            directory: dir,
            minimumSettleAge: 360,
            quietPeriod: 60,
            clock: ImmediateClock(),
            now: { naiveDecisionPoint }
        ) else {
            return XCTFail("archiving 60s after 'finished' must be refused — Apple "
                + "truncated Info.plist 3m53s later")
        }
        guard case .stillSettling = reason else {
            return XCTFail("expected stillSettling, got \(reason)")
        }
    }

    /// Both real observations, as data. If the gate is ever lowered below either
    /// measured lag, this fails and says which run it would have broken.
    ///
    ///     transport            backup took    finished -> Info.plist rewritten
    ///     Wi-Fi   2026-08-07   ~20 min        235 s
    ///     USB/TB4 2026-08-08   ~5 min         150 s
    ///
    /// The lag does not scale with transfer speed — 4x faster overall, only ~1.6x
    /// shorter tail — so it behaves like fixed post-processing, which is why a single
    /// fixed threshold is a reasonable shape for this gate at all.
    func testGateExceedsEveryObservedRewriteLag() throws {
        let observations: [(transport: String, lagSeconds: TimeInterval)] = [
            ("Wi-Fi 2026-08-07", 235),
            ("USB/TB4 2026-08-08", 150),
        ]

        for observation in observations {
            let dir = try makeBackup(named: "lag-\(observation.lagSeconds)")
            let finishedAt = Date(timeIntervalSince1970: 1_786_179_846)
            for name in BackupCompletionValidator.watchedFiles {
                try FileManager.default.setAttributes(
                    [.modificationDate: finishedAt],
                    ofItemAtPath: dir.appendingPathComponent(name).path)
            }

            // At the moment Apple actually rewrote Info.plist, the gate must still
            // be refusing — otherwise the archive would capture a file mid-write.
            let atRewrite = finishedAt.addingTimeInterval(observation.lagSeconds)
            let result = validator.confirmReadyToArchive(
                directory: dir,
                minimumSettleAge: Configuration.defaultMinimumSettleAge,
                quietPeriod: 60,
                clock: ImmediateClock(),
                now: { atRewrite }
            )
            guard case .failure(.stillSettling) = result else {
                return XCTFail(
                    "gate of \(Configuration.defaultMinimumSettleAge)s would have archived "
                    + "at the exact moment of the \(observation.transport) rewrite "
                    + "(\(observation.lagSeconds)s after 'finished')")
            }
        }
    }

    /// And once the real lag has elapsed, it does proceed — the gate must not be
    /// so strict that nothing is ever archived.
    func testArchivesOnceTheObservedLagHasComfortablyPassed() throws {
        let dir = try makeBackup(named: "ready")
        let finishedAt = Date(timeIntervalSince1970: 1_786_095_306)
        for name in BackupCompletionValidator.watchedFiles {
            try FileManager.default.setAttributes(
                [.modificationDate: finishedAt],
                ofItemAtPath: dir.appendingPathComponent(name).path)
        }

        guard case .success(let status) = validator.confirmReadyToArchive(
            directory: dir,
            minimumSettleAge: 360,
            quietPeriod: 60,
            clock: ImmediateClock(),
            now: { finishedAt.addingTimeInterval(600) }
        ) else {
            return XCTFail("a backup untouched for 10 minutes must be archivable")
        }
        XCTAssertEqual(status.snapshotState, "finished")
    }
}
