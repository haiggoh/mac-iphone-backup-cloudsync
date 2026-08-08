import Foundation

/// Every path and tunable the app uses, resolved through Foundation rather than
/// string-interpolating a username, and injectable so tests can point at a
/// temporary directory instead of the developer's real 50 GB backup.
public struct Configuration {

    public static let defaultDestinationSubdirectory = "_iPhone-BU"
    /// How long metadata must sit unchanged, sampled twice, before archiving.
    public static let defaultQuietPeriod: TimeInterval = 60

    /// The newest write to any watched file must be at least this old.
    ///
    /// **This number is measured, not chosen.** Two real backups were observed end
    /// to end, timing the gap between `SnapshotState` becoming `finished` and the
    /// last write to `Info.plist`:
    ///
    ///     transport            backup took    finished -> Info.plist rewritten
    ///     Wi-Fi   2026-08-07   ~20 min        235 s  (3m55s)
    ///     USB/TB4 2026-08-08   ~5 min         150 s  (2m30s)
    ///
    /// Two things follow. A 60-second quiet period would have archived mid-write in
    /// **both** runs — two samples a minute apart both land in the lull before the
    /// rewrite, so they cannot tell "finished" from "between two writes". And the lag
    /// does **not** scale with transfer speed: the second backup was roughly 4x
    /// faster overall yet its tail shrank only ~1.6x, so this is a largely fixed
    /// couple of minutes of post-processing rather than a fraction of the transfer.
    /// A slower link should therefore not push it far past the observed maximum.
    ///
    /// 360 s leaves 125 s (53%) of headroom over the worst case seen. It is exposed
    /// in settings so it can be raised if a backup is ever missed.
    ///
    /// Corroborated from outside the filesystem: during the second run the user
    /// reported the Finder progress bar still animating after reaching 100%, and it
    /// stopped at the moment `Info.plist` was rewritten. The visible "still working"
    /// signal and the file being watched are the same event.
    public static let defaultMinimumSettleAge: TimeInterval = 360
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
    public let minimumSettleAge: TimeInterval
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
        minimumSettleAge: TimeInterval = Configuration.defaultMinimumSettleAge,
        archivesToKeep: Int = Configuration.defaultArchivesToKeep,
        destinationRootOverride: String? = nil
    ) {
        self.minimumSettleAge = minimumSettleAge
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
