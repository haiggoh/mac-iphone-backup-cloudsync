import AppKit
import Foundation
import IPhoneBackupCore

// The mode is decided before anything AppKit-related is touched.
//
// This ordering is the whole reason automatic mode is usable: a LaunchAgent runs
// every few minutes, and an app that creates a window and then hides it would steal
// focus each time. Creating no window at all is the only version that is invisible.
let mode = ApplicationMode.parse(arguments: CommandLine.arguments)
let configuration = Configuration.resolve()
let logger = AppLogger(subsystem: configuration.bundleIdentifier)

/// Assembles the object graph. Everything is injected so tests can substitute
/// temporary directories and fake clocks.
func makeController() -> AutomaticRunController {
    let validator = BackupCompletionValidator()
    return AutomaticRunController(
        configuration: configuration,
        discovery: BackupDiscovery(configuration: configuration, validator: validator),
        validator: validator,
        locator: CloudRootLocator(),
        archiver: BackupArchiver(configuration: configuration),
        store: BackupStateStore(url: configuration.stateURL),
        lock: ProcessLock(url: configuration.lockURL),
        logger: logger
    )
}

switch mode {

case .automatic:
    // No NSApplication, no activation policy, no window. The process does its work
    // and exits, which is what launchd expects.
    let result = makeController().run()

    let automation = logger.log(.automation)
    let description = String(describing: result)
    if result.isSuccess {
        automation.notice("automatic run finished: \(description, privacy: .public)")
    } else {
        automation.error("automatic run failed: \(description, privacy: .public)")
    }

    // Notifications are deliberately not sent from here. Posting one needs a running
    // NSApplication and an authorization prompt no background process can answer, so
    // an unattended run reports through the log and the state file instead. The
    // manual UI surfaces the last outcome.
    exit(result.exitCode)

case .checkOnly:
    // A diagnostic for a human at a terminal: says what an unattended run would do
    // right now, changes nothing, and does not block on the quiet period.
    let result = makeController().check()
    print(String(describing: result))
    // The state file first, because it is the channel that actually works. `log show`
    // needs administrator rights and otherwise fails with "Could not open local log
    // store: Operation not permitted", so offering it alone sends a standard user
    // after a command they cannot run.
    print("last run: \(configuration.stateURL.path)")
    print("logs:     \(logger.inspectionCommand)")
    print("          (needs admin rights; the state file above does not)")
    exit(result.exitCode)

case .installAutomation:
    let manager = LaunchAgentManager(configuration: configuration)
    let site = LaunchAgentManager.inspectInstallation(bundleURL: Bundle.main.bundleURL)
    do {
        // The path in the installed plist is derived from the running bundle here, at
        // install time. Nothing about this machine is committed to the repository.
        let state = try manager.install(bundleURL: Bundle.main.bundleURL)
        print("automation installed: \(state)")
        print("  plist:      \(manager.plistURL.path)")
        print("  runs:       \(site.executableURL.path) \(ApplicationMode.automaticFlag)")
        print("  interval:   \(LaunchAgentManager.defaultStartInterval)s")
        logger.log(.launchAgent).notice("automation installed")
        exit(0)
    } catch {
        // Say what is wrong specifically. "Installation failed" would leave the user
        // guessing between a bad location, a malformed plist and a launchd refusal.
        FileHandle.standardError.write(Data("automation NOT installed: \(error)\n".utf8))
        if case LaunchAgentError.unsuitableInstallation(let concerns) = error {
            for concern in concerns {
                FileHandle.standardError.write(Data("  \(concern)\n".utf8))
            }
            FileHandle.standardError.write(
                Data("  move the app to ~/Applications and try again\n".utf8))
        }
        logger.log(.launchAgent).error("automation install failed: \(String(describing: error))")
        exit(1)
    }

case .removeAutomation:
    let manager = LaunchAgentManager(configuration: configuration)
    do {
        try manager.uninstall()
        print("automation removed")
        logger.log(.launchAgent).notice("automation removed")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("automation NOT removed: \(error)\n".utf8))
        logger.log(.launchAgent).error("automation removal failed: \(String(describing: error))")
        exit(1)
    }

case .manual:
    let application = NSApplication.shared
    let delegate = AppDelegate(configuration: configuration, logger: logger)
    application.delegate = delegate
    // Keeps the delegate alive for the process lifetime; NSApplication holds its
    // delegate weakly.
    withExtendedLifetime(delegate) {
        application.run()
    }
}
