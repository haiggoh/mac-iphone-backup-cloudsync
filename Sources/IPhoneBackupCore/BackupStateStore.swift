import Foundation

/// How a backup came to be recorded as processed.
public enum RecordOrigin: String, Codable, Equatable {
    /// An archive was actually produced.
    case archived
    /// Marked processed without archiving, when automation was first enabled.
    ///
    /// Enabling a checkbox should not silently start a 50 GB upload of a backup
    /// taken days ago, so existing finished backups are baselined. Recorded as a
    /// distinct origin rather than a fake archive record, because claiming an
    /// archive exists when none does would be a lie the app later trips over.
    case baselinedAtFirstEnable
}

public struct ProcessedArchive: Codable, Equatable {
    /// `BackupCandidate.identity` — directory name plus completion instant. Holds a
    /// device UDID, so it is never written to a log or a bug report.
    public let sourceIdentity: String
    public let completionDate: Date
    public let dateSource: CompletionDateSource
    public let origin: RecordOrigin
    /// nil for baselined records, since no file was written.
    public let archiveFilename: String?
    public let archiveSize: Int64?
    public let completedAt: Date

    public init(
        sourceIdentity: String,
        completionDate: Date,
        dateSource: CompletionDateSource,
        origin: RecordOrigin,
        archiveFilename: String? = nil,
        archiveSize: Int64? = nil,
        completedAt: Date
    ) {
        self.sourceIdentity = sourceIdentity
        self.completionDate = completionDate
        self.dateSource = dateSource
        self.origin = origin
        self.archiveFilename = archiveFilename
        self.archiveSize = archiveSize
        self.completedAt = completedAt
    }
}

/// Remembers the last error the user was told about, so a failure that recurs
/// every five minutes does not produce a notification every five minutes.
public struct ErrorNotice: Codable, Equatable {
    public let signature: String
    public let notifiedAt: Date
}

/// The outcome of the most recent unattended run, whatever it was.
///
/// Exists because the unified log is not a dependable channel to the user. Reading it
/// needs admin rights on a managed Mac — verified directly: `log show` returns
/// "Could not open local log store: Operation not permitted" for a standard user, and
/// `log stream` refuses outright with "Must be admin". An app whose only record of an
/// unattended run lives somewhere the user cannot look is not diagnosable, so the
/// outcome is written here as well, where the app itself can read it back and show it.
///
/// `summary` is a stable enum description, not localized text: it is persisted, and a
/// stored string that changes with the UI language would be unreadable after a
/// language switch.
public struct LastRun: Codable, Equatable {
    public let at: Date
    public let summary: String
    public let wasSuccess: Bool
    /// Distinguishes an unattended run from a manual one, since "nothing happened for
    /// three days" means very different things in each case.
    public let wasAutomatic: Bool

    public init(at: Date, summary: String, wasSuccess: Bool, wasAutomatic: Bool) {
        self.at = at
        self.summary = summary
        self.wasSuccess = wasSuccess
        self.wasAutomatic = wasAutomatic
    }
}

public struct ProcessedState: Codable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var records: [ProcessedArchive]
    public var lastErrorNotice: ErrorNotice?
    /// Added in version 2. Optional, so a version-1 file still decodes.
    public var lastRun: LastRun?

    public init(
        version: Int = ProcessedState.currentVersion,
        records: [ProcessedArchive] = [],
        lastErrorNotice: ErrorNotice? = nil,
        lastRun: LastRun? = nil
    ) {
        self.version = version
        self.records = records
        self.lastErrorNotice = lastErrorNotice
        self.lastRun = lastRun
    }
}

/// Persists which backups have been dealt with.
///
/// Written atomically and only after an archive is safely in place, so an
/// interrupted run can repeat work but can never skip it. Losing a record costs
/// one redundant archive; writing one too early loses a backup silently, so the
/// asymmetry decides the ordering everywhere in this type.
public struct BackupStateStore {

    public enum StoreError: Error, Equatable {
        case encodingFailed(String)
        case writeFailed(String)
    }

    public static let defaultErrorSuppressionInterval: TimeInterval = 12 * 60 * 60

    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    // MARK: Load / save

    /// Reads the state, returning an empty one if it is absent or unreadable.
    ///
    /// Deliberately does not overwrite a file it could not parse. A corrupt state
    /// file means "unknown", and unknown must not become "empty" on disk — the
    /// archive-exists-without-state path handles the consequence safely, whereas
    /// truncating the file would destroy the only record of everything processed.
    public func load() -> ProcessedState {
        guard let data = try? Data(contentsOf: url) else { return ProcessedState() }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(ProcessedState.self, from: data) else {
            return ProcessedState()
        }

        // Forward migration: keep the records, adopt the current version. Older
        // versions have only ever added fields, so decoding already succeeded.
        if state.version != ProcessedState.currentVersion {
            state.version = ProcessedState.currentVersion
        }
        return state
    }

    public func save(_ state: ProcessedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw StoreError.encodingFailed(String(describing: error))
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // .atomic writes a temporary file and renames it, so a crash mid-write
            // leaves the previous state intact rather than a truncated file.
            try data.write(to: url, options: .atomic)
            // The file lists device UDIDs; no reason for it to be world-readable.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError.writeFailed(String(describing: error))
        }
    }

    // MARK: Queries

    public func hasProcessed(identity: String) -> Bool {
        load().records.contains { $0.sourceIdentity == identity }
    }

    public func record(for identity: String) -> ProcessedArchive? {
        load().records.first { $0.sourceIdentity == identity }
    }

    // MARK: Mutations

    /// Records a completed archive. Call only after the archive has reached its
    /// final location.
    public func recordArchive(
        candidate: BackupCandidate,
        archiveFilename: String,
        archiveSize: Int64,
        now: Date = Date()
    ) throws {
        var state = load()
        state.records.removeAll { $0.sourceIdentity == candidate.identity }
        state.records.append(
            ProcessedArchive(
                sourceIdentity: candidate.identity,
                completionDate: candidate.completionDate,
                dateSource: candidate.dateSource,
                origin: .archived,
                archiveFilename: archiveFilename,
                archiveSize: archiveSize,
                completedAt: now
            )
        )
        try save(state)
    }

    /// Marks already-finished backups as processed without archiving them, so
    /// turning automation on stays a cheap, quiet action.
    ///
    /// Skips anything already recorded, so enabling automation twice cannot
    /// downgrade a real archive record to a baseline.
    public func baseline(candidates: [BackupCandidate], now: Date = Date()) throws {
        var state = load()
        let known = Set(state.records.map(\.sourceIdentity))

        for candidate in candidates where !known.contains(candidate.identity) {
            state.records.append(
                ProcessedArchive(
                    sourceIdentity: candidate.identity,
                    completionDate: candidate.completionDate,
                    dateSource: candidate.dateSource,
                    origin: .baselinedAtFirstEnable,
                    completedAt: now
                )
            )
        }
        try save(state)
    }

    /// Records the outcome of a run, successful or not.
    ///
    /// Written on every path, including the boring ones. "Nothing to do" recorded at a
    /// recent timestamp is what tells a user the automation is alive; its absence is
    /// what tells them it is not running at all. Without that, a silently broken
    /// LaunchAgent is indistinguishable from a machine with no new backups.
    public func recordRun(
        summary: String,
        wasSuccess: Bool,
        wasAutomatic: Bool,
        now: Date = Date()
    ) throws {
        var state = load()
        state.lastRun = LastRun(
            at: now, summary: summary, wasSuccess: wasSuccess, wasAutomatic: wasAutomatic)
        try save(state)
    }

    public func lastRun() -> LastRun? { load().lastRun }

    // MARK: Error notification rate limiting

    /// Whether the user should be told about this failure now.
    ///
    /// A different failure is always worth reporting; the same one repeats every
    /// poll and is worth reporting occasionally. Logs are unaffected — suppression
    /// applies only to notifications, so diagnostics stay complete.
    public func shouldNotify(
        errorSignature: String,
        now: Date = Date(),
        suppressFor interval: TimeInterval = BackupStateStore.defaultErrorSuppressionInterval
    ) -> Bool {
        guard let last = load().lastErrorNotice else { return true }
        guard last.signature == errorSignature else { return true }
        return now.timeIntervalSince(last.notifiedAt) >= interval
    }

    public func noteNotified(errorSignature: String, now: Date = Date()) throws {
        var state = load()
        state.lastErrorNotice = ErrorNotice(signature: errorSignature, notifiedAt: now)
        try save(state)
    }

    /// Clears the suppression record after a success, so the next failure — even an
    /// identical one — is reported promptly rather than being swallowed because a
    /// similar error happened to occur within the window.
    public func clearErrorNotice() throws {
        var state = load()
        guard state.lastErrorNotice != nil else { return }
        state.lastErrorNotice = nil
        try save(state)
    }
}
