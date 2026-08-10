import Foundation

/// How the process was launched.
///
/// Parsed before any window exists. Automatic mode must never create and then
/// hide a window — under a LaunchAgent that briefly steals focus every five
/// minutes, which is worse than useless.
public enum ApplicationMode: Equatable {
    case manual
    case automatic
    case checkOnly
    /// Install or remove the LaunchAgent from the command line.
    ///
    /// The UI offers the same thing, but these exist as a first-class surface rather
    /// than a test hook: they make automation scriptable, they give a user a way to
    /// recover when the UI cannot launch, and they report a real exit status, which a
    /// button cannot.
    case installAutomation
    case removeAutomation

    public static let automaticFlag = "--automatic"
    public static let checkOnlyFlag = "--check-only"
    public static let installAutomationFlag = "--install-automation"
    public static let removeAutomationFlag = "--remove-automation"

    /// Order matters where flags could be combined: the destructive-sounding one is
    /// checked before the constructive one, so `--install-automation
    /// --remove-automation` removes rather than leaving a job loaded.
    public static func parse(arguments: [String]) -> ApplicationMode {
        if arguments.contains(removeAutomationFlag) { return .removeAutomation }
        if arguments.contains(installAutomationFlag) { return .installAutomation }
        if arguments.contains(automaticFlag) { return .automatic }
        if arguments.contains(checkOnlyFlag) { return .checkOnly }
        return .manual
    }

    public var suppressesUserInterface: Bool {
        self != .manual
    }

    /// Human-readable list for a usage message.
    public static var allFlags: [String] {
        [automaticFlag, checkOnlyFlag, installAutomationFlag, removeAutomationFlag]
    }
}

/// Why a run ended. Deliberately a value rather than a UI string: the UI owns
/// localization, so these stay stable across wording and language changes and
/// tests can assert on them.
public enum AutomaticRunResult: Equatable {
    case archived(URL)
    case nothingToDo
    case alreadyRunning
    case incompleteBackup(IncompleteReason)
    /// Everything is ready but conditions say wait — currently only insufficient
    /// battery. A success, like `nothingToDo`: the next poll will pick it up.
    case deferred(DeferralReason)
    case configurationRequired(ConfigurationProblem)
    case failed(RunFailure)

    /// Exit status for unattended runs.
    ///
    /// `alreadyRunning` and `nothingToDo` are successes: launchd polls every few
    /// minutes and most polls legitimately have nothing to do. Reporting those as
    /// failures would train anyone reading the logs to ignore real ones.
    public var exitCode: Int32 {
        switch self {
        case .archived, .nothingToDo, .alreadyRunning:
            return 0
        case .incompleteBackup, .deferred:
            // Not errors either — the backup is not ready yet, or conditions say
            // wait. Reporting these as failures would train anyone reading the logs
            // to ignore the real ones.
            return 0
        case .configurationRequired, .failed:
            return 1
        }
    }

    public var isSuccess: Bool { exitCode == 0 }
}

/// The three reason types below conform to `Error` so they can be the failure
/// type of a `Result`. They are still plain values with no localized text — the
/// UI layer turns them into words.
public enum IncompleteReason: Equatable, Error {
    case snapshotNotFinished(state: String)
    case manifestMissing
    case manifestUnreadable
    case statusPlistUnreadable
    case metadataStillChanging(fields: [String])
    case noCompletionDate
    /// A watched file exists but has zero length. Never valid, and observed
    /// happening on real hardware minutes after the backup claimed to be finished.
    case watchedFileEmpty(name: String)
    /// Something was modified too recently to trust. `newestAge` is how long ago
    /// the most recent write was, `required` the minimum age demanded.
    case stillSettling(newestAge: TimeInterval, required: TimeInterval)
}

public enum DeferralReason: Equatable, Error {
    /// On battery, and the estimated job outlasts the remaining charge.
    case insufficientBattery(secondsRemaining: TimeInterval?, secondsNeeded: TimeInterval)
}

public enum ConfigurationProblem: Equatable, Error {
    /// Several genuinely distinct cloud roots exist and none was chosen. Automatic
    /// mode refuses rather than guessing which account a 50 GB archive belongs in.
    case multipleCloudRootsNeedSelection(displayNames: [String])
    case noCloudRootFound
    /// A previously chosen root no longer exists — the account was removed, or an
    /// external volume is unmounted.
    case configuredCloudRootMissing(path: String)
    case backupRootMissing(path: String)
    case backupRootUnreadable(path: String)
}

public enum RunFailure: Equatable, Error {
    case archiveToolFailed(exitCode: Int32, stderrTail: String)
    case archiveImplausiblySmall(bytes: Int64)
    case insufficientFreeSpace(availableBytes: Int64, requiredBytes: Int64)
    case stagingUnavailable(String)
    case finalMoveFailed(String, stagedArchivePath: String)
    case stateWriteFailed(String)
    case archiveAlreadyExistsWithoutState(path: String)
}
