import AppKit
import IPhoneBackupCore
import SwiftUI

/// Manual mode only. Automatic mode never constructs an NSApplication at all, so
/// nothing here runs under a LaunchAgent.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let configuration: Configuration
    private let logger: AppLogger
    private var window: NSWindow!
    private var model: BackupViewModel!

    init(configuration: Configuration, logger: AppLogger) {
        self.configuration = configuration
        self.logger = logger
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings is deliberately absent until there is something to configure —
        // the provider picker and automation toggle. A menu item that opens an empty
        // window is worse than no menu item.
        MainMenu.install(applicationName: L("window.title"), showSettings: nil)

        model = BackupViewModel(configuration: configuration, logger: logger)

        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 190)

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
