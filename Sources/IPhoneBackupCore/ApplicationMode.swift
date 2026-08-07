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

    public static let automaticFlag = "--automatic"
    public static let checkOnlyFlag = "--check-only"

    public static func parse(arguments: [String]) -> ApplicationMode {
        if arguments.contains(automaticFlag) { return .automatic }
        if arguments.contains(checkOnlyFlag) { return .checkOnly }
        return .manual
    }

    public var suppressesUserInterface: Bool {
        self != .manual
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
        case .incompleteBackup:
            // Not an error either — the backup simply is not ready yet.
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
