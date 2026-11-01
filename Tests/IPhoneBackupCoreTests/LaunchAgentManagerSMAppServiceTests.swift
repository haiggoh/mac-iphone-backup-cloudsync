import Foundation
import Testing
import ServiceManagement
@testable import IPhoneBackupCore

@Suite("LaunchAgentManager SMAppService")
struct LaunchAgentManagerSMAppServiceTests {
    let configuration: Configuration
    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMAppServiceTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        configuration = Configuration(
            bundleIdentifier: "test.iphonebackup",
            backupRoot: tempDir.appendingPathComponent("backup"),
            stagingRoot: tempDir.appendingPathComponent("staging"),
            applicationSupportDirectory: tempDir.appendingPathComponent("appSupport"),
            destinationSubdirectory: "_iPhone-BU"
        )
    }

    @Test("SMAppService installs agent from bundle plist")
    func installFromBundle() throws {
        // Create a test bundle structure
        let bundle = tempDir.appendingPathComponent("TestApp.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Library/LaunchAgents"),
            withIntermediateDirectories: true
        )

        // Write executable stub
        let executable = bundle.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // Write Info.plist
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>TestApp</string>
            <key>CFBundleIdentifier</key>
            <string>test.iphonebackup</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        // Write LaunchAgent plist to bundle
        let plist = [
            "Label": "test.iphonebackup",
            "ProgramArguments": [executable.path, "--automatic"],
            "RunAtLoad": true,
            "StartInterval": 300,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5
        ] as [String: Any]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appendingPathComponent("Contents/Library/LaunchAgents/test.iphonebackup.plist"), options: .atomic)

        var manager = LaunchAgentManager(configuration: configuration)

        // Tests must never register a real launchd agent (2026-10-08: a test agent in
        // ~/Library/LaunchAgents kept firing every 1800 s after its bundle was deleted).
        // Inject a recording fake; teardown unregisters through the same fake, and we
        // assert the real SMAppService domain stayed untouched.
        if #available(macOS 13.0, *) {
            final class FakeAgentService: AgentService {
                var registered = false
                var registerCalls = 0
                var unregisterCalls = 0
                func register() throws { registered = true; registerCalls += 1 }
                func unregister() throws { registered = false; unregisterCalls += 1 }
                var status: SMAppService.Status { registered ? .enabled : .notRegistered }
            }
            let fake = FakeAgentService()
            manager.agentServiceFactory = { _ in fake }
            defer {
                try? manager.uninstall()
                #expect(fake.unregisterCalls >= 1,
                        "teardown must unregister through the service")
                #expect(!fake.registered)
            }
            let state = try manager.install(bundleURL: bundle)
            #expect(state == .installedAndLoaded)
            #expect(fake.registerCalls == 1 && fake.registered)
        } else {
            // On older macOS, launchctl is used (also a real domain — set the env-free
            // force-launchctl hook is NOT used here; legacy path is covered by the
            // automation-location tests' inspectInstallation checks instead)
            let state = try manager.install(bundleURL: bundle)
            #expect(state == .installedAndLoaded)
            defer { try? manager.uninstall() }
        }
    }

    @Test("Ghost task cleanup in build.sh")
    func buildShCleansUpGhostTasks() throws {
        // This test verifies the build.sh logic by checking that
        // the installed app's --remove-automation is called before rm -rf
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // IPhoneBackupCoreTests/
            .deletingLastPathComponent()  // Tests/
        let buildShPath = projectRoot.appendingPathComponent("build.sh")
        let buildSh = try String(contentsOf: buildShPath)
        #expect(buildSh.contains("--remove-automation"))
        #expect(buildSh.contains("rm -rf"))
        #expect(buildSh.range(of: "--remove-automation")!.lowerBound < buildSh.range(of: "rm -rf")!.lowerBound)
    }
}