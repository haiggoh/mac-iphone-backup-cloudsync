import Foundation

/// Where the app is installed, and whether that location is fit to automate from.
public struct InstallationSite: Equatable {
    public let bundleURL: URL
    public let executableURL: URL
    public let concerns: [InstallationConcern]

    public var isSuitable: Bool { concerns.isEmpty }
}

public enum InstallationConcern: Equatable {
    /// Gatekeeper copied the app to a random read-only mount. The path is
    /// meaningless once the app quits, so a LaunchAgent written from it would point
    /// at nothing.
    case translocated(path: String)
    /// Running from a disk image or other read-only volume.
    case readOnlyVolume(path: String)
    /// Somewhere transient — Downloads, /tmp, or a build directory. Automating from
    /// a path the user will move or delete produces an agent that silently stops.
    case volatileLocation(path: String)
}

public enum LaunchAgentState: Equatable {
    case notInstalled
    /// The plist exists and launchd has the job loaded.
    case installedAndLoaded
    /// The plist exists but launchd does not know about it — a half state, usually
    /// after a failed bootstrap or a manual `launchctl bootout`.
    case installedNotLoaded
}

public enum LaunchAgentError: Error, Equatable {
    case unsuitableInstallation([InstallationConcern])
    case couldNotWritePlist(String)
    case plistInvalid(String)
    case bootstrapFailed(exitCode: Int32, output: String)
    case bootoutFailed(exitCode: Int32, output: String)
    case verificationFailed(String)
}

/// Installs and removes the per-user LaunchAgent that drives unattended runs.
///
/// A LaunchAgent, not a LaunchDaemon and not cron: the work needs the logged-in
/// user's backup directory, their cloud folder, their privacy grants and their
/// preferences. A daemon has none of those, and cron on macOS simply misses the run
/// when the laptop is asleep instead of catching up on wake.
///
/// `StartInterval` rather than `WatchPaths`: an iPhone backup generates a very large
/// number of filesystem events, nested changes do not map cleanly onto a top-level
/// trigger, and launchd exposes no semantic "a backup finished" event. Polling every
/// few minutes is unglamorous and correct, and it composes with the settle gate,
/// which is what actually decides readiness.
public struct LaunchAgentManager {

    public static let defaultStartInterval = 300

    private let configuration: Configuration
    private let fileManager: FileManager
    private let runProcess: (URL, [String]) -> (exitCode: Int32, output: String)

    public init(
        configuration: Configuration,
        fileManager: FileManager = .default,
        runProcess: ((URL, [String]) -> (exitCode: Int32, output: String))? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.runProcess = runProcess ?? LaunchAgentManager.execute
    }

    // MARK: Locations

    public var plistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(configuration.launchAgentLabel).plist")
    }

    /// Describes where this build is running from, and what is wrong with it.
    ///
    /// The path is derived from the running bundle rather than hardcoded, which is
    /// what makes the installed plist correct on any machine without the repository
    /// containing anyone's home directory.
    public static func inspectInstallation(bundleURL: URL) -> InstallationSite {
        var concerns: [InstallationConcern] = []
        let path = bundleURL.path

        // App translocation mounts the bundle under /private/var/folders/…/AppTranslocation.
        if path.contains("/AppTranslocation/") {
            concerns.append(.translocated(path: path))
        }

        if let writable = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            .volumeIsReadOnly, writable == true {
            concerns.append(.readOnlyVolume(path: path))
        }

        // A build directory is the trap that matters in practice: it is the copy a
        // developer runs, and `swift build` deletes and recreates it.
        let volatileMarkers = ["/build/", "/.build/", "/Downloads/", "/tmp/", "/private/tmp/"]
        if volatileMarkers.contains(where: { path.contains($0) }) {
            concerns.append(.volatileLocation(path: path))
        }

        return InstallationSite(
            bundleURL: bundleURL,
            executableURL: bundleURL
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(bundleExecutableName(in: bundleURL)),
            concerns: concerns
        )
    }

    private static func bundleExecutableName(in bundleURL: URL) -> String {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let dictionary = raw as? [String: Any],
              let name = dictionary["CFBundleExecutable"] as? String
        else { return "iPhoneBackup" }
        return name
    }

    // MARK: Plist

    /// Builds the agent definition.
    ///
    /// `ProgramArguments` runs the executable **directly** rather than going through
    /// `open -b <bundle-id>`. Both were tested and both deliver the argument, but
    /// direct execution wins on two counts: `open` returns as soon as it has asked
    /// LaunchServices to start the app, so launchd never sees the real exit status;
    /// and a bundle identifier can be claimed by more than one bundle on disk — this
    /// machine had the build output and the installed copy both registered — leaving
    /// `open -b` free to launch a disposable build directory.
    ///
    /// The absolute path is therefore unavoidable, and is resolved at install time
    /// from the running bundle. It must never appear in the repository.
    public func plistContents(executableURL: URL, startInterval: Int) -> [String: Any] {
        [
            "Label": configuration.launchAgentLabel,
            "ProgramArguments": [executableURL.path, ApplicationMode.automaticFlag],
            // Catches up promptly after login rather than waiting a whole interval.
            "RunAtLoad": true,
            "StartInterval": startInterval,
            // No StandardOutPath/StandardErrorPath: unattended runs report through the
            // state file and unified logging, and a log file in a fixed location is a
            // thing that grows forever.
            "ProcessType": "Background",
            // Lowers the priority of a job that is about to read tens of gigabytes,
            // so it does not compete with whatever the user is actually doing.
            "LowPriorityIO": true,
            "Nice": 5,
        ]
    }

    // MARK: State

    public func currentState() -> LaunchAgentState {
        guard fileManager.fileExists(atPath: plistURL.path) else { return .notInstalled }
        return isLoaded() ? .installedAndLoaded : .installedNotLoaded
    }

    private func isLoaded() -> Bool {
        let result = runProcess(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["print", "gui/\(getuid())/\(configuration.launchAgentLabel)"])
        return result.exitCode == 0
    }

    /// How many definitions launchd knows under our label. Used to prove an upgrade
    /// did not leave a duplicate behind.
    public func loadedJobCount() -> Int {
        let result = runProcess(URL(fileURLWithPath: "/bin/launchctl"), ["list"])
        guard result.exitCode == 0 else { return 0 }
        return result.output
            .split(separator: "\n")
            .filter { $0.hasSuffix("\t" + configuration.launchAgentLabel)
                || $0.hasSuffix(" " + configuration.launchAgentLabel) }
            .count
    }

    // MARK: Install / remove

    /// Installs or upgrades the agent, idempotently.
    ///
    /// Always boots out any existing definition first. `launchctl bootstrap` on an
    /// already-loaded label fails rather than replacing it, so upgrading in place
    /// without the bootout leaves the *old* definition running while the new plist
    /// sits on disk unused — the worst outcome, because everything looks installed.
    @discardableResult
    public func install(
        bundleURL: URL,
        startInterval: Int = LaunchAgentManager.defaultStartInterval
    ) throws -> LaunchAgentState {

        let site = Self.inspectInstallation(bundleURL: bundleURL)
        guard site.isSuitable else {
            throw LaunchAgentError.unsuitableInstallation(site.concerns)
        }

        // Boot out first, ignoring failure: "not loaded" is the expected error on a
        // fresh install and must not abort it.
        _ = runProcess(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["bootout", "gui/\(getuid())/\(configuration.launchAgentLabel)"])

        let contents = plistContents(executableURL: site.executableURL,
                                     startInterval: startInterval)
        do {
            try fileManager.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: contents, format: .xml, options: 0)
            // Atomic: a half-written plist that launchd then reads would fail in a way
            // that is tedious to diagnose.
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw LaunchAgentError.couldNotWritePlist(String(describing: error))
        }

        // Validate before asking launchd to load it, so a malformed file is reported
        // as such rather than as a mysterious bootstrap failure.
        let lint = runProcess(URL(fileURLWithPath: "/usr/bin/plutil"), ["-lint", plistURL.path])
        guard lint.exitCode == 0 else {
            throw LaunchAgentError.plistInvalid(lint.output)
        }

        let bootstrap = runProcess(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard bootstrap.exitCode == 0 else {
            throw LaunchAgentError.bootstrapFailed(
                exitCode: bootstrap.exitCode, output: bootstrap.output)
        }

        // Confirm by asking launchd, not by assuming the command that just returned 0
        // did what it said. And confirm there is exactly one, since a duplicate would
        // mean two archives racing.
        guard isLoaded() else {
            throw LaunchAgentError.verificationFailed("launchctl does not report the job as loaded")
        }
        let count = loadedJobCount()
        guard count <= 1 else {
            throw LaunchAgentError.verificationFailed("\(count) jobs are loaded under this label")
        }

        return .installedAndLoaded
    }

    /// Removes the agent. Boots out before deleting the plist, because deleting first
    /// leaves launchd running a job whose definition no longer exists — still firing,
    /// and no longer visible to anyone looking at the LaunchAgents folder.
    public func uninstall() throws {
        let bootout = runProcess(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["bootout", "gui/\(getuid())/\(configuration.launchAgentLabel)"])

        // Exit 3 / "No such process" means it was not loaded, which is fine here.
        if bootout.exitCode != 0,
           !bootout.output.lowercased().contains("no such process"),
           bootout.exitCode != 3 {
            throw LaunchAgentError.bootoutFailed(
                exitCode: bootout.exitCode, output: bootout.output)
        }

        if fileManager.fileExists(atPath: plistURL.path) {
            try? fileManager.removeItem(at: plistURL)
        }

        guard currentState() == .notInstalled else {
            throw LaunchAgentError.verificationFailed("the agent is still present after removal")
        }
    }

    // MARK: Process

    private static func execute(_ tool: URL, _ arguments: [String])
        -> (exitCode: Int32, output: String) {
        let task = Process()
        task.executableURL = tool
        // An argument array, never an interpolated shell string: paths here contain
        // spaces ("iPhone Backup.app") and a quoting mistake would be a silent
        // command-injection surface.
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do { try task.run() } catch {
            return (-1, "could not run \(tool.lastPathComponent): \(error)")
        }
        // Read before waiting, so a chatty tool filling the pipe buffer cannot deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
