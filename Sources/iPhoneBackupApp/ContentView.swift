import IPhoneBackupCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BackupViewModel
    @ObservedObject var automation: AutomationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                // "iphone.gen3" needs SF Symbols 5 (macOS 14), and the deployment
                // target is 13.0, where it renders as nothing. "iphone" has existed
                // since SF Symbols 1, so it degrades to something rather than a gap.
                Image(systemName: "iphone")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("headline.title"))
                        .font(.headline)
                    Text(model.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(model.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: model.percentage, total: 100)
                .progressViewStyle(.linear)
                .tint(.blue)
                .opacity(model.isRunning || model.percentage > 0 ? 1 : 0.35)

            // Only appears when macOS actually blocked the read. Full Disk Access is
            // not promptable, so pointing at the pane is the only way out; and the
            // app cannot grant it, which the wording is careful not to imply.
            if model.needsFullDiskAccess {
                HStack(spacing: 10) {
                    Button(L("permissions.openSettings")) {
                        model.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L("permissions.recheck")) { model.retryDiscovery() }
                }
            }

            HStack {
                Text(model.isRunning ? "\(Int(model.percentage)) %" : " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if model.finishedURL != nil {
                    Button(L("button.revealInFinder")) { model.revealInFinder() }
                }

                if model.isRunning {
                    Button(L("button.cancel")) { model.cancel() }
                }

                Button(model.isRunning ? L("button.running") : L("button.start")) {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || !model.isReady)
            }

            AutomationSection(model: automation)
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            model.discover()
            automation.refresh()
        }
        // Presented rather than inlined so the choice is made before anything else can
        // be attempted, and only ever once.
        .sheet(isPresented: $automation.isFirstRun) {
            FirstRunSheet(model: automation)
        }
    }
}
