import Foundation
import os

/// Log categories, matching the stages a run passes through so a reader can filter
/// to the part that interests them.
public enum LogCategory: String, CaseIterable {
    case discovery
    case completion
    case archive
    case automation
    case launchAgent
    case cloud
    case permissions
    case retention
}

/// Unified-logging access, keyed on the bundle identifier as subsystem.
///
/// Unified logging rather than a file in /tmp: it survives without the app being
/// running, is readable with one documented `log show` command, and cannot fill a
/// disk. The tradeoff is that entries are not permanent, which is fine — these are
/// diagnostics, not the record of what was archived. That record is the state file.
///
/// **Level matters more than it looks.** `os_log` does not persist `.debug` or
/// `.info` to disk at all — they live in a memory ring buffer and are gone once the
/// process exits. An unattended run that logged its outcome at `.info` therefore left
/// nothing behind, and the documented `log show` command returned an empty result:
/// the app appeared never to have run. Verified directly, and it is exactly the
/// silent-failure shape this project exists to avoid.
///
/// So: anything a human may need to read *after the fact* is `.notice` or higher.
/// `.debug` is for per-item detail that is only useful while watching live, and
/// reading it needs `log show --info --debug`.
///
/// Nothing here logs backup contents, device names, full UDIDs or UUIDs. Candidates
/// expose `logDescription` for exactly this reason: a user pasting log output into a
/// public issue must not be pasting their device identifiers.
public struct AppLogger {

    private let subsystem: String
    private var loggers: [LogCategory: Logger] = [:]

    public init(subsystem: String) {
        self.subsystem = subsystem
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
    }

    public func log(_ category: LogCategory) -> Logger {
        // Every category is populated in init, so this fallback is unreachable; it
        // exists only to keep the accessor non-optional at call sites.
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// The command to hand a user asking how to see what happened. Shows the
    /// persisted levels, which is where every outcome is recorded.
    public var inspectionCommand: String {
        "log show --last 1h --predicate 'subsystem == \"\(subsystem)\"'"
    }

    /// Adds the ephemeral levels for per-candidate detail. Only meaningful for a run
    /// that is happening now or has just happened, since these are never written to
    /// disk.
    public var verboseInspectionCommand: String {
        "log show --last 15m --info --debug --predicate 'subsystem == \"\(subsystem)\"'"
    }
}
