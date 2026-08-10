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
    /// **900 s is deliberately far more than the measurements require — roughly 3.8x
    /// the worst case seen — because the cost of waiting is nil and the cost of being
    /// wrong is a corrupt 50 GB archive.** Two observations are two observations:
    /// neither sampled a heavily loaded SSD, a much larger backup, a thermally
    /// throttled machine, or a slower link than Wi-Fi. Sizing the gate to the
    /// observed maximum would assume the sample is the worst case, which it plainly
    /// is not.
    ///
    /// What waiting actually costs: the agent polls every 5 minutes regardless, so a
    /// larger gate means a backup is archived one or two polls later — roughly 15 to
    /// 20 minutes after it finishes instead of 6 to 10. For an archive taken at most
    /// daily, that is not a cost at all.
    ///
    /// The one real risk is the opposite end: if backups were taken more often than
    /// the settle window, the state would keep flipping away from `finished` and
    /// nothing would ever be archived. Every deferral is logged with its reason
    /// precisely so that is diagnosable rather than a silent stall, and the value is
    /// a setting rather than a constant.
    ///
    /// Note the two gates cover different failure modes and both are needed: the
    /// quiet period catches a file being written *while we watch*, however long that
    /// lasts, and this catches the gap *between* two writes.
    ///
    /// Corroborated from outside the filesystem: during the second run the user
    /// reported the Finder progress bar still animating after reaching 100%, and it
    /// stopped at the moment `Info.plist` was rewritten. The visible "still working"
    /// signal and the file being watched are the same event.
    public static let defaultMinimumSettleAge: TimeInterval = 900
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

        let supportDirectory = appSupport.appendingPathComponent(identifier)

        // Two phases, because the settings file lives at a path this function
        // computes. Paths first, then read the user's choices, then combine.
        let settings = SettingsStore(
            url: supportDirectory.appendingPathComponent("settings.json"),
            fileManager: fileManager
        ).load()

        // A command-line override beats the saved setting, so a test run can point
        // somewhere harmless without editing the user's real configuration.
        let destinationOverride = value(for: "--destination-root", in: arguments)
            ?? settings.cloudRootPath

        return Configuration(
            bundleIdentifier: identifier,
            backupRoot: sourceRoot,
            // Staging sits in the home folder so it shares a volume with the
            // destination where possible, making the final step a rename rather
            // than a second 50 GB copy.
            stagingRoot: home.appendingPathComponent(".iphone-backup-staging"),
            applicationSupportDirectory: supportDirectory,
            destinationSubdirectory: settings.destinationSubdirectory,
            quietPeriod: defaultQuietPeriod,
            minimumSettleAge: settings.minimumSettleAge,
            archivesToKeep: settings.archivesToKeep,
            destinationRootOverride: destinationOverride
        )
    }

    /// The settings file backing `resolve()`. Documented in the README so a user can
    /// find and edit it.
    public var settingsStore: SettingsStore {
        SettingsStore(url: settingsURL)
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
