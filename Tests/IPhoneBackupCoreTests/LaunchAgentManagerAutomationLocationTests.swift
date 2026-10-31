import XCTest
@testable import IPhoneBackupCore

/// Test case for automation location workaround - extends the existing LaunchAgentManagerTests patterns
final class LaunchAgentManagerAutomationLocationTests: XCTestCase {

    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPhoneBackupCoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func configuration() -> Configuration {
        Configuration(
            bundleIdentifier: "io.github.haiggoh.iphonebackup.tests",
            backupRoot: root.appendingPathComponent("backups"),
            stagingRoot: root.appendingPathComponent("staging"),
            applicationSupportDirectory: root.appendingPathComponent("support")
        )
    }

    private func makeBundle(at path: String) throws -> URL {
        let bundle = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        try PropertyListSerialization
            .data(fromPropertyList: ["CFBundleExecutable": "iPhoneBackup"],
                  format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8)
            .write(to: bundle.appendingPathComponent("Contents/MacOS/iPhoneBackup"))
        return bundle
    }

    // MARK: - Automation Location Tests

    func testBuildDirectoryCanAutomateViaSupportDir() throws {
        // Simulate app launched from build directory
        let buildDir = root.appendingPathComponent("build/Debug")
        try FileManager.default.createDirectory(
            at: buildDir.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        let executable = buildDir.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let infoPlist = """
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>TestApp</string>
            <key>CFBundleIdentifier</key><string>test.iphonebackup</string>
        </dict></plist>
        """
        try infoPlist.write(to: buildDir.appendingPathComponent("Contents/Info.plist"),
                            atomically: true, encoding: .utf8)

        let site = LaunchAgentManager.inspectInstallation(bundleURL: buildDir)

        // 2026-10-31 ruling: the support-dir resolve was never completed (the specced
        // ensureStableInstallation self-copy was never implemented — a resolved plist would
        // point at a nonexistent executable), so the reject contract wins and this test
        // asserts it, matching LaunchAgentManagerTests.testBuildDirectoryIsRejectedAsVolatile.
        XCTAssertTrue(site.concerns.contains { if case .volatileLocation = $0 { return true }; return false },
                      "Build directory must be rejected as volatile (support-dir copy is not implemented)")
        XCTAssertFalse(site.isSuitable, "a volatile location is never suitable")
    }

    func testAutomationUsesSupportDirExecutable() throws {
        // Simulate app launched from build directory
        let buildDir = root.appendingPathComponent("build/Debug")
        try FileManager.default.createDirectory(
            at: buildDir.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        let executable = buildDir.appendingPathComponent("Contents/MacOS/TestApp")
        try "#!/bin/sh\necho test".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let infoPlist = """
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>TestApp</string>
            <key>CFBundleIdentifier</key><string>test.iphonebackup</string>
        </dict></plist>
        """
        try infoPlist.write(to: buildDir.appendingPathComponent("Contents/Info.plist"),
                            atomically: true, encoding: .utf8)

        let site = LaunchAgentManager.inspectInstallation(bundleURL: buildDir)

        // Same ruling as above: volatile locations are rejected, not resolved — the
        // Application Support "InstalledApp" copy nothing writes.
        XCTAssertFalse(site.isSuitable, "build-dir install must be refused")
        XCTAssertTrue(site.concerns.contains { if case .volatileLocation = $0 { return true }; return false })
    }
}
