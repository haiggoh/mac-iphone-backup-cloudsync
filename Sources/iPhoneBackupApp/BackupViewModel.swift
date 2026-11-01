import Foundation
import IPhoneBackupCore
import SwiftUI
@preconcurrency import UserNotifications

/// Drives the manual window.
///
/// Holds no archiving logic of its own — every decision comes from
/// IPhoneBackupCore, and this type's job is to move work off the main thread, turn
/// structured outcomes into text, and expose them as observable state.
@MainActor
final class BackupViewModel: ObservableObject {

    @Published var headline: String = ""
    @Published var status: String = ""
    @Published var percentage: Double = 0
    @Published var isRunning = false
    @Published var isError = false
    @Published var isReady = false
    @Published var finishedURL: URL?
    /// Populated when several distinct cloud roots exist and none is chosen yet.
    @Published var needsCloudSelection: [String] = []
    /// True when macOS blocked the read. Drives a button that opens the right
    /// System Settings pane, because Full Disk Access is not a permission the system
    /// will ever prompt for — without this the user is simply stuck.
    @Published var needsFullDiskAccess = false

    private let configuration: Configuration
    private let logger: AppLogger
    private let validator = BackupCompletionValidator()
    private let discovery: BackupDiscovery
    private let locator = CloudRootLocator()
    private let archiver: BackupArchiver
    private let store: BackupStateStore

    private var candidate: BackupCandidate?
    private var sourceBytes: Int64 = 0
    private var multipleDevices = false
    private var cancelRequested = false

    /// Set when the source backup is older than the staleness threshold — shown beside
    /// the action so what would be archived is visible BEFORE the click (roadmap: "say
    /// plainly that this archives an existing backup").
    @Published var staleWarning: String?
    /// Set when a manual run found the archive already exists: the UI turns this into
    /// the duplicate-replace CHOICE (duplicate.* strings) instead of a red error.
    @Published var pendingDuplicate = false
    /// Display name of the resolved destination root, for the duplicate dialog.
    @Published var destinationName: String = ""
    /// Source backup's completion date, formatted for the duplicate dialog.
    @Published var duplicateSourceDateText: String = ""

    init(configuration: Configuration, logger: AppLogger) {
        self.configuration = configuration
        self.logger = logger
        self.discovery = BackupDiscovery(configuration: configuration, validator: validator)
        self.archiver = BackupArchiver(configuration: configuration)
        self.store = BackupStateStore(url: configuration.stateURL)
        self.headline = L("status.searching")
    }

    // MARK: Discovery

    func discover() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Device names are wanted here: this is the one place a human is looking
            // at the screen, so the 58 MB Info.plist read is justified.
            let outcome = await self.discovery.discover(loadDeviceNames: true)

            switch outcome {
            case .failure(let problem):
                await self.logDiscovery("cannot search: \(problem.code)")
                await self.show(problem: problem)

            case .success(let result):
                // ONE selection for both paths: the newest candidate the state store has
                // not recorded yet. AutomaticRunController.check() uses this same function,
                // so "Jetzt prüfen" and a manual run can no longer disagree about whether
                // work exists (waypoint iphone-backup-jetzt-pruefen). With an empty store
                // this is candidates.first, so a fresh install still offers the existing
                // backup; once recorded, both paths report nothing-new instead.
                guard let picked = discovery.newestUnprocessed(in: result, store: store) else {
                    if result.candidates.isEmpty {
                        // An empty folder and a backup still in progress look identical
                        // from outside the process, so record which it was.
                        await self.logDiscovery(
                            result.rejections.first.map { "no candidate: \($0.logDescription)" }
                                ?? "no candidate: nothing present")
                        await self.show(
                            headline: L("status.noBackupPresent"),
                            status: result.rejections.isEmpty
                                ? L("status.emptyOrNoAccess")
                                : Presenter.text(for: result.rejections[0].reason),
                            isError: true)
                    } else if let settling = result.rejections.first(where: {
                        if case .stillSettling = $0.reason { return true }
                        return false
                    }) {
                        // Mirror check(): a still-settling backup is NEW work, just not
                        // ready — never show a bare "nothing new" in that case.
                        await self.logDiscovery("still settling: \(settling.logDescription)")
                        await self.show(
                            headline: L("status.nothingNew"),
                            status: Presenter.text(for: settling.reason),
                            isError: false)
                    } else {
                        await self.logDiscovery("no unprocessed candidate")
                        await self.show(
                            headline: L("status.nothingNew"),
                            status: L("run.nothingToDo"),
                            isError: false)
                    }
                    return
                }

                await self.logDiscovery("selected \(picked.logDescription)")
                await self.adopt(candidate: picked, multipleDevices: result.hasMultipleDevices)

                // du on a few hundred thousand files is slow, so it runs here rather
                // than blocking the click.
                let bytes: Int64
                do {
                    bytes = try self.archiver.sourceSizeBytes(of: picked.directoryURL)
                } catch {
                    logger.log(.automation).error("failed to measure source size: \(String(describing: error))")
                    await self.adopt(sourceBytes: 0)
                    return
                }
                await self.adopt(sourceBytes: bytes)
            }
        }
    }

    /// Records what discovery decided, so a manual run can be confirmed from outside
    /// the process.
    ///
    /// The automatic path reports its decisions this way already; the manual path
    /// reported only to the window, on the reasoning that a human is looking at it.
    /// That holds for the human and fails for everyone else: verifying the app could
    /// read the backups at all meant inferring it from the *absence* of a permissions
    /// alert, across repeated launches, because nothing positive was ever written.
    ///
    /// `.notice`, not `.debug`, per the level policy in `AppLogger`: this is a decision
    /// someone may need to read after the fact, and `.debug` does not survive the
    /// process. Once per discovery rather than per step, and `logDescription` rather
    /// than the raw directory name so pasted output carries no device identifiers.
    /// Prefixed, because the automatic path logs to this same category.
    private func logDiscovery(_ decision: String) {
        logger.log(.discovery).notice("manual: \(decision, privacy: .public)")
    }

    private func adopt(candidate: BackupCandidate, multipleDevices: Bool) {
        self.candidate = candidate
        self.multipleDevices = multipleDevices

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var line = candidate.deviceName ?? candidate.directoryName
        line += " — \(formatter.string(from: candidate.completionDate))"
        if let version = candidate.productVersion, !version.isEmpty {
            line += " · iOS \(version)"
        }
        headline = line
        status = L("status.determiningSize")

        // Staleness advisory: past 24 h the archived data is a day old or more, and the
        // user should connect the iPhone and back up in Finder first. A hint, never a
        // block — the run itself still works.
        let age = Date().timeIntervalSince(candidate.completionDate)
        if age > 24 * 3600 {
            let ageText = DateComponentsFormatter()
            ageText.unitsStyle = .short
            ageText.allowedUnits = [.day, .hour]
            staleWarning = L("warn.staleSource",
                             ageText.string(from: age) ?? "\(Int(age / 86400))d")
        } else {
            staleWarning = nil
        }
    }

    private func adopt(sourceBytes bytes: Int64) {
        sourceBytes = bytes
        status = L("status.readyToArchive", Presenter.bytes(bytes))
        isReady = true
    }

    private func show(problem: ConfigurationProblem) {
        switch problem {
        case .multipleCloudRootsNeedSelection(let names):
            needsCloudSelection = names
        case .backupRootUnreadable:
            needsFullDiskAccess = true
        default:
            break
        }
        show(headline: L("status.noBackupFolder"),
             status: Presenter.text(for: problem),
             isError: true)
    }

    /// Takes the user straight to the pane they need, then re-checks when they come
    /// back. Granting access does not restart the app, so without the re-check the
    /// window would keep showing the old error and look broken.
    func openFullDiskAccessSettings() {
        SystemSettingsLink.openFullDiskAccess()
    }

    func retryDiscovery() {
        needsFullDiskAccess = false
        isError = false
        headline = L("status.searching")
        status = ""
        discover()
    }

    private func show(headline: String, status: String, isError: Bool) {
        self.headline = headline
        self.status = status
        self.isError = isError
        self.isReady = false
    }

    // MARK: Running

    func start(replaceExisting: Bool = false) {
        guard let candidate, !isRunning else { return }

        cancelRequested = false
        isError = false
        finishedURL = nil
        isRunning = true
        percentage = 0
        status = L("status.creatingArchive")

        let filename = ArchiveNaming.filename(for: candidate, multipleDevices: multipleDevices)
        let policy: ConflictPolicy = replaceExisting ? .replace : .fail

        // Everything the background work needs is captured up front as plain values.
        // A detached task reaching back into this @MainActor type would need an
        // `await` on every single property access — noisy, and easy to get subtly
        // wrong. Only the UI updates below cross back onto the main actor.
        let configuration = self.configuration
        let locator = self.locator
        let archiver = self.archiver
        let bytes = self.sourceBytes

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let destinationRoot: URL
            switch locator.resolve(configuredPath: configuration.destinationRootOverride) {
            case .resolved(let root):
                destinationRoot = root.url
            case .ambiguous(let roots):
                await self.finish(failure: nil, problem:
                    .multipleCloudRootsNeedSelection(displayNames: roots.map(\.displayName)))
                return
            case .none:
                await self.finish(failure: nil, problem: .noCloudRootFound)
                return
            }

            let destination = destinationRoot
                .appendingPathComponent(configuration.destinationSubdirectory)

            let result = await archiver.archive(
                candidate: candidate,
                archiveFilename: filename,
                destinationFolder: destination,
                sourceBytes: bytes,
                conflictPolicy: policy,
                progress: { progress in
                    Task { @MainActor [weak self] in
                        self?.apply(progress)
                    }
                },
                isCancelled: { [weak self] in
                    // Reading @Published state from a background thread would be a
                    // data race; the flag is captured atomically enough for a
                    // cancel check because it only ever goes false -> true.
                    self?.cancelRequestedUnsafe ?? false
                }
            )

            switch result {
            case .success(let outcome):
                await self.finish(outcome: outcome, candidate: candidate)
            case .failure(let failure):
                // An existing archive is the DESIRED state, not a failure: turn it into
                // the replace choice (duplicate.* strings) instead of red error text.
                if case .archiveAlreadyExistsWithoutState = failure {
                    await self.logDiscovery("archive already exists — offering replace")
                    await MainActor.run {
                        self.pendingDuplicate = true
                        self.isRunning = false
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        formatter.timeStyle = .short
                        self.duplicateSourceDateText = formatter.string(from: candidate.completionDate)
                        if case .resolved(let root) = self.locator.resolve(
                            configuredPath: self.configuration.destinationRootOverride) {
                            self.destinationName = root.displayName
                        }
                    }
                    return
                }
                await self.finish(failure: failure, problem: nil)
            }
        }
    }

    /// Read from the archiver's polling thread. Deliberately a plain Bool rather
    /// than @Published state, which must only be touched on the main actor.
    nonisolated(unsafe) private var cancelRequestedUnsafe = false

    func cancel() {
        cancelRequested = true
        cancelRequestedUnsafe = true
        archiver.cancel()
        status = L("status.cancelling")
    }

    private func apply(_ progress: ArchiveProgress) {
        // Clamped short of 100 so the bar never claims completion before the move
        // and the checks have actually succeeded.
        percentage = min(max(progress.fraction * 100, 0.5), 99)

        var line = L("status.progressOf",
                     Presenter.bytes(progress.bytesWritten),
                     Presenter.bytes(sourceBytes))
        if progress.bytesPerSecond > 0 {
            line += " · \(Presenter.bytes(Int64(progress.bytesPerSecond)))/s"
        }
        if let remaining = progress.estimatedRemaining {
            line += " · \(L("status.remaining", Presenter.duration(remaining)))"
        }
        status = line
    }

    private func finish(outcome: ArchiveOutcome, candidate: BackupCandidate) {
        percentage = 100
        isRunning = false
        finishedURL = outcome.finalURL
        status = L("status.finished",
                   Presenter.bytes(outcome.sizeBytes),
                   Presenter.duration(outcome.duration))
        NSSound(named: "Glass")?.play()

        do {
            try store.recordArchive(
                candidate: candidate,
                archiveFilename: outcome.finalURL.lastPathComponent,
                archiveSize: outcome.sizeBytes)
            try store.clearErrorNotice()
        } catch {
            // The archive is safe; only the record failed. Say so rather than
            // reporting unqualified success.
            isError = true
            status = Presenter.text(for: .stateWriteFailed(String(describing: error)))
        }

        notify(title: L("notification.doneTitle"),
               body: L("notification.doneBody",
                       outcome.finalURL.lastPathComponent,
                       Presenter.bytes(outcome.sizeBytes)))
    }

    private func finish(failure: RunFailure?, problem: ConfigurationProblem?) {
        isRunning = false
        percentage = 0
        isError = true
        if cancelRequested {
            isError = false
            status = L("status.cancelled")
        } else if let failure {
            status = Presenter.text(for: failure)
        } else if let problem {
            status = Presenter.text(for: problem)
            if case .multipleCloudRootsNeedSelection(let names) = problem {
                needsCloudSelection = names
            }
        }
    }

    func revealInFinder() {
        guard let url = finishedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Notifications

    private func notify(title: String, body: String) {
        // Requires a bundle identifier; running the binary directly (not as an .app)
        // has none, and requesting authorization would trap.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            // Archiving must work whether or not notifications were allowed, so a
            // refusal is silently fine.
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
