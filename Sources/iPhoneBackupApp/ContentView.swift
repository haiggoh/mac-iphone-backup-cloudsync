import IPhoneBackupCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BackupViewModel

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
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { model.discover() }
    }
}
