import IPhoneBackupCore
import SwiftUI

/// The Automation controls, plus the two lines that make unattended work trustworthy:
/// when it last looked, and what happened.
struct AutomationSection: View {
    @ObservedObject var model: AutomationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Text(L("automation.title")).font(.headline)
                Spacer()
                // The state shown is what launchd reports, not what settings claim.
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(isOn ? Color.green : Color.secondary)
            }

            HStack(spacing: 8) {
                if isOn {
                    Button(L("automation.disable")) { model.disableAutomation() }
                } else {
                    Button(L("automation.enable")) { model.enableAutomation() }
                        .buttonStyle(.borderedProminent)
                }

                Button(L("automation.checkNow")) { model.checkNow() }

                Spacer()

                // Disabled while running: changing the interval means reinstalling the
                // agent, and doing that mid-archive would boot out a live job.
                Picker(L("automation.interval"), selection: $model.intervalMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { minutes in
                        Text(L("automation.everyMinutes", minutes)).tag(minutes)
                    }
                }
                .frame(width: 190)
                .disabled(isOn)
            }

            Group {
                // Orange, not red: this is the *last* outcome, which may well have been
                // fixed since. Red would read as "broken right now", and the same line
                // is shown for a run that happened days ago.
                Text(model.lastRunDescription)
                    .foregroundStyle(model.lastRunNeedsAttention ? Color.orange : .secondary)
                Text(model.lastArchiveDescription)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            // Retention is advisory only — this app has no code path that deletes an
            // archive, by design.
            if let warning = model.retentionWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.automationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(L("automation.showSettingsFile")) { model.revealSettingsFile() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .onAppear { model.refresh() }
    }

    private var isOn: Bool { model.automationState == .installedAndLoaded }

    private var stateLabel: String {
        switch model.automationState {
        case .installedAndLoaded: return L("automation.stateOn")
        case .installedNotLoaded: return L("automation.stateHalf")
        case .notInstalled: return L("automation.stateOff")
        }
    }
}

/// Shown once, on first launch, to choose where archives go.
///
/// Only providers actually found on this machine are offered. Listing one the user
/// does not have invites them to choose something that cannot work, and then to blame
/// the app when it does not.
struct FirstRunSheet: View {
    @ObservedObject var model: AutomationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("firstRun.title")).font(.headline)
            Text(L("firstRun.explain"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.discoveredProviders.isEmpty {
                Text(L("firstRun.noProvidersFound"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.discoveredProviders) { discovered in
                    HStack {
                        Image(systemName: model.selectedRootPath == discovered.rootPath
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(discovered.displayName)
                            Text(discovered.rootPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(discovered) }
                }
            }

            Button(L("firstRun.customFolder")) { model.chooseCustomFolder() }
                .font(.caption)

            // Honest, and shown before the choice rather than after it goes wrong.
            if !model.providerCaveats.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.providerCaveats, id: \.rawValue) { caveat in
                        Text("• " + Presenter.text(forCaveat: caveat))
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Automation is offered here but NOT preselected. Setting it up is
            // optional, and declining must be an ordinary outcome rather than leaving
            // setup half-finished.
            Text(L("firstRun.automationOptional"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L("firstRun.confirm")) { model.confirmFirstRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedProvider == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
