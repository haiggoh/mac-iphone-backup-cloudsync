import AppKit
import Combine
import IPhoneBackupCore
import SwiftUI

/// Manual mode only. Automatic mode never constructs an NSApplication at all, so
/// nothing here runs under a LaunchAgent.
/// Manual mode only. Automatic mode never constructs an NSApplication, so nothing here
/// runs under a LaunchAgent.
///
/// Deliberately NOT `@MainActor`, even though every callback arrives on the main
/// thread: annotating it means `main.swift`'s top-level code — which is nonisolated —
/// can no longer construct it, and the obvious escape hatch,
/// `MainActor.assumeIsolated`, requires macOS 14 while this app targets 13.0. So the
/// hop onto the main actor is made explicitly where it is needed.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let configuration: Configuration
    private let logger: AppLogger
    private var window: NSWindow!
    private var model: BackupViewModel!
    private var automation: AutomationViewModel!

    /// Retained, or the subscriptions below are cancelled the moment they are made.
    private var cancellables: Set<AnyCancellable> = []

    /// Full Disk Access guidance is offered at most once per launch, suppressed only in
    /// memory.
    ///
    /// Nothing is written to disk on purpose. A user who dismissed this once has not
    /// dismissed it for ever — the denial is a live condition they may fix and re-break
    /// (every ad-hoc rebuild re-breaks it), so a later launch should be free to say so
    /// again. Persisting "do not ask again" would silently strand the next denial.
    private var hasOfferedFullDiskAccessGuidance = false

    /// Set when a denial arrives while a sheet is already up. The alert is a sheet too,
    /// and two sheets on one window is a race, not a stack.
    private var fullDiskAccessGuidancePending = false

    init(configuration: Configuration, logger: AppLogger) {
        self.configuration = configuration
        self.logger = logger
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings now has something to point at: the documented JSON file. The menu
        // item reveals it rather than opening a preferences window that would just
        // duplicate the Automation section already in the main window.
        MainMenu.install(applicationName: L("window.title"),
                         showSettings: #selector(revealSettings))

        model = BackupViewModel(configuration: configuration, logger: logger)
        automation = AutomationViewModel(configuration: configuration, logger: logger)

        let hosting = NSHostingView(
            rootView: ContentView(model: model, automation: automation))
        // Taller now that the Automation section is present; SwiftUI sizes the content
        // and the window follows, but the initial frame should not clip it.
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 400)

        window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("window.title")
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Explicit hop, per this type's deliberate non-`@MainActor` design: the published
        // projections below are main-actor isolated.
        //
        // Subscribing a runloop turn later is harmless, and slightly safer: Combine
        // delivers the current value on subscribe, so a denial that has *already* been
        // published still arrives rather than being missed.
        Task { @MainActor [weak self] in
            self?.observeFullDiskAccessDenial()
        }

        logger.log(.automation).debug("manual mode started")
    }

    // MARK: Full Disk Access guidance

    /// Watches the *existing* denial state rather than probing for permission again.
    ///
    /// `BackupViewModel.needsFullDiskAccess` is already set from the authoritative path —
    /// `BackupDiscovery` failing to read the backup root and classifying it as
    /// `backupRootUnreadable`. A second probe here would be a different question asked a
    /// different way, and could disagree with what the window is showing.
    ///
    /// Subscribed rather than driven from a SwiftUI `body`: presenting an alert as a side
    /// effect of rendering fires again on every recomputation.
    @MainActor
    private func observeFullDiskAccessDenial() {
        // `removeDuplicates` is what makes this a *transition*: SwiftUI republishing the
        // same `true` must not produce a second alert, while a genuine false -> true
        // after the user re-broke access must.
        model.$needsFullDiskAccess
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestFullDiskAccessGuidance()
                }
            }
            .store(in: &cancellables)

        // First-run setup finishing is the moment a queued alert becomes presentable.
        automation.$isFirstRun
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.presentQueuedFullDiskAccessGuidance()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func requestFullDiskAccessGuidance() {
        guard !hasOfferedFullDiskAccessGuidance else { return }

        // Queue behind first-run setup. Denial during setup is likely — the app is
        // reading the backup folder for the first time — and interrupting the sheet that
        // asks where archives go would be the wrong order to answer two questions in.
        if automation?.isFirstRun == true || window?.attachedSheet != nil {
            fullDiskAccessGuidancePending = true
            return
        }

        presentFullDiskAccessAlert()
    }

    @MainActor
    private func presentQueuedFullDiskAccessGuidance(isRetry: Bool = false) {
        guard fullDiskAccessGuidancePending, !hasOfferedFullDiskAccessGuidance else { return }

        // A sheet dismissal is animated, so `attachedSheet` can still be set for a moment
        // after `isFirstRun` flips. One bounded retry, never a poll: if a sheet is somehow
        // still up after that, the alert is dropped and the inline guidance in the window
        // — which is always visible for this condition — remains the route out.
        if window?.attachedSheet != nil {
            guard !isRetry else {
                logger.log(.permissions).notice(
                    "skipped the Full Disk Access alert: a sheet is still attached")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.presentQueuedFullDiskAccessGuidance(isRetry: true)
            }
            return
        }

        // Read the state, do not re-run discovery. If access was granted while the sheet
        // was up there is nothing left to tell the user.
        guard model?.needsFullDiskAccess == true else {
            fullDiskAccessGuidancePending = false
            return
        }

        presentFullDiskAccessAlert()
    }

    /// Supplements the inline controls, which stay visible either way. The alert exists
    /// because Full Disk Access is not promptable: macOS shows nothing at all, so an
    /// app that does not speak up leaves the user staring at an empty list.
    @MainActor
    private func presentFullDiskAccessAlert() {
        hasOfferedFullDiskAccessGuidance = true
        fullDiskAccessGuidancePending = false

        let alert = NSAlert()
        alert.messageText = L("permissions.alertTitle")
        alert.informativeText = L("permissions.alertMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("permissions.alertOpenSettings"))
        alert.addButton(withTitle: L("permissions.alertNotNow"))

        logger.log(.permissions).notice("offering Full Disk Access guidance")

        // Settings is opened only on the button, never as a side effect of the alert
        // appearing — an app that yanks the user into System Settings unasked is worse
        // than one that stays quiet.
        let openSettingsIfChosen: (NSApplication.ModalResponse) -> Void = { [logger] response in
            guard response == .alertFirstButtonReturn else {
                logger.log(.permissions).notice("Full Disk Access guidance dismissed")
                return
            }
            SystemSettingsLink.openFullDiskAccess()
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: openSettingsIfChosen)
        } else {
            // Only reachable in manual mode with no usable window, which should not
            // happen after launch — but a modal is better than silently doing nothing.
            openSettingsIfChosen(alert.runModal())
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Settings are a documented JSON file rather than a preferences window, so the
    /// menu item reveals it. Honest about what exists instead of opening an empty pane.
    @objc func revealSettings() {
        // Menu actions already arrive on the main thread; the hop is what lets the
        // compiler verify the main-actor-isolated call rather than taking it on trust.
        Task { @MainActor [weak self] in
            self?.automation?.revealSettingsFile()
        }
    }

    /// Refuses to quit mid-archive without asking. Terminating during `ditto` leaves
    /// a partial file in staging, and the user almost certainly meant to close the
    /// window rather than abandon a 15-minute job.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isRunning == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = L("quit.title")
        alert.informativeText = L("quit.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("quit.stopAndQuit"))
        alert.addButton(withTitle: L("quit.keepRunning"))

        if alert.runModal() == .alertFirstButtonReturn {
            model.cancel()
            return .terminateNow
        }
        return .terminateCancel
    }
}
