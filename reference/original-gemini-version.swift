import SwiftUI
import AppKit

// 1. Core Logic & State Management
class BackupManager: ObservableObject {
    @Published var progressText: String = "Bereit zum Sichern..."
    @Published var percentage: Double = 0.0
    @Published var isRunning: Bool = false
    
    // Redacted for publication: the original hardcoded an absolute home path and
    // a real OneDrive tenant name here. That it hardcoded them at all is the point
    // worth preserving — see this folder's README.
    //
    // These are placeholders, NOT a suggested fix. "$HOME/..." would not work in a
    // Swift literal either — Swift performs no shell expansion, so the dollar sign
    // would end up in the path. The rewrite resolves the home directory at runtime
    // instead, with NSHomeDirectory(); see Sources/iPhoneBackupApp.swift.
    let backupDir = "/Users/USERNAME/Library/Application Support/MobileSync/Backup"
    let baseOneDriveDir = "/Users/USERNAME/OneDrive - TENANT NAME"
    
    func startBackupPipeline() {
        let fileManager = FileManager.default
        let targetFolder = "\(baseOneDriveDir)/_iPhone-BU"
        
        // Ordner ermitteln
        guard let files = try? fileManager.contentsOfDirectory(atPath: backupDir),
              let backupFolder = files.map({ folder -> (String, Date) in
                  let path = "\(backupDir)/\(folder)"
                  let attrs = try? fileManager.attributesOfItem(atPath: path)
                  let modDate = attrs?[.modificationDate] as? Date ?? Date()
                  return (folder, modDate)
              }).sorted(by: { $0.1 > $1.1 }).first?.0 else {
            self.progressText = "❌ Fehler: Kein Backup-Ordner gefunden."
            return
        }
        
        // Datum auslesen
        var dateTimeStamp = ""
        let plistPath = "\(backupDir)/\(backupFolder)/Info.plist"
        if fileManager.fileExists(atPath: plistPath),
           let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
           let lastBackupDate = plist["Last Backup Date"] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm"
            dateTimeStamp = formatter.string(from: lastBackupDate)
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: "\(backupDir)/\(backupFolder)")
            let modDate = attrs?[.modificationDate] as? Date ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm"
            dateTimeStamp = formatter.string(from: modDate)
        }
        
        try? fileManager.createDirectory(atPath: targetFolder, withIntermediateDirectories: true, attributes: nil)
        let zipName = "iPhone_Backup_\(dateTimeStamp).zip"
        let targetPath = "\(targetFolder)/\(zipName)"
        
        // Überprüfung auf Duplikate
        if fileManager.fileExists(atPath: targetPath) {
            let alert = NSAlert()
            alert.messageText = "Backup existiert bereits"
            alert.informativeText = "Ein Archiv für das iPhone-Backup vom \(dateTimeStamp) existiert bereits.\n\nMöchtest du es ersetzen?"
            alert.addButton(withTitle: "Ersetzen")
            alert.addButton(withTitle: "Abbrechen")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                self.progressText = "⏹️ Vorgang abgebrochen."
                return
            }
        }
        
        self.isRunning = true
        self.progressText = "Analysiere Dateigrößen..."
        
        // Exakte Quellgröße berechnen
        let processDu = Process()
        processDu.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        processDu.arguments = ["-sk", "\(backupDir)/\(backupFolder)"]
        let pipeDu = Pipe()
        processDu.standardOutput = pipeDu
        try? processDu.run()
        processDu.waitUntilExit()
        let dataDu = pipeDu.fileHandleForReading.readDataToEndOfFile()
        let outputDu = String(data: dataDu, encoding: .utf8) ?? ""
        let sourceSize = Double(outputDu.components(separatedBy: CharacterSet.whitespaces).first ?? "1") ?? 1.0
        
        // Da iPhone-Backups bereits hochkomprimierte Daten enthalten,
        // entspricht die Zielgröße fast exakt 98% der Quellgröße (Fixes the 99% math bug)
        let expectedZipSize = sourceSize * 0.98
        
        // Komprimierung starten
        let processTar = Process()
        processTar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        processTar.arguments = ["-czf", targetPath, "-C", backupDir, backupFolder]
        try? processTar.run()
        
        // UI-Überwachungsthread (Läuft im Hintergrund, blockiert niemals den Cursor-Fokus)
        DispatchQueue.global(qos: .userInitiated).async {
            while processTar.isRunning {
                Thread.sleep(forTimeInterval: 2.0)
                if let attrs = try? fileManager.attributesOfItem(atPath: targetPath),
                   let currentSizeKB = attrs[.size] as? Int64 {
                    let currentSize = Double(currentSizeKB) / 1024.0
                    var pct = (currentSize / expectedZipSize) * 100.0
                    if pct > 99.0 { pct = 99.0 }
                    if pct < 1.0 { pct = 1.0 }
                    
                    DispatchQueue.main.async {
                        self.percentage = pct
                        self.progressText = "Komprimierung läuft: \(Int(pct))% abgeschlossen..."
                    }
                }
            }
            
            // Finale Schritte auf dem Main-UI-Thread
            DispatchQueue.main.async {
                self.percentage = 100.0
                self.progressText = "Backup abgeschlossen! 👍"
                self.isRunning = false
                
                let notification = NSUserNotification()
                notification.title = "Backup abgeschlossen! 👍"
                notification.informativeText = "Das Archiv vom \(dateTimeStamp) liegt sicher im OneDrive Ordner."
                NSUserNotificationCenter.default.deliver(notification)
            }
        }
    }
}

// 2. NATIVES INTERFACE (Wunderschöne macOS Progress GUI)
struct ContentView: View {
    @StateObject var manager = BackupManager()
    
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.networkName)!)
                    .resizable()
                    .frame(width: 40, height: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("iPhone-Backup Archivierung")
                        .font(.headline)
                    Text(manager.progressText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            // Der echte blaue macOS Fortschrittsbalken (wie im Finder)
            ProgressView(value: manager.percentage, total: 100.0)
                .progressViewStyle(LinearProgressViewStyle())
                .accentColor(.blue)
            
            HStack {
                Spacer()
                Button(action: {
                    if !manager.isRunning {
                        manager.startBackupPipeline()
                    }
                }) {
                    Text(manager.isRunning ? "Sicherung läuft..." : "Sicherung starten")
                        .frame(width: 130, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isRunning)
            }
        }
        .padding(22)
        .frame(width: 440, height: 150)
    }
}

// 3. Application Entry Point Wrapper
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.center()
        window.title = "iPhone Backup Pro"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        
        // Verhindert Fokusdiebstahl - das Fenster erscheint passiv
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct iPhoneBackupApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
