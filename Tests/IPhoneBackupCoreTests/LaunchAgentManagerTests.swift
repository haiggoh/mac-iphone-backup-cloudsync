import XCTest
@testable import IPhoneBackupCore

/// Records what would have been run, so install/remove logic is testable without
/// actually loading a job into the user's launchd.
private final class FakeProcessRunner {
    struct Invocation: Equatable {
        let tool: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    /// Keyed by the first argument (`bootout`, `bootstrap`, `print`, `list`, `-lint`).
    var results: [String: (Int32, String)] = [:]
    var defaultResult: (Int32, String) = (0, "")

    func run(_ tool: URL, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        invocations.append(Invocation(tool: tool.path, arguments: arguments))
        let key = arguments.first ?? ""
        let result = results[key] ?? defaultResult
        return (result.0, result.1)
    }

    var subcommands: [String] { invocations.compactMap { $0.arguments.first } }
}

final class LaunchAgentManagerTests: TemporaryDirectoryTestCase {

    private var fake: FakeProcessRunner!

    private func configuration() -> Configuration {
        Configuration(
            bundleIdentifier: "io.github.haiggoh.iphonebackup.tests",
            backupRoot: root.appendingPathComponent("backups"),
            stagingRoot: root.appendingPathComponent("staging"),
            applicationSupportDirectory: root.appendingPathComponent("support")
        )
    }

    /// A FileManager whose home directory is the temp dir, so the test never writes
    /// into the real ~/Library/LaunchAgents.
    private final class FakeHomeFileManager: FileManager {
        let fakeHome: URL
        init(fakeHome: URL) { self.fakeHome = fakeHome; super.init() }
        override var homeDirectoryForCurrentUser: URL { fakeHome }
    }

    private func manager() -> LaunchAgentManager {
        fake = FakeProcessRunner()
        return LaunchAgentManager(
            configuration: configuration(),
            fileManager: FakeHomeFileManager(fakeHome: root),
            runProcess: { [unowned self] tool, args in self.fake.run(tool, args) }
        )
    }

    /// Builds a plausible app bundle so installation has something real to point at.
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

    // MARK: The plist

    func testPlistRunsTheExecutableDirectlyWithTheFlag() throws {
        let subject = manager()
        let executable = URL(fileURLWithPath: "/Users/somebody/Applications/App.app/Contents/MacOS/iPhoneBackup")

        let plist = subject.plistContents(executableURL: executable, startInterval: 300)

        XCTAssertEqual(plist["Label"] as? String, "io.github.haiggoh.iphonebackup.tests")
        // Directly, not via `open -b`: open returns before the app finishes so launchd
        // never sees the real exit status, and a bundle id can be claimed by more than
        // one bundle on disk.
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       [executable.path, "--automatic"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 300)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["StandardOutPath"],
                     "a fixed log file would grow forever; runs report via the state file")
    }

    func testPlistLabelMatchesTheBundleIdentifier() throws {
        // launchctl addresses the job by label, so a mismatch makes bootout target
        // nothing while appearing to succeed.
        let subject = manager()
        XCTAssertEqual(subject.plistContents(
            executableURL: URL(fileURLWithPath: "/x"), startInterval: 300)["Label"] as? String,
            configuration().launchAgentLabel)
    }

    // MARK: Where it is installed from

    func testTranslocatedBundleIsRejected() {
        let site = LaunchAgentManager.inspectInstallation(bundleURL: URL(
            fileURLWithPath: "/private/var/folders/ab/AppTranslocation/XYZ/d/iPhone Backup.app"))
        XCTAssertFalse(site.isSuitable)
        XCTAssertTrue(site.concerns.contains { if case .translocated = $0 { return true }; return false })
    }

    /// The trap that matters in practice: `swift build` deletes and recreates this
    /// directory, so an agent pointing into it silently stops working.
    func testBuildDirectoryIsRejectedAsVolatile() {
        let site = LaunchAgentManager.inspectInstallation(bundleURL: URL(
            fileURLWithPath: "/Users/somebody/project/build/iPhone Backup.app"))
        XCTAssertFalse(site.isSuitable)
        XCTAssertTrue(site.concerns.contains { if case .volatileLocation = $0 { return true }; return false })
    }

    func testApplicationsFolderIsAccepted() throws {
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        let site = LaunchAgentManager.inspectInstallation(bundleURL: bundle)
        XCTAssertTrue(site.isSuitable, "concerns: \(site.concerns)")
        XCTAssertEqual(site.executableURL.lastPathComponent, "iPhoneBackup")
    }

    func testInstallRefusesAnUnsuitableLocation() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "build/iPhone Backup.app")

        XCTAssertThrowsError(try subject.install(bundleURL: bundle)) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .unsuitableInstallation(let concerns) = launchError else {
                return XCTFail("expected unsuitableInstallation, got \(error)")
            }
            XCTAssertFalse(concerns.isEmpty)
        }
        // And it must not have touched launchd or written anything.
        XCTAssertTrue(fake.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: subject.plistURL.path))
    }

    // MARK: Install

    func testInstallWritesLintsAndBootstrapsInThatOrder() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")

        let state = try subject.install(bundleURL: bundle)
        XCTAssertEqual(state, .installedAndLoaded)

        // bootout FIRST: launchctl bootstrap fails on an already-loaded label rather
        // than replacing it, so skipping this leaves the OLD definition running while
        // the new plist sits unused — the worst outcome, since it all looks installed.
        XCTAssertEqual(fake.subcommands.first, "bootout")
        XCTAssertTrue(fake.subcommands.contains("-lint"))
        XCTAssertTrue(fake.subcommands.contains("bootstrap"))
        // Verified by asking launchd, not by trusting the command's exit code.
        XCTAssertTrue(fake.subcommands.contains("print"))

        guard let lint = fake.subcommands.firstIndex(of: "-lint"),
              let bootstrap = fake.subcommands.firstIndex(of: "bootstrap") else {
            return XCTFail("expected both a lint and a bootstrap")
        }
        XCTAssertLessThan(lint, bootstrap, "validate the plist before asking launchd to load it")

        XCTAssertTrue(FileManager.default.fileExists(atPath: subject.plistURL.path))
    }

    func testInstalledPlistIsValidAndPointsAtTheInstalledBinary() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        try subject.install(bundleURL: bundle)

        let data = try Data(contentsOf: subject.plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.count, 2)
        XCTAssertTrue(arguments[0].hasSuffix("Contents/MacOS/iPhoneBackup"))
        XCTAssertEqual(arguments[1], "--automatic")
        // The path is resolved at install time from the running bundle; it must never
        // be a literal in the repository.
        XCTAssertTrue(arguments[0].hasPrefix(root.path))
    }

    func testInstallReportsAMalformedPlistAsSuchRatherThanAsABootstrapFailure() throws {
        let subject = manager()
        fake = FakeProcessRunner()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        fake.results["-lint"] = (1, "unexpected character")

        XCTAssertThrowsError(try subject.install(bundleURL: bundle)) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .plistInvalid = launchError else {
                return XCTFail("expected plistInvalid, got \(error)")
            }
        }
        XCTAssertFalse(fake.subcommands.contains("bootstrap"),
                       "must not ask launchd to load a plist that failed validation")
    }

    func testInstallFailsWhenBootstrapFails() throws {
        let subject = manager()
        fake = FakeProcessRunner()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        fake.results["bootstrap"] = (5, "Load failed: 5: Input/output error")

        XCTAssertThrowsError(try subject.install(bundleURL: bundle)) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .bootstrapFailed(let code, _) = launchError else {
                return XCTFail("expected bootstrapFailed, got \(error)")
            }
            XCTAssertEqual(code, 5)
        }
    }

    /// A successful-looking bootstrap that launchd does not actually know about must
    /// not be reported as installed.
    func testInstallFailsWhenLaunchdDoesNotConfirmTheJob() throws {
        let subject = manager()
        fake = FakeProcessRunner()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        fake.results["print"] = (1, "Could not find service")

        XCTAssertThrowsError(try subject.install(bundleURL: bundle)) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .verificationFailed = launchError else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        }
    }

    /// Two loaded definitions would mean two archives racing each other.
    func testInstallFailsWhenTwoJobsAreLoadedUnderTheLabel() throws {
        let subject = manager()
        fake = FakeProcessRunner()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        let label = configuration().launchAgentLabel
        fake.results["list"] = (0, "-\t0\t\(label)\n-\t0\t\(label)\n")

        XCTAssertThrowsError(try subject.install(bundleURL: bundle)) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .verificationFailed = launchError else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        }
    }

    /// Installing twice must converge, not accumulate.
    func testInstallIsIdempotent() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")

        try subject.install(bundleURL: bundle)
        let firstPlist = try Data(contentsOf: subject.plistURL)
        try subject.install(bundleURL: bundle)
        let secondPlist = try Data(contentsOf: subject.plistURL)

        XCTAssertEqual(firstPlist, secondPlist)
        XCTAssertEqual(subject.currentState(), .installedAndLoaded)
    }

    // MARK: Uninstall

    func testUninstallBootsOutBeforeDeletingThePlist() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        try subject.install(bundleURL: bundle)

        fake = FakeProcessRunner()
        // After removal, launchd must report the job as gone.
        fake.results["print"] = (1, "Could not find service")
        try subject.uninstall()

        // Order matters: deleting first would leave launchd running a job whose
        // definition no longer exists — still firing, and invisible to anyone
        // inspecting the LaunchAgents folder.
        XCTAssertEqual(fake.subcommands.first, "bootout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: subject.plistURL.path))
        XCTAssertEqual(subject.currentState(), .notInstalled)
    }

    /// Removing something that was never loaded is a normal case, not an error.
    func testUninstallToleratesAJobThatWasNotLoaded() throws {
        let subject = manager()
        fake = FakeProcessRunner()
        fake.results["bootout"] = (3, "Boot-out failed: 3: No such process")
        fake.results["print"] = (1, "Could not find service")

        XCTAssertNoThrow(try subject.uninstall())
    }

    func testUninstallSurfacesARealBootoutFailure() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        try subject.install(bundleURL: bundle)

        fake = FakeProcessRunner()
        fake.results["bootout"] = (9, "Boot-out failed: 9: Bad file descriptor")

        XCTAssertThrowsError(try subject.uninstall()) { error in
            guard let launchError = error as? LaunchAgentError,
                  case .bootoutFailed = launchError else {
                return XCTFail("expected bootoutFailed, got \(error)")
            }
        }
        // And the plist must survive, so the state stays coherent rather than becoming
        // "no definition on disk but still loaded".
        XCTAssertTrue(FileManager.default.fileExists(atPath: subject.plistURL.path))
    }

    // MARK: State reporting

    func testStateDistinguishesInstalledButNotLoaded() throws {
        let subject = manager()
        let bundle = try makeBundle(at: "Applications/iPhone Backup.app")
        try subject.install(bundleURL: bundle)

        fake = FakeProcessRunner()
        fake.results["print"] = (1, "Could not find service")

        // The half state a manual `launchctl bootout` leaves behind. Reporting it as
        // simply "installed" would tell the user automation is on when it is not.
        XCTAssertEqual(subject.currentState(), .installedNotLoaded)
    }

    func testStateIsNotInstalledWhenNoPlistExists() {
        XCTAssertEqual(manager().currentState(), .notInstalled)
    }
}
