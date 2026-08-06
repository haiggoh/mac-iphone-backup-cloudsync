import SwiftUI
import AppKit
import UserNotifications

// MARK: - Model

struct BackupCandidate {
    var url: URL
    var deviceName: String
    var date: Date
    var productVersion: String
    var timestamp: String   // yyyy-MM-dd_HH-mm
}

// MARK: - Core logic

final class BackupManager: ObservableObject {

    @Published var headline: String = "Suche iPhone-Backup …"
    @Published var status: String = ""
    @Published var percentage: Double = 0
    @Published var isRunning: Bool = false
    @Published var isError: Bool = false
    @Published var isReady: Bool = false
    @Published var finishedURL: URL?

    private let backupRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/MobileSync/Backup")

    private let stagingRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".iphone-backup-staging")

    private var candidate: BackupCandidate?
    private var sourceBytes: Int64 = 0
    private var task: Process?
    private var stagedURL: URL?
    private var wasCancelled = false

    private let fm = FileManager.default

    // MARK: UI helpers

    private func ui(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func fail(_ message: String) {
        ui {
            self.isError = true
            self.isRunning = false
            self.percentage = 0
            self.status = message
        }
    }

    // MARK: Target folder

    /// Finds the OneDrive root in the home folder (name contains the tenant, so match by prefix).
    private func oneDriveRoot() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return nil }
        let matches = entries
            .filter { $0.hasPrefix("OneDrive") }
            .sorted()
        for name in matches {
            let candidate = home.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func targetFolder() -> URL? {
        oneDriveRoot()?.appendingPathComponent("_iPhone-BU")
    }

    // MARK: Discovery

    /// Picks the most recent backup folder and reads its metadata. Runs off the main thread.
    func discover() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.fm.fileExists(atPath: self.backupRoot.path) else {
                self.ui {
                    self.headline = "Kein Backup-Ordner gefunden"
                    self.status = "\(self.backupRoot.path) existiert nicht."
                    self.isError = true
                }
                return
            }

            guard let entries = try? self.fm.contentsOfDirectory(
                at: self.backupRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ), !entries.isEmpty else {
                self.ui {
                    self.headline = "Kein iPhone-Backup vorhanden"
                    self.status = "Ordner ist leer, oder der App fehlt „Festplattenvollzugriff“ "
                        + "(Systemeinstellungen › Datenschutz & Sicherheit)."
                    self.isError = true
                }
                return
            }

            let dirs = entries.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            var best: BackupCandidate?
            for dir in dirs {
                let info = self.readInfoPlist(in: dir)
                let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date.distantPast
                let date = info.date ?? mtime
                let cand = BackupCandidate(
                    url: dir,
                    deviceName: info.deviceName ?? dir.lastPathComponent,
                    date: date,
                    productVersion: info.productVersion ?? "",
                    timestamp: Self.stamp(date)
                )
                if best == nil || cand.date > best!.date { best = cand }
            }

            guard let picked = best else {
                self.fail("Kein gültiger Backup-Ordner gefunden.")
                return
            }

            self.candidate = picked

            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short

            var line = "\(picked.deviceName) — \(df.string(from: picked.date))"
            if !picked.productVersion.isEmpty { line += " · iOS \(picked.productVersion)" }

            self.ui {
                self.headline = line
                self.status = "Ermittle Größe …"
            }

            // du -sk is slow on ~250k files, so it runs here rather than blocking the click.
            let kb = self.directorySizeKB(picked.url)
            self.sourceBytes = kb * 1024

            let human = ByteCountFormatter.string(fromByteCount: self.sourceBytes, countStyle: .file)
            self.ui {
                self.status = "\(human) — bereit zum Archivieren."
                self.isReady = true
            }
        }
    }

    private func readInfoPlist(in dir: URL)
        -> (deviceName: String?, date: Date?, productVersion: String?) {
        let plistURL = dir.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let plist = raw as? [String: Any]
        else { return (nil, nil, nil) }

        return (
            plist["Device Name"] as? String,
            plist["Last Backup Date"] as? Date,
            plist["Product Version"] as? String
        )
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.string(from: date)
    }

    private func directorySizeKB(_ url: URL) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        // Read before waiting so a full pipe buffer can never deadlock us.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let first = text.components(separatedBy: CharacterSet.whitespaces).first ?? ""
        return Int64(first) ?? 0
    }

    // MARK: Run

    func start() {
        guard let picked = candidate else { return }
        guard let target = targetFolder() else {
            fail("OneDrive-Ordner nicht gefunden.")
            return
        }

        let zipName = "iPhone_Backup_\(picked.timestamp).zip"
        let finalURL = target.appendingPathComponent(zipName)

        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            fail("Zielordner konnte nicht erstellt werden: \(error.localizedDescription)")
            return
        }

        // Duplicate check
        if fm.fileExists(atPath: finalURL.path) {
            let existing = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            let alert = NSAlert()
            alert.messageText = "Backup existiert bereits"
            alert.informativeText = "Für das iPhone-Backup vom \(picked.timestamp) liegt schon "
                + "ein Archiv im OneDrive-Ordner "
                + "(\(ByteCountFormatter.string(fromByteCount: existing, countStyle: .file))).\n\n"
                + "Möchtest du es ersetzen?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Ersetzen")
            alert.addButton(withTitle: "Abbrechen")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                status = "Vorgang abgebrochen."
                return
            }
        }

        // Free space check on the staging volume
        if sourceBytes > 0,
           let free = (try? stagingRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity).map(Int64.init),
           free < sourceBytes + 2_000_000_000 {
            fail("Zu wenig freier Speicher: "
                + "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) frei, "
                + "benötigt werden ca. "
                + "\(ByteCountFormatter.string(fromByteCount: sourceBytes, countStyle: .file)).")
            return
        }

        wasCancelled = false
        isError = false
        finishedURL = nil
        isRunning = true
        percentage = 0
        status = "Archiv wird erstellt …"

        DispatchQueue.global(qos: .userInitiated).async {
            self.runPipeline(source: picked.url, stagingName: zipName, finalURL: finalURL)
        }
    }

    func cancel() {
        wasCancelled = true
        task?.terminate()
        status = "Wird abgebrochen …"
    }

    private func runPipeline(source: URL, stagingName: String, finalURL: URL) {
        let staged = stagingRoot.appendingPathComponent(stagingName)
        stagedURL = staged
        try? fm.removeItem(at: staged)

        let logURL = stagingRoot.appendingPathComponent("ditto-\(UUID().uuidString).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            fail("Log-Datei konnte nicht angelegt werden.")
            return
        }

        // ditto -c -k produces a real (zip64-capable) .zip archive, unlike tar -czf,
        // which only ever writes a gzip stream.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, staged.path]
        p.standardOutput = FileHandle.nullDevice
        // Written to a file, never an unread pipe: ditto can emit a lot of warnings.
        p.standardError = logHandle

        do {
            try p.run()
        } catch {
            try? logHandle.close()
            fail("ditto konnte nicht gestartet werden: \(error.localizedDescription)")
            return
        }
        task = p

        // iPhone backups are mostly already-compressed media, so the archive lands
        // at roughly 97-99% of the source size — good enough to drive a progress bar.
        let expected = Double(sourceBytes) * 0.975
        let started = Date()

        while p.isRunning {
            Thread.sleep(forTimeInterval: 1.5)
            guard let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
                .int64Value else { continue }

            let elapsed = Date().timeIntervalSince(started)
            var pct = expected > 0 ? (Double(size) / expected) * 100.0 : 0
            pct = min(max(pct, 0.5), 99.0)

            let written = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: sourceBytes, countStyle: .file)
            let rate = elapsed > 1 ? Double(size) / elapsed : 0
            var line = "\(written) von ca. \(total)"
            if rate > 0 {
                line += " · \(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s"
                let remaining = (expected - Double(size)) / rate
                if remaining > 0, remaining < 86_400 {
                    line += " · noch ca. \(Self.humanDuration(remaining))"
                }
            }

            self.ui {
                self.percentage = pct
                self.status = line
            }
        }

        p.waitUntilExit()
        try? logHandle.close()
        task = nil

        let stderrTail = Self.tail(of: logURL, lines: 4)
        try? fm.removeItem(at: logURL)

        if wasCancelled {
            try? fm.removeItem(at: staged)
            ui {
                self.isRunning = false
                self.percentage = 0
                self.status = "Abgebrochen — unvollständiges Archiv wurde gelöscht."
            }
            return
        }

        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: staged)
            var msg = "ditto ist mit Code \(p.terminationStatus) fehlgeschlagen."
            if !stderrTail.isEmpty { msg += "\n\(stderrTail)" }
            fail(msg)
            return
        }

        let stagedSize = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard stagedSize > 1_000_000 else {
            try? fm.removeItem(at: staged)
            fail("Archiv ist unplausibel klein (\(stagedSize) Bytes) — Vorgang verworfen.")
            return
        }

        ui { self.status = "Verschiebe Archiv nach OneDrive …" }

        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            // Same volume as the staging folder, so this is a rename, not a 50 GB copy.
            try fm.moveItem(at: staged, to: finalURL)
        } catch {
            fail("Verschieben fehlgeschlagen: \(error.localizedDescription)\n"
                + "Das fertige Archiv liegt noch unter \(staged.path)")
            return
        }

        let human = ByteCountFormatter.string(fromByteCount: stagedSize, countStyle: .file)
        let took = Self.humanDuration(Date().timeIntervalSince(started))

        ui {
            self.percentage = 100
            self.isRunning = false
            self.finishedURL = finalURL
            self.status = "Fertig — \(human) in \(took). OneDrive lädt jetzt hoch."
            NSSound(named: "Glass")?.play()
            self.notify(title: "Backup abgeschlossen 👍",
                        body: "\(finalURL.lastPathComponent) (\(human)) liegt im OneDrive-Ordner.")
        }
    }

    // MARK: Utilities

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }

    func revealInFinder() {
        guard let url = finishedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }

    private static func tail(of url: URL, lines: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: "\n")
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("iPhone-Backup archivieren")
                        .font(.headline)
                    Text(manager.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(manager.status)
                        .font(.caption)
                        .foregroundStyle(manager.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: manager.percentage, total: 100)
                .progressViewStyle(.linear)
                .tint(.blue)
                .opacity(manager.isRunning || manager.percentage > 0 ? 1 : 0.35)

            HStack {
                Text(manager.isRunning ? "\(Int(manager.percentage)) %" : " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if manager.finishedURL != nil {
                    Button("Im Finder zeigen") { manager.revealInFinder() }
                }

                if manager.isRunning {
                    Button("Abbrechen") { manager.cancel() }
                }

                Button(manager.isRunning ? "Läuft …" : "Sicherung starten") {
                    manager.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(manager.isRunning || !manager.isReady)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { manager.discover() }
    }
}

// MARK: - Entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: ContentView())
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 190)

        window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iPhone Backup"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct iPhoneBackupAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Keeps the delegate alive for the process lifetime.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
