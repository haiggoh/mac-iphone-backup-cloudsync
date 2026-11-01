import Foundation
import Testing
@testable import IPhoneBackupCore

/// Test-safety contract for LaunchAgentManager: install/uninstall must go through the
/// injected `runProcess` and the injected home directory only, so a test can never
/// register a real launchd agent or write into the real ~/Library/LaunchAgents.
/// (2026-10-08 incident: a test left test.iphonebackup.plist there, firing every
/// 1800 s for days after its bundle was deleted.)
@Suite("LaunchAgentManager test safety")
struct LaunchAgentManagerTestSafetyTests {
    let tempDir: URL
    let fakeHome: URL
    let configuration: Configuration

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAgentSafetyTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fakeHome = tempDir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        configuration = Configuration(
            bundleIdentifier: "test.iphonebackup",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    /// A fake bundle in the fake home's Applications, suitable per inspectInstallation.
    private func makeSuitableBundle() throws -> URL {
        let app = fakeHome.appendingPathComponent("Applications/TestApp.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>TestApp</string>
            <key>CFBundleIdentifier</key><string>test.iphonebackup</string>
        </dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        // install() requires the LaunchAgent plist inside the bundle
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let agentPlist = [
            "Label": "test.iphonebackup",
            "ProgramArguments": [exe.path, "--automatic"],
            "RunAtLoad": true,
            "StartInterval": 300
        ] as [String: Any]
        try PropertyListSerialization.data(fromPropertyList: agentPlist, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("test.iphonebackup.plist"), options: .atomic)
        return app
    }

    @Test("install/uninstall go only through the injected runner and fake home")
    func installUninstallStayInTestDomain() throws {
        let bundle = try makeSuitableBundle()
        var commands: [[String]] = []
        let fakeRun: (URL, [String]) -> (exitCode: Int32, output: String) = { tool, args in
            commands.append([tool.lastPathComponent] + args)
            // plutil -lint, launchctl bootstrap/bootout succeed; "print" reports the
            // job loaded (install's verification); "list" shows exactly one job.
            if args.first == "list" {
                return (0, "123\t0\ttest.iphonebackup")
            }
            return (0, "")
        }
        let manager = LaunchAgentManager(
            configuration: configuration,
            runProcess: fakeRun,
            homeDirectory: fakeHome)

        let state = try manager.install(bundleURL: bundle)
        #expect(state == .installedAndLoaded)
        #expect(commands.contains { $0.contains("bootstrap") })
        // the plist was written under the FAKE home, not the real one
        let plistInFakeHome = fakeHome
            .appendingPathComponent("Library/LaunchAgents/test.iphonebackup.plist")
        #expect(FileManager.default.fileExists(atPath: plistInFakeHome.path))

        try manager.uninstall()
        #expect(commands.contains { $0.contains("bootout") })
        #expect(!FileManager.default.fileExists(atPath: plistInFakeHome.path))

        // and the REAL domain was never touched: no plist in the real home (all
        // launchctl calls went to the fake runner, asserted above)
        let realPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/test.iphonebackup.plist")
        #expect(!FileManager.default.fileExists(atPath: realPlist.path))
    }

    // NOTE: the old "ghost task cleanup in build.sh" test was removed with the
    // 2026-10-31 rework (c087090): build.sh no longer calls --remove-automation,
    // because installation now resolves to a stable AppSupport location instead of
    // the build dir, so no ghost agent can be written from a transient path.
}
