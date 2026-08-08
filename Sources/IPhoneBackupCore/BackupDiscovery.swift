import Foundation

/// A backup directory that was examined and refused, with the reason.
///
/// Kept rather than discarded so a log can explain why nothing was archived. "No
/// eligible backup" with no reason is the kind of message that makes a silent
/// failure indistinguishable from correct behaviour.
public struct BackupRejection: Equatable {
    public let directoryName: String
    public let reason: IncompleteReason

    /// Safe for logs: UDID truncated.
    public var logDescription: String {
        "\(directoryName.prefix(8))… rejected: \(reason)"
    }
}

public struct DiscoveryResult: Equatable {
    /// Valid, complete candidates, newest completion first.
    public let candidates: [BackupCandidate]
    public let rejections: [BackupRejection]
    /// Distinct backup directories seen, valid or not. Drives whether filenames
    /// need a device name to stay unique.
    public let directoriesSeen: Int

    public var hasMultipleDevices: Bool { directoriesSeen > 1 }
}

public struct BackupDiscovery {

    private let configuration: Configuration
    private let validator: BackupCompletionValidator
    private let fileManager: FileManager

    public init(
        configuration: Configuration,
        validator: BackupCompletionValidator = BackupCompletionValidator(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.validator = validator
        self.fileManager = fileManager
    }

    /// Enumerates every backup directory, validates each independently, and returns
    /// the valid ones newest first.
    ///
    /// Each directory is judged on its own so one malformed backup cannot hide a
    /// good one behind it — which matters with several devices, where the newest
    /// directory is not necessarily the usable one.
    ///
    /// - Parameter loadDeviceNames: reads `Info.plist` for display names. Off by
    ///   default because that file is ~58 MB and parsing it to choose a candidate
    ///   would be absurd; `Status.plist` carries the date and identity in 189 bytes.
    ///   Turn it on for the manual UI, or when several devices make a device name
    ///   necessary for a unique filename.
    public func discover(loadDeviceNames: Bool = false)
        -> Result<DiscoveryResult, ConfigurationProblem> {

        let root = configuration.backupRoot
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .failure(.backupRootMissing(path: root.path))
        }

        // Distinguishing unreadable from empty matters: unreadable almost always
        // means Full Disk Access was never granted, and telling the user their
        // backup folder is empty when it is really inaccessible sends them looking
        // in the wrong place.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .failure(.backupRootUnreadable(path: root.path))
        }

        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var candidates: [BackupCandidate] = []
        var rejections: [BackupRejection] = []

        for directory in directories {
            let name = directory.lastPathComponent

            switch validator.validateCompletion(directory: directory) {
            case .failure(let reason):
                rejections.append(BackupRejection(directoryName: name, reason: reason))

            case .success(let status):
                guard let dated = resolveDate(
                    for: directory, status: status, allowInfoPlist: true
                ) else {
                    rejections.append(
                        BackupRejection(directoryName: name, reason: .noCompletionDate))
                    continue
                }

                var deviceName: String?
                var productVersion: String?
                if loadDeviceNames {
                    let info = validator.readInfo(in: directory)
                    deviceName = info.deviceName
                    productVersion = info.productVersion
                }

                candidates.append(BackupCandidate(
                    directoryURL: directory,
                    directoryName: name,
                    deviceName: deviceName,
                    productVersion: productVersion,
                    completionDate: dated.date,
                    dateSource: dated.source,
                    snapshotState: status.snapshotState,
                    backupUUID: status.uuid
                ))
            }
        }

        candidates.sort { $0.completionDate > $1.completionDate }

        return .success(DiscoveryResult(
            candidates: candidates,
            rejections: rejections,
            directoriesSeen: directories.count
        ))
    }

    /// Establishes a completion date, preferring the most trustworthy source and
    /// recording which one was used.
    private func resolveDate(
        for directory: URL,
        status: StatusInfo,
        allowInfoPlist: Bool
    ) -> (date: Date, source: CompletionDateSource)? {
        // Written by the backup itself, and present on every backup observed.
        if let date = status.date { return (date, .statusPlist) }

        // Only reached when Status.plist has no Date. Expensive, hence guarded.
        if allowInfoPlist, let date = validator.readInfo(in: directory).lastBackupDate {
            return (date, .infoPlist)
        }

        // Last resort. Moves for reasons unrelated to a backup finishing, so it is
        // recorded as the weakest source rather than passed off as a real date.
        if let modified = try? directory.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate {
            return (modified, .directoryModificationDate)
        }

        return nil
    }

    /// The newest candidate that has not already been dealt with.
    public func newestUnprocessed(
        in result: DiscoveryResult,
        store: BackupStateStore
    ) -> BackupCandidate? {
        let state = store.load()
        let processed = Set(state.records.map(\.sourceIdentity))
        return result.candidates.first { !processed.contains($0.identity) }
    }
}
