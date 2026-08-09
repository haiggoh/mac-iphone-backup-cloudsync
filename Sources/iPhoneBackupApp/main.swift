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
    print("logs: \(logger.inspectionCommand)")
    exit(result.exitCode)

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
