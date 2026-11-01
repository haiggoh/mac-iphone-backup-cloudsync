import IPhoneBackupCore
import SwiftUI

/// Settings window, starting with the destination — the one choice every user makes and
/// previously only reachable during first run or by hand-editing the JSON file.
/// The picker is the same control the first-run sheet uses, so it is familiar the second
/// time it is seen. Automation stays in the main window (visibility argument, per
/// docs/roadmap.md); `automation.mismatch` reporting is untouched.
struct SettingsView: View {
    @ObservedObject var model: AutomationViewModel
    /// Closes the host NSWindow — @Environment(\.dismiss) has no presentation context
    /// inside a hand-constructed NSWindow, so Save would persist but never close.
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("settings.destination")).font(.headline)

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

            if let error = model.destinationSaveError {
                Text(L("settings.saveError", error))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("settings.save")) {
                    if model.saveDestination() {
                        onClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedProvider == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if model.discoveredProviders.isEmpty { model.discoverProviders() }
        }
    }
}
