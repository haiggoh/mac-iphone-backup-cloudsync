import Foundation

/// The contents of a backup's `Status.plist`.
///
/// Observed on macOS 26.6 / iOS 26 (development machine, 2026-08-07):
///
///     SnapshotState => "finished"
///     BackupState   => "new"
///     Date          => 2026-08-05 15:22:34 +0000
///     UUID          => 00000000-…
///     IsFullBackup  => false
///     Version       => "3.3"
///
/// None of this is documented public API. It is an observation, so the code treats
/// every field as optional and refuses to proceed when it cannot read what it
/// needs, rather than assuming a shape.
public struct StatusInfo: Equatable {
    public let snapshotState: String
    public let backupState: String?
    public let date: Date?
    public let uuid: String?
    public let isFullBackup: Bool?
    public let version: String?
}

public struct FileStamp: Equatable {
    public let size: Int64
    public let modified: Date
}

/// Size and mtime of the files that move while a backup is being written.
///
/// Cheap on purpose: a completed backup holds a few hundred thousand files, so
/// recursively walking it to decide whether it is still growing would cost more
/// than the archive itself. Three stat calls answer the same question.
public struct MetadataFingerprint: Equatable {
    public let stamps: [String: FileStamp?]

    /// Names of the files that differ, for logging a precise reason rather than
    /// "something changed".
    public func changedFields(comparedTo other: MetadataFingerprint) -> [String] {
        let names = Set(stamps.keys).union(other.stamps.keys)
        // Parentheses are load-bearing: ?? binds looser than !=, so without them
        // this compares a FileStamp? against a Bool.
        return names.filter { (stamps[$0] ?? nil) != (other.stamps[$0] ?? nil) }.sorted()
    }
}

/// Waiting, injected so tests do not actually sleep for a minute.
public protocol QuietPeriodClock {
    func wait(_ interval: TimeInterval)
}

public struct SystemClock: QuietPeriodClock {
    public init() {}
    public func wait(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

/// A clock that returns immediately, recording what it was asked to wait for.
public final class ImmediateClock: QuietPeriodClock {
    public private(set) var requestedWaits: [TimeInterval] = []
    public init() {}
    public func wait(_ interval: TimeInterval) { requestedWaits.append(interval) }
}

public struct BackupCompletionValidator {

    /// The files whose stability decides whether writing has stopped.
    ///
    /// `Info.plist` earns its place here despite being large. On the development
    /// machine `Status.plist` reached `SnapshotState = finished` at 17:22:34 while
    /// `Info.plist` (58 MB) was not finished until 17:25:16 — **2m42s later**. So
    /// "finished" is emphatically not "done writing", and watching only
    /// `Status.plist` would archive a backup that is still changing underneath.
    public static let watchedFiles = ["Status.plist", "Manifest.db", "Info.plist"]

    public static let finishedSnapshotState = "finished"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: Reading

    public func readStatus(in directory: URL) -> StatusInfo? {
        let url = directory.appendingPathComponent("Status.plist")
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let plist = raw as? [String: Any],
              let snapshotState = plist["SnapshotState"] as? String
        else { return nil }

        return StatusInfo(
            snapshotState: snapshotState,
            backupState: plist["BackupState"] as? String,
            date: plist["Date"] as? Date,
            uuid: plist["UUID"] as? String,
            isFullBackup: plist["IsFullBackup"] as? Bool,
            version: plist["Version"] as? String
        )
    }

    /// Reads `Info.plist`, which is expensive — 58 MB on the development machine,
    /// because it embeds device artwork and an application list. Never call this
    /// while merely deciding *which* backup to archive; `Status.plist` carries the
    /// date and identity for that at 189 bytes. This is for display, and for the
    /// filename when several devices make one necessary.
    public func readInfo(in directory: URL)
        -> (deviceName: String?, lastBackupDate: Date?, productVersion: String?) {
        let url = directory.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let plist = raw as? [String: Any]
        else { return (nil, nil, nil) }

        return (
            plist["Device Name"] as? String,
            plist["Last Backup Date"] as? Date,
            plist["Product Version"] as? String
        )
    }

    // MARK: Completion

    /// Whether a directory holds a backup that has finished being taken.
    ///
    /// Conservative by construction: every unreadable or unexpected condition is a
    /// refusal, never a shrug. The cost of a false negative is one skipped poll
    /// five minutes later; the cost of a false positive is a corrupt 50 GB archive
    /// that replaced a good one.
    public func validateCompletion(directory: URL) -> Result<StatusInfo, IncompleteReason> {
        guard let status = readStatus(in: directory) else {
            return .failure(.statusPlistUnreadable)
        }

        // Case-insensitive: the value is not contractual, so do not depend on its
        // exact casing surviving an OS update.
        guard status.snapshotState.lowercased() == Self.finishedSnapshotState else {
            return .failure(.snapshotNotFinished(state: status.snapshotState))
        }

        let manifest = directory.appendingPathComponent("Manifest.db")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: manifest.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .failure(.manifestMissing)
        }
        guard fileManager.isReadableFile(atPath: manifest.path) else {
            return .failure(.manifestUnreadable)
        }

        // A zero-length watched file is never a valid backup, and this is not
        // hypothetical: on 2026-08-07 Info.plist was observed at 0 bytes for ~3
        // seconds, 3m53s after the backup reported itself finished. Archiving in
        // that window produces a backup that cannot be restored, while every other
        // signal says success.
        for name in Self.watchedFiles {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else { continue }   // absent is handled by the checks above
            if size == 0 {
                return .failure(.watchedFileEmpty(name: name))
            }
        }

        return .success(status)
    }

    // MARK: Settling

    /// The most recent modification time across the watched files, or nil if none
    /// could be read.
    public func newestModification(directory: URL) -> Date? {
        fingerprint(directory: directory).stamps.values
            .compactMap { $0?.modified }
            .max()
    }

    /// Requires that nothing has been written *recently*.
    ///
    /// This complements the two-sample quiet period rather than replacing it, and
    /// it is the gate that actually catches Apple's late rewrite. Two samples taken
    /// during a lull both look identical, so they cannot distinguish "finished" from
    /// "between two writes" — but an mtime only minutes old proves the latter.
    public func confirmSettled(
        directory: URL,
        minimumAge: TimeInterval,
        now: Date = Date()
    ) -> Result<Void, IncompleteReason> {
        guard let newest = newestModification(directory: directory) else {
            return .failure(.statusPlistUnreadable)
        }
        let age = now.timeIntervalSince(newest)
        guard age >= minimumAge else {
            return .failure(.stillSettling(newestAge: age, required: minimumAge))
        }
        return .success(())
    }

    /// The single gate the archiver should use: complete, settled, and stable.
    ///
    /// Ordered cheapest-first so a backup that is obviously not ready costs three
    /// stat calls rather than a minute of waiting.
    public func confirmReadyToArchive(
        directory: URL,
        minimumSettleAge: TimeInterval,
        quietPeriod: TimeInterval,
        clock: QuietPeriodClock = SystemClock(),
        now: @escaping () -> Date = Date.init
    ) -> Result<StatusInfo, IncompleteReason> {
        if case .failure(let reason) = validateCompletion(directory: directory) {
            return .failure(reason)
        }
        if case .failure(let reason) = confirmSettled(
            directory: directory, minimumAge: minimumSettleAge, now: now()
        ) {
            return .failure(reason)
        }
        return confirmStable(directory: directory, quietPeriod: quietPeriod, clock: clock)
    }

    // MARK: Stability

    public func fingerprint(directory: URL) -> MetadataFingerprint {
        var stamps: [String: FileStamp?] = [:]
        for name in Self.watchedFiles {
            let url = directory.appendingPathComponent(name)
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = (attributes[.size] as? NSNumber)?.int64Value,
               let modified = attributes[.modificationDate] as? Date {
                stamps[name] = FileStamp(size: size, modified: modified)
            } else {
                stamps[name] = nil
            }
        }
        return MetadataFingerprint(stamps: stamps)
    }

    /// Confirms nothing has moved for `quietPeriod`, and that the backup still
    /// claims to be finished afterwards.
    ///
    /// Re-checking the state at the end matters: a new backup starting during the
    /// quiet window flips `SnapshotState` away from `finished`, and archiving then
    /// would capture a half-written snapshot.
    public func confirmStable(
        directory: URL,
        quietPeriod: TimeInterval,
        clock: QuietPeriodClock = SystemClock()
    ) -> Result<StatusInfo, IncompleteReason> {
        let before = fingerprint(directory: directory)
        clock.wait(quietPeriod)
        let after = fingerprint(directory: directory)

        let changed = before.changedFields(comparedTo: after)
        guard changed.isEmpty else {
            return .failure(.metadataStillChanging(fields: changed))
        }

        return validateCompletion(directory: directory)
    }
}
