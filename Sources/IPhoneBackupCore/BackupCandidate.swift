import Foundation

/// Where a candidate's completion date came from. Recorded rather than inferred,
/// because the three sources are not equally trustworthy and a log that says
/// "finished at X" is misleading if X was really just a folder mtime.
public enum CompletionDateSource: String, Equatable, Codable {
    /// `Status.plist`'s own `Date`. Authoritative — written by the backup itself.
    case statusPlist
    /// `Info.plist`'s `Last Backup Date`.
    case infoPlist
    /// Directory modification time. Last resort; moves for reasons unrelated to
    /// a backup completing.
    case directoryModificationDate
}

public struct BackupCandidate: Equatable {
    public let directoryURL: URL
    /// The backup folder name, i.e. the device UDID. Personal data — never logged
    /// in full, see `logDescription`.
    public let directoryName: String
    public let deviceName: String?
    public let productVersion: String?
    public let completionDate: Date
    public let dateSource: CompletionDateSource
    public let snapshotState: String?
    public let backupUUID: String?

    public init(
        directoryURL: URL,
        directoryName: String,
        deviceName: String? = nil,
        productVersion: String? = nil,
        completionDate: Date,
        dateSource: CompletionDateSource,
        snapshotState: String? = nil,
        backupUUID: String? = nil
    ) {
        self.directoryURL = directoryURL
        self.directoryName = directoryName
        self.deviceName = deviceName
        self.productVersion = productVersion
        self.completionDate = completionDate
        self.dateSource = dateSource
        self.snapshotState = snapshotState
        self.backupUUID = backupUUID
    }

    /// What "already archived this one" means.
    ///
    /// Directory name plus completion instant: the directory alone is wrong
    /// because iPhone backups are incremental and reuse the same folder for every
    /// subsequent backup, so a second backup on the same device must not look like
    /// the one already archived. Second precision, UTC, so it is stable regardless
    /// of the machine's timezone or DST.
    public var identity: String {
        "\(directoryName)@\(ArchiveNaming.identityStamp(completionDate))"
    }

    /// Safe to write to a log or a bug report: no UDID, no device name, no UUID.
    public var logDescription: String {
        let shortID = String(directoryName.prefix(8))
        return "\(shortID)… completed \(ArchiveNaming.identityStamp(completionDate)) "
            + "(date from \(dateSource.rawValue))"
    }
}

/// Archive filenames and identity stamps.
///
/// Timezone policy is deliberate and split: identities and stored state use UTC so
/// they never shift under DST or a travelling laptop, while the filename a human
/// reads in their own cloud folder uses local time, because "the backup from
/// yesterday evening" should look like it.
public enum ArchiveNaming {

    public static let filenamePrefix = "iPhone_Backup_"
    public static let filenameExtension = "zip"

    private static func formatter(utc: Bool) -> DateFormatter {
        let f = DateFormatter()
        // Fixed locale: without this, a non-Gregorian system calendar produces
        // filenames that neither sort nor parse.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        if utc { f.timeZone = TimeZone(secondsFromGMT: 0) }
        return f
    }

    /// UTC, second precision. Used inside identities and persisted state.
    public static func identityStamp(_ date: Date) -> String {
        formatter(utc: true).string(from: date)
    }

    /// Local time, second precision. Seconds matter: two backups of the same
    /// device in one minute would otherwise produce the same filename and the
    /// second would silently overwrite the first.
    public static func filenameStamp(_ date: Date) -> String {
        formatter(utc: false).string(from: date)
    }

    /// Reduces a device name to something safe in a filename on any filesystem:
    /// no separators, no colons, no leading dots, and bounded in length.
    public static func sanitize(deviceName: String) -> String? {
        let allowed = CharacterSet.alphanumerics
        let collapsed = String(
            deviceName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        let trimmed = collapsed
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(32))
    }

    /// The archive filename for a candidate.
    ///
    /// The device name is included only when more than one device is present.
    /// With a single device it adds nothing but noise, and leaving it out keeps
    /// the name identical to archives produced before multi-device support, so
    /// retention still recognises them.
    public static func filename(for candidate: BackupCandidate, multipleDevices: Bool) -> String {
        let stamp = filenameStamp(candidate.completionDate)
        if multipleDevices,
           let name = candidate.deviceName.flatMap(sanitize(deviceName:)) {
            return "\(filenamePrefix)\(name)_\(stamp).\(filenameExtension)"
        }
        return "\(filenamePrefix)\(stamp).\(filenameExtension)"
    }

    /// Whether a filename is one of ours, for retention counting. Deliberately
    /// narrow so it can never propose warning about an unrelated file.
    public static func isArchiveFilename(_ name: String) -> Bool {
        name.hasPrefix(filenamePrefix) && name.hasSuffix(".\(filenameExtension)")
    }
}
