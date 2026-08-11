import Foundation
import IPhoneBackupCore
import SwiftUI

/// Backs the Automation section and the first-run destination picker.
///
/// Kept separate from BackupViewModel because the two answer different questions —
/// "what is happening to this backup right now" versus "how is this app configured" —
/// and mixing them made the archiving path depend on settings state it does not need.
@MainActor
final class AutomationViewModel: ObservableObject {

    // MARK: First run

    @Published var isFirstRun = false
    /// Providers that were actually found on this machine, with the roots each
    /// resolved to. Only these are offered; listing a provider the user does not have
    /// invites them to pick something that cannot work.
    @Published var discoveredProviders: [DiscoveredProvider] = []
    @Published var selectedProvider: CloudProvider?
    @Published var selectedRootPath: String?
    /// Honest warnings for the selected provider, e.g. iCloud evicting local copies.
    @Published var providerCaveats: [CloudArchiveCaveat] = []

    // MARK: Automation

    @Published var automationState: LaunchAgentState = .notInstalled
    @Published var intervalMinutes: Int = 5
    @Published var lastRunDescription: String = ""
    /// Whether the last outcome is one the user has to do something about.
    ///
    /// Mirrors `AutomaticRunResult.isSuccess`, which already draws the line in the right
    /// place: "no new backup" and "not settled yet" are normal and must not be dressed
    /// up as failures, while a missing permission or a failed archive must stand out.
    /// Without this every outcome rendered identically, so a routine check looked as
    /// alarming as a real problem.
    @Published var lastRunNeedsAttention = false
    @Published var lastArchiveDescription: String = ""
    @Published var retentionWarning: String?
    @Published var automationError: String?

    struct DiscoveredProvider: Identifiable, Equatable {
        var id: String { rootPath }
        let provider: CloudProvider
        let displayName: String
        let rootPath: String
    }

    private let configuration: Configuration
    private let logger: AppLogger
    private let locator = CloudRootLocator()
    private let agent: LaunchAgentManager
    private let settings: SettingsStore
    private let store: BackupStateStore

    init(configuration: Configuration, logger: AppLogger) {
        self.configuration = configuration
        self.logger = logger
        self.agent = LaunchAgentManager(configuration: configuration)
        self.settings = configuration.settingsStore
        self.store = BackupStateStore(url: configuration.stateURL)
    }

    // MARK: Loading

    func refresh() {
        let current = settings.load()
        isFirstRun = current.needsFirstRunSetup
        selectedProvider = current.cloudProvider
        selectedRootPath = current.cloudRootPath
        intervalMinutes = max(1, current.automationIntervalSeconds / 60)
        providerCaveats = current.cloudProvider?.largeArchiveCaveats ?? []

        // Asked of launchd, not read from settings. If they disagree, something
        // outside the app changed it, and the UI should show what is actually true.
        automationState = agent.currentState()
        if current.automationEnabled, automationState != .installedAndLoaded {
            automationError = L("automation.mismatch")
        }

        if isFirstRun { discoverProviders() }
        loadHistory()
    }

    private func discoverProviders() {
        var found: [DiscoveredProvider] = []
        for provider in CloudProvider.discoverable {
            for root in CloudRootLocator(providers: [provider]).discover() {
                found.append(DiscoveredProvider(
                    provider: provider,
                    displayName: "\(provider.displayName) — \(root.displayName)",
                    rootPath: root.url.path))
            }
        }
        discoveredProviders = found
    }

    /// The two lines that make an unattended tool trustworthy: when it last looked,
    /// and what happened. Read from the state file rather than the unified log, which
    /// needs admin rights to read on a managed Mac.
    private func loadHistory() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        if let last = store.lastRun() {
            // From the stored code, never from `summary` — that is a raw Swift enum
            // dump complete with a home-folder path, and it was reaching the UI.
            lastRunDescription = L("automation.lastCheck",
                                   formatter.string(from: last.at),
                                   Presenter.text(forRunCode: last.code))
            lastRunNeedsAttention = !last.wasSuccess
        } else {
            lastRunDescription = L("automation.neverRun")
            lastRunNeedsAttention = false
        }

        let archived = store.load().records
            .filter { $0.origin == .archived }
            .max(by: { $0.completedAt < $1.completedAt })
        if let archived, let filename = archived.archiveFilename {
            lastArchiveDescription = L("automation.lastArchive",
                                      formatter.string(from: archived.completedAt),
                                      filename)
        } else {
            lastArchiveDescription = L("automation.noArchiveYet")
        }
    }

    // MARK: First-run choices

    func select(_ discovered: DiscoveredProvider) {
        selectedProvider = discovered.provider
        selectedRootPath = discovered.rootPath
        providerCaveats = discovered.provider.largeArchiveCaveats
    }

    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("firstRun.chooseFolder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedProvider = .custom
        selectedRootPath = url.path
        providerCaveats = CloudProvider.custom.largeArchiveCaveats
    }

    /// Completes first-run setup. Automation is NOT enabled here — it is offered
    /// separately and declining must be a normal outcome, not an unfinished setup.
    func confirmFirstRun() {
        guard let provider = selectedProvider else { return }
        do {
            _ = try settings.update {
                $0.cloudProvider = provider
                $0.cloudRootPath = selectedRootPath
            }
            isFirstRun = false
            logger.log(.cloud).notice("destination chosen: \(provider.rawValue, privacy: .public)")
        } catch {
            automationError = String(describing: error)
        }
    }

    // MARK: Automation control

    func enableAutomation() {
        automationError = nil
        do {
            // Baseline first. Enabling a checkbox must not start a surprise 50 GB
            // upload of a backup taken days ago, so anything already finished is
            // recorded as processed before the agent can look at it.
            try baselineExistingBackups()

            let state = try agent.install(
                bundleURL: Bundle.main.bundleURL,
                startInterval: max(60, intervalMinutes * 60))
            _ = try settings.update {
                $0.automationEnabled = true
                $0.automationIntervalSeconds = max(60, self.intervalMinutes * 60)
            }
            automationState = state
            loadHistory()
            logger.log(.launchAgent).notice("automation enabled")
        } catch {
            automationError = Presenter.text(forAgentError: error)
            // Settings are not flipped on a failure, so the UI cannot claim automation
            // is on when no agent is loaded.
            automationState = agent.currentState()
            logger.log(.launchAgent).error("enable failed: \(String(describing: error))")
        }
    }

    func disableAutomation() {
        automationError = nil
        do {
            try agent.uninstall()
            _ = try settings.update { $0.automationEnabled = false }
            automationState = agent.currentState()
            logger.log(.launchAgent).notice("automation disabled")
        } catch {
            automationError = Presenter.text(forAgentError: error)
            automationState = agent.currentState()
        }
    }

    private func baselineExistingBackups() throws {
        let validator = BackupCompletionValidator()
        let discovery = BackupDiscovery(configuration: configuration, validator: validator)
        guard case .success(let result) = discovery.discover() else { return }
        try store.baseline(candidates: result.candidates)
    }

    /// Runs a check immediately, so enabling automation can be confirmed to work
    /// rather than waiting up to five minutes to find out.
    func checkNow() {
        let validator = BackupCompletionValidator()
        let controller = AutomaticRunController(
            configuration: configuration,
            discovery: BackupDiscovery(configuration: configuration, validator: validator),
            validator: validator,
            locator: locator,
            archiver: BackupArchiver(configuration: configuration),
            store: store,
            lock: ProcessLock(url: configuration.lockURL),
            logger: logger
        )
        let result = controller.check()
        // A live result, so the richer presenter applies — it can name the archive, the
        // remaining wait, the shortfall in free space.
        lastRunDescription = L("automation.checkResult", Presenter.text(for: result))
        lastRunNeedsAttention = !result.isSuccess
    }

    func revealSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([settings.fileURL])
    }
}
