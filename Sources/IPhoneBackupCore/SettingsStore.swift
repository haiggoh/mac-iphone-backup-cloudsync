import Foundation

/// User-editable configuration, persisted as JSON.
///
/// A plain readable file rather than `UserDefaults` on purpose: it is documented, a
/// user can inspect and edit it, and it can be deleted to reset the app without
/// hunting through a preferences domain. Every field is optional or has a default, so
/// a partially hand-edited file still loads.
public struct Settings: Codable, Equatable {

    public static let currentVersion = 1

    public var version: Int

    /// nil until the user has chosen. Distinguishes "not asked yet" from "asked and
    /// answered", which is what makes the first-run prompt fire exactly once.
    public var cloudProvider: CloudProvider?

    /// The chosen destination root. Set when discovery found several and the user
    /// picked, or when they nominated a custom folder. nil means "discover it".
    public var cloudRootPath: String?

    /// Subfolder within the cloud root. Centralised here rather than hardcoded so a
    /// user who wants a different layout does not have to rebuild.
    public var destinationSubdirectory: String

    /// Archives kept before the app starts warning. It never deletes.
    public var archivesToKeep: Int

    /// Exposed deliberately: the shipped 900 s derives from two measurements, and a
    /// user whose backups behave differently must be able to raise it without waiting
    /// for a release.
    public var minimumSettleAge: TimeInterval

    /// Whether automation should be running. Kept separate from the LaunchAgent's
    /// actual state so the two can be compared — a mismatch means something outside
    /// the app changed it, and saying so is more useful than silently re-installing.
    public var automationEnabled: Bool

    public var automationIntervalSeconds: Int

    public init(
        version: Int = Settings.currentVersion,
        cloudProvider: CloudProvider? = nil,
        cloudRootPath: String? = nil,
        destinationSubdirectory: String = Configuration.defaultDestinationSubdirectory,
        archivesToKeep: Int = Configuration.defaultArchivesToKeep,
        minimumSettleAge: TimeInterval = Configuration.defaultMinimumSettleAge,
        automationEnabled: Bool = false,
        automationIntervalSeconds: Int = LaunchAgentManager.defaultStartInterval
    ) {
        self.version = version
        self.cloudProvider = cloudProvider
        self.cloudRootPath = cloudRootPath
        self.destinationSubdirectory = destinationSubdirectory
        self.archivesToKeep = archivesToKeep
        self.minimumSettleAge = minimumSettleAge
        self.automationEnabled = automationEnabled
        self.automationIntervalSeconds = automationIntervalSeconds
    }

    /// True before the user has made a destination choice.
    ///
    /// Note automation is NOT part of this test: setting up unattended archiving is
    /// optional and must stay optional, so declining it must not leave the app
    /// permanently believing first-run is unfinished.
    public var needsFirstRunSetup: Bool {
        cloudProvider == nil
    }

    /// Clamps hand-edited values into a range that cannot break the safety guarantees.
    ///
    /// Someone will edit this file and put 0 somewhere. A settle age of 0 would
    /// disable the one check standing between the app and a half-written archive, so
    /// the floor is enforced in code rather than trusted to the file.
    public func validated() -> Settings {
        var copy = self
        copy.archivesToKeep = max(0, min(archivesToKeep, 100))
        // 60 s floor: below the quiet period the gate stops meaning anything.
        copy.minimumSettleAge = max(60, min(minimumSettleAge, 24 * 60 * 60))
        // launchd treats very small intervals harshly, and anything under a minute
        // would poll far more often than a backup could possibly complete.
        copy.automationIntervalSeconds = max(60, min(automationIntervalSeconds, 24 * 60 * 60))
        if copy.destinationSubdirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.destinationSubdirectory = Configuration.defaultDestinationSubdirectory
        }
        return copy
    }
}

public struct SettingsStore {

    public enum StoreError: Error, Equatable {
        case writeFailed(String)
    }

    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public var fileURL: URL { url }

    /// Reads settings, falling back to defaults for anything absent or unreadable.
    ///
    /// A malformed file yields defaults rather than an error, and is NOT overwritten:
    /// a user who mistyped a brace should get working defaults and keep their file to
    /// fix, not silently lose it.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var settings = try? decoder.decode(Settings.self, from: data) else {
            return Settings()
        }
        if settings.version != Settings.currentVersion {
            settings.version = Settings.currentVersion
        }
        return settings.validated()
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(settings.validated()).write(to: url, options: .atomic)
            // May name a cloud account folder, which embeds a tenant; keep it private.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError.writeFailed(String(describing: error))
        }
    }

    /// Applies a change and persists it in one step, so no caller can mutate settings
    /// and forget to save.
    public func update(_ mutate: (inout Settings) -> Void) throws -> Settings {
        var settings = load()
        mutate(&settings)
        try save(settings)
        return settings.validated()
    }
}
