import Foundation

/// Every path and tunable the app uses, resolved through Foundation rather than
/// string-interpolating a username, and injectable so tests can point at a
/// temporary directory instead of the developer's real 50 GB backup.
public struct Configuration {

    public static let defaultDestinationSubdirectory = "_iPhone-BU"
    /// How long metadata must sit unchanged before a backup counts as settled.
    /// `Status.plist` flips to `finished` while `Info.plist` is still being
    /// written — measured ~2m40s apart on the development machine — so this is
    /// the check that stops us archiving a moving target.
    public static let defaultQuietPeriod: TimeInterval = 60
    /// Archives to keep before the app starts warning. It never deletes.
    public static let defaultArchivesToKeep = 3
    public static let defaultPollInterval: TimeInterval = 300

    /// Only used when `Bundle.main.bundleIdentifier` is nil, which happens under
    /// `swift test` because tests are not running inside an app bundle. The real
    /// app always reports its own identifier.
    public static let fallbackBundleIdentifier = "io.github.haiggoh.iphonebackup"

    public let bundleIdentifier: String
    public let backupRoot: URL
    public let stagingRoot: URL
    public let applicationSupportDirectory: URL
    public let destinationSubdirectory: String
    public let quietPeriod: TimeInterval
    public let archivesToKeep: Int
    /// Set by `--destination-root`, or by the user picking a folder. Bypasses
    /// discovery entirely.
    public let destinationRootOverride: String?

    public init(
        bundleIdentifier: String,
        backupRoot: URL,
        stagingRoot: URL,
        applicationSupportDirectory: URL,
        destinationSubdirectory: String = Configuration.defaultDestinationSubdirectory,
        quietPeriod: TimeInterval = Configuration.defaultQuietPeriod,
        archivesToKeep: Int = Configuration.defaultArchivesToKeep,
        destinationRootOverride: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.backupRoot = backupRoot
        self.stagingRoot = stagingRoot
        self.applicationSupportDirectory = applicationSupportDirectory
        self.destinationSubdirectory = destinationSubdirectory
        self.quietPeriod = quietPeriod
        self.archivesToKeep = archivesToKeep
        self.destinationRootOverride = destinationRootOverride
    }

    // MARK: Derived locations

    /// Advisory lock file. Under Application Support rather than /tmp so it is
    /// per-user and survives nothing being cleaned out from under it.
    public var lockURL: URL {
        applicationSupportDirectory.appendingPathComponent("run.lock")
    }

    public var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("processed-state.json")
    }

    public var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    public var launchAgentLabel: String { bundleIdentifier }

    // MARK: Resolution

    /// Builds the production configuration, honouring the documented development
    /// overrides. The overrides move *roots* only — they never relax completion,
    /// stability, size or state checks, so a test run exercises the same logic
    /// the real one does.
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Configuration {
        let identifier = bundleIdentifier ?? fallbackBundleIdentifier
        let home = fileManager.homeDirectoryForCurrentUser

        let sourceRoot = value(for: "--source-root", in: arguments).map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent("Library/Application Support/MobileSync/Backup")

        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )) ?? home.appendingPathComponent("Library/Application Support")

        return Configuration(
            bundleIdentifier: identifier,
            backupRoot: sourceRoot,
            // Staging sits in the home folder so it shares a volume with the
            // destination where possible, making the final step a rename rather
            // than a second 50 GB copy.
            stagingRoot: home.appendingPathComponent(".iphone-backup-staging"),
            applicationSupportDirectory: appSupport.appendingPathComponent(identifier),
            destinationRootOverride: value(for: "--destination-root", in: arguments)
        )
    }

    /// `--flag value`. Returns nil when the flag is absent or is the last argument
    /// with nothing after it, rather than reading past the end.
    static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        let candidate = arguments[arguments.index(after: index)]
        return candidate.hasPrefix("--") ? nil : candidate
    }
}
