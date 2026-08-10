import AppKit
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

        logger.log(.automation).debug("manual mode started")
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
