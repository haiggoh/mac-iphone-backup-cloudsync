import Foundation

/// Runs one unattended archive attempt and reports what happened.
///
/// Returns a value instead of touching any UI, so the same sequence backs
/// `--automatic`, `--check-only` and the manual "check now" button. The ordering of
/// the gates is deliberate: everything cheap and everything that could refuse comes
/// before anything expensive or destructive, so a poll with nothing to do costs a
/// handful of stat calls rather than a minute of waiting or a gigabyte of writing.
public final class AutomaticRunController {

    private let configuration: Configuration
    private let discovery: BackupDiscovery
    private let validator: BackupCompletionValidator
    private let locator: CloudRootLocator
    private let archiver: BackupArchiver
    private let store: BackupStateStore
    private let lock: ProcessLock
    private let powerMonitor: PowerMonitor
    private let logger: AppLogger
    private let clock: QuietPeriodClock
    private let now: () -> Date

    public init(
        configuration: Configuration,
        discovery: BackupDiscovery,
        validator: BackupCompletionValidator,
        locator: CloudRootLocator,
        archiver: BackupArchiver,
        store: BackupStateStore,
        lock: ProcessLock,
        powerMonitor: PowerMonitor = PowerMonitor(),
        logger: AppLogger,
        clock: QuietPeriodClock = SystemClock(),
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.discovery = discovery
        self.validator = validator
        self.locator = locator
        self.archiver = archiver
        self.store = store
        self.lock = lock
        self.powerMonitor = powerMonitor
        self.logger = logger
        self.clock = clock
        self.now = now
    }

    /// Reports what an unattended run *would* do, changing nothing.
    ///
    /// Deliberately stops short of the quiet period, because `--check-only` is a
    /// diagnostic a human runs impatiently, and blocking it for a minute to answer
    /// "is anything ready?" would make it useless.
    public func check() -> AutomaticRunResult {
        let discovered: DiscoveryResult
        switch discovery.discover(loadDeviceNames: false) {
        case .failure(let problem): return .configurationRequired(problem)
        case .success(let result): discovered = result
        }

        guard let candidate = discovery.newestUnprocessed(in: discovered, store: store) else {
            return .nothingToDo
        }

        if case .failure(let reason) = validator.validateCompletion(
            directory: candidate.directoryURL) {
            return .incompleteBackup(reason)
        }
        if case .failure(let reason) = validator.confirmSettled(
            directory: candidate.directoryURL,
            minimumAge: configuration.minimumSettleAge,
            now: now()
        ) {
            return .incompleteBackup(reason)
        }

        switch locator.resolve(configuredPath: configuration.destinationRootOverride) {
        case .none:
            return .configurationRequired(
                configuration.destinationRootOverride == nil
                    ? .noCloudRootFound
                    : .configuredCloudRootMissing(
                        path: configuration.destinationRootOverride ?? ""))
        case .ambiguous(let roots):
            return .configurationRequired(
                .multipleCloudRootsNeedSelection(displayNames: roots.map(\.displayName)))
        case .resolved:
            // Ready as far as a non-blocking check can tell.
            return .archived(candidate.directoryURL)
        }
    }

    /// Wraps `perform()` so every exit path leaves a durable record, including the
    /// early ones. A `defer` rather than a call at each `return`, because the whole
    /// point is that no path can forget.
    public func run() -> AutomaticRunResult {
        var outcome: AutomaticRunResult = .nothingToDo
        defer {
            do {
                try store.recordRun(
                    // Both: the code is what the UI shows, the description is what a
                    // bug report needs.
                    summary: String(describing: outcome),
                    code: outcome.code,
                    wasSuccess: outcome.isSuccess,
                    wasAutomatic: true,
                    now: now())
            } catch {
                // Best-effort: failing to record the run must not change what the run
                // itself reported, or a bookkeeping hiccup would mask a real result.
                logger.log(.automation).error(
                    "could not record the run outcome: \(String(describing: error))")
            }
        }
        outcome = perform()
        return outcome
    }

    private func perform() -> AutomaticRunResult {
        let automation = logger.log(.automation)

        // The lock comes first so two overlapping launches cannot both spend a
        // minute waiting out the quiet period before discovering each other.
        do {
            guard try lock.acquire() == .acquired else {
                automation.notice("another instance holds the lock; exiting successfully")
                return .alreadyRunning
            }
        } catch {
            automation.error("could not acquire the run lock: \(String(describing: error))")
            return .failed(.stagingUnavailable("could not acquire the run lock"))
        }
        defer { lock.release() }

        // MARK: Find something to do

        let discovered: DiscoveryResult
        switch discovery.discover(loadDeviceNames: false) {
        case .failure(let problem):
            logger.log(.discovery).error("discovery failed: \(String(describing: problem))")
            return .configurationRequired(problem)
        case .success(let result):
            discovered = result
        }

        for rejection in discovered.rejections {
            logger.log(.completion).debug("\(rejection.logDescription, privacy: .public)")
        }

        guard let candidate = discovery.newestUnprocessed(in: discovered, store: store) else {
            automation.notice("nothing to do: no unprocessed complete backup")
            return .nothingToDo
        }
        logger.log(.discovery).notice("selected \(candidate.logDescription, privacy: .public)")

        // MARK: Is it actually finished?

        switch validator.confirmReadyToArchive(
            directory: candidate.directoryURL,
            minimumSettleAge: configuration.minimumSettleAge,
            quietPeriod: configuration.quietPeriod,
            clock: clock,
            now: now
        ) {
        case .failure(let reason):
            logger.log(.completion).notice(
                "not ready: \(String(describing: reason), privacy: .public)")
            return .incompleteBackup(reason)
        case .success:
            break
        }

        // MARK: Where does it go?
        //
        // Resolved BEFORE the archive is built. Creating a 50 GB zip and only then
        // discovering there is nowhere to put it would waste a quarter of an hour
        // and leave the staging directory full.

        let destination: URL
        switch locator.resolve(configuredPath: configuration.destinationRootOverride) {
        case .none:
            let problem: ConfigurationProblem = configuration.destinationRootOverride == nil
                ? .noCloudRootFound
                : .configuredCloudRootMissing(path: configuration.destinationRootOverride ?? "")
            logger.log(.cloud).error("no destination: \(String(describing: problem), privacy: .public)")
            return .configurationRequired(problem)
        case .ambiguous(let roots):
            // Never guess which account a 50 GB archive belongs in.
            logger.log(.cloud).error("\(roots.count) distinct cloud roots; selection required")
            return .configurationRequired(
                .multipleCloudRootsNeedSelection(displayNames: roots.map(\.displayName)))
        case .resolved(let root):
            destination = root.url.appendingPathComponent(configuration.destinationSubdirectory)
        }

        // MARK: Can we finish?

        let sourceBytes = archiver.sourceSizeBytes(of: candidate.directoryURL)

        if case .insufficientBattery(let remaining, let needed) = powerMonitor.verdict(
            forSourceBytes: sourceBytes
        ) {
            automation.notice("deferring: battery would not outlast the job")
            return .deferred(.insufficientBattery(
                secondsRemaining: remaining, secondsNeeded: needed))
        }

        // MARK: Archive

        let filename = ArchiveNaming.filename(
            for: discovered.hasMultipleDevices
                // Only now is the expensive read justified, and only to keep
                // filenames unique across devices.
                ? withDeviceName(candidate)
                : candidate,
            multipleDevices: discovered.hasMultipleDevices
        )

        let outcome: ArchiveOutcome
        switch archiver.archive(
            candidate: candidate,
            archiveFilename: filename,
            destinationFolder: destination,
            sourceBytes: sourceBytes,
            // Unattended runs never overwrite. An existing file the state file does
            // not know about may be the user's only copy.
            conflictPolicy: .fail
        ) {
        case .failure(let failure):
            logger.log(.archive).error("archive failed: \(String(describing: failure), privacy: .public)")
            return .failed(failure)
        case .success(let result):
            outcome = result
        }

        // MARK: Only now is it processed

        do {
            try store.recordArchive(
                candidate: candidate,
                archiveFilename: outcome.finalURL.lastPathComponent,
                archiveSize: outcome.sizeBytes,
                now: now()
            )
            // A success clears the suppression record, so the next failure is
            // reported promptly instead of being swallowed by a stale window.
            try store.clearErrorNotice()
        } catch {
            // The archive is safely in place; only the bookkeeping failed. Reported
            // as a failure because the next run would otherwise archive it again.
            logger.log(.automation).error("state write failed: \(String(describing: error))")
            return .failed(.stateWriteFailed(String(describing: error)))
        }

        logger.log(.archive).notice(
            "archived \(outcome.sizeBytes) bytes in \(Int(outcome.duration))s")

        // Advisory only, and after the fact — it can never block or delete.
        let retention = ArchiveRetention(fileManager: .default)
            .report(in: destination, keep: configuration.archivesToKeep)
        if retention.needsAttention {
            // One interpolated literal, not a concatenation: os.Logger takes an
            // OSLogMessage, and `"a" + "b"` collapses to a plain String first.
            let excessCount = retention.excess.count
            let kept = configuration.archivesToKeep
            let bytes = retention.excessBytes
            logger.log(.retention).notice(
                "\(excessCount) archive(s) beyond the \(kept) kept, using \(bytes) bytes — nothing was deleted")
        }

        return .archived(outcome.finalURL)
    }

    /// Re-reads the candidate with its device name populated. Costs a 58 MB plist
    /// parse, so it happens only when several devices make it necessary.
    private func withDeviceName(_ candidate: BackupCandidate) -> BackupCandidate {
        let info = validator.readInfo(in: candidate.directoryURL)
        return BackupCandidate(
            directoryURL: candidate.directoryURL,
            directoryName: candidate.directoryName,
            deviceName: info.deviceName,
            productVersion: info.productVersion,
            completionDate: candidate.completionDate,
            dateSource: candidate.dateSource,
            snapshotState: candidate.snapshotState,
            backupUUID: candidate.backupUUID
        )
    }
}
