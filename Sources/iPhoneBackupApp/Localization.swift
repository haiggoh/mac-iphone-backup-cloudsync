import Foundation
import IPhoneBackupCore

/// Shorthand for a localized string from the app bundle.
///
/// Localization lives entirely in this target, never in IPhoneBackupCore. Core
/// returns enums, and turning them into words happens here — which keeps core
/// testable without a bundle, and means a wording or language change cannot break a
/// test that asserts on behaviour.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""), arguments: arguments)
}

// MARK: - Presenting core outcomes

/// Turns core's structured results into user-facing text.
///
/// Deliberately exhaustive with no `default:` case. When a new reason is added to
/// core, this stops compiling — which is the point. A `default` here would silently
/// show a stale or generic message for a genuinely new condition.
enum Presenter {

    static func text(for reason: IncompleteReason) -> String {
        switch reason {
        case .snapshotNotFinished(let state):
            return L("incomplete.notFinished", state)
        case .manifestMissing:
            return L("incomplete.manifestMissing")
        case .manifestUnreadable:
            return L("incomplete.manifestUnreadable")
        case .statusPlistUnreadable:
            return L("incomplete.statusUnreadable")
        case .metadataStillChanging(let fields):
            return L("incomplete.stillChanging", fields.joined(separator: ", "))
        case .noCompletionDate:
            return L("incomplete.noDate")
        case .watchedFileEmpty(let name):
            return L("incomplete.fileEmpty", name)
        case .stillSettling(let age, let required):
            return L("incomplete.settling",
                     Self.duration(required - age))
        }
    }

    static func text(for problem: ConfigurationProblem) -> String {
        switch problem {
        case .multipleCloudRootsNeedSelection(let names):
            return L("config.multipleRoots", names.joined(separator: ", "))
        case .noCloudRootFound:
            return L("config.noRoot")
        case .configuredCloudRootMissing(let path):
            return L("config.rootMissing", path)
        case .backupRootMissing(let path):
            return L("status.folderMissing", path)
        case .backupRootUnreadable:
            return L("status.emptyOrNoAccess")
        }
    }

    static func text(for failure: RunFailure) -> String {
        switch failure {
        case .archiveToolFailed(let code, let tail):
            let base = L("error.archiveToolFailed", Int64(code))
            return tail.isEmpty ? base : "\(base)\n\(tail)"
        case .archiveImplausiblySmall(let bytes):
            return L("error.archiveTooSmall", bytes)
        case .insufficientFreeSpace(let available, let required):
            return L("error.insufficientSpace", bytes(available), bytes(required))
        case .stagingUnavailable(let detail):
            return L("error.targetFolderFailed", detail)
        case .finalMoveFailed(let detail, let staged):
            return "\(L("error.moveFailed", detail))\n\(L("error.stagedArchiveKept", staged))"
        case .stateWriteFailed(let detail):
            return L("error.stateWriteFailed", detail)
        case .archiveAlreadyExistsWithoutState(let path):
            return L("error.archiveExists", path)
        }
    }

    static func text(for reason: DeferralReason) -> String {
        switch reason {
        case .insufficientBattery(_, let needed):
            return L("deferred.battery", duration(needed))
        }
    }

    /// A stable signature for rate-limiting repeated error notifications.
    ///
    /// Uses only the *kind* of failure, never its interpolated detail: a path or an
    /// exit code that varies slightly between attempts would defeat suppression and
    /// notify every five minutes anyway.
    ///
    /// `RunFailure.code` is exactly that, and both strings are persisted, so this
    /// delegates rather than keeping a second hand-written copy of the same list —
    /// two lists would eventually disagree and silently break suppression.
    static func signature(for failure: RunFailure) -> String { failure.code }

    /// A whole run outcome as one sentence, for the Automation section.
    ///
    /// Exhaustive with no `default:`, like the rest of this type: a new outcome in core
    /// must stop this compiling rather than fall through to something stale. The
    /// Automation section previously interpolated `String(describing:)` here, which is
    /// how a raw Swift enum dump containing a home-folder path reached the UI.
    static func text(for result: AutomaticRunResult) -> String {
        switch result {
        case .archived(let url):
            return L("run.archived", url.lastPathComponent)
        case .nothingToDo:
            return L("run.nothingToDo")
        case .alreadyRunning:
            return L("run.alreadyRunning")
        case .incompleteBackup(let reason):
            return text(for: reason)
        case .deferred(let reason):
            return text(for: reason)
        case .configurationRequired(let problem):
            return text(for: problem)
        case .failed(let failure):
            return text(for: failure)
        }
    }

    /// The same thing for a *persisted* outcome, which is only a code.
    ///
    /// Deliberately payload-free — a stored code carries no path, count or duration, so
    /// these read a little more generally than the live messages above. That is the
    /// right trade: the alternative was showing the stored `String(describing:)`.
    ///
    /// Unknown or absent codes fall back to a neutral line rather than to the raw
    /// summary. A record written by a future version must not leak internals into the
    /// UI just because this build does not recognise it.
    ///
    /// Keys are built at runtime, so `Tools/check-localization.sh` cannot see them as
    /// literals — it carries a matching `run.code.` prefix rule so these are not
    /// reported as unused and the real unused-key signal stays trustworthy.
    static func text(forRunCode code: String?) -> String {
        guard let code else { return L("run.unknown") }
        let key = "run.code.\(code)"
        let localized = NSLocalizedString(key, bundle: .main, comment: "")
        // NSLocalizedString echoes the key back when the table has no entry for it.
        return localized == key ? L("run.unknown") : localized
    }

    /// LaunchAgent failures, named specifically. "Could not enable automation" would
    /// leave the user guessing between a bad install location, a malformed plist and a
    /// refusal from launchd — three problems with three different fixes.
    static func text(forAgentError error: Error) -> String {
        guard let agentError = error as? LaunchAgentError else {
            return String(describing: error)
        }
        switch agentError {
        case .unsuitableInstallation(let concerns):
            let detail = concerns.map(text(forConcern:)).joined(separator: " ")
            return "\(L("automation.badLocation")) \(detail)"
        case .couldNotWritePlist(let detail):
            return L("automation.writeFailed", detail)
        case .plistInvalid(let detail):
            return L("automation.plistInvalid", detail)
        case .bootstrapFailed(let code, let output):
            return L("automation.bootstrapFailed", Int64(code), output)
        case .bootoutFailed(let code, let output):
            return L("automation.bootoutFailed", Int64(code), output)
        case .verificationFailed(let detail):
            return L("automation.verificationFailed", detail)
        }
    }

    static func text(forConcern concern: InstallationConcern) -> String {
        switch concern {
        case .translocated:
            return L("automation.concernTranslocated")
        case .readOnlyVolume:
            return L("automation.concernReadOnly")
        case .volatileLocation:
            return L("automation.concernVolatile")
        }
    }

    static func text(forCaveat caveat: CloudArchiveCaveat) -> String {
        switch caveat {
        case .mayEvictLocalCopies:
            return L("caveat.mayEvict")
        case .smallFreeTier:
            return L("caveat.smallFreeTier")
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return L("duration.hoursMinutes", hours, minutes) }
        if minutes > 0 { return L("duration.minutesSeconds", minutes, secs) }
        return L("duration.seconds", secs)
    }
}
