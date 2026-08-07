import Foundation

/// A cloud-sync service the archive can be written into.
///
/// Users overwhelmingly pick one service and stay there, so this is a first-run
/// choice persisted in settings rather than something asked repeatedly. The same
/// choice governs manual and automatic runs — an unattended run that wrote
/// somewhere different from the button would be a trap.
public enum CloudProvider: String, Codable, CaseIterable, Equatable {
    case oneDrive
    case iCloudDrive
    case googleDrive
    case dropbox
    /// A path the user supplied. Covers anything the others cannot reach: an
    /// external volume, a self-hosted sync folder, or no sync at all.
    case custom

    /// Providers worth scanning for. `custom` is excluded because there is
    /// nothing to discover — it is whatever path the user named.
    public static var discoverable: [CloudProvider] {
        allCases.filter { $0 != .custom }
    }

    /// Shown in the picker. Product names, deliberately not localized: "OneDrive"
    /// is "OneDrive" in every language.
    public var displayName: String {
        switch self {
        case .oneDrive: return "OneDrive"
        case .iCloudDrive: return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .custom: return "Custom folder"
        }
    }

    /// Where a provider keeps its folder.
    ///
    /// Two shapes, because the services genuinely differ: most create a
    /// per-account folder whose name embeds the account or tenant, so they must be
    /// matched by prefix; iCloud Drive uses one fixed path for everyone.
    enum Location {
        /// Scan `container` for directories whose name starts with `prefix`.
        case prefixed(container: String, prefix: String)
        /// One exact path relative to home.
        case fixed(relativePath: String)
    }

    var locations: [Location] {
        switch self {
        case .oneDrive:
            // Modern first. Business folders are "OneDrive-TenantName", personal
            // ones "OneDrive-Personal", legacy home ones "OneDrive - Tenant Name"
            // or bare "OneDrive" — all matched by prefix, so no tenant string
            // appears anywhere in this source.
            return [
                .prefixed(container: "Library/CloudStorage", prefix: "OneDrive"),
                .prefixed(container: "", prefix: "OneDrive"),
            ]
        case .googleDrive:
            return [
                .prefixed(container: "Library/CloudStorage", prefix: "GoogleDrive"),
                .prefixed(container: "", prefix: "Google Drive"),
            ]
        case .dropbox:
            return [
                .prefixed(container: "Library/CloudStorage", prefix: "Dropbox"),
                .prefixed(container: "", prefix: "Dropbox"),
            ]
        case .iCloudDrive:
            // Same path on every Mac, and it is not user-renameable.
            return [.fixed(relativePath: "Library/Mobile Documents/com~apple~CloudDocs")]
        case .custom:
            return []
        }
    }

    /// Reasons a provider may handle a ~50 GB archive badly.
    ///
    /// Surfaced as values so the UI can warn and the README can explain, without
    /// the app either silently allowing a bad choice or refusing a choice the user
    /// is entitled to make.
    public var largeArchiveCaveats: [CloudArchiveCaveat] {
        switch self {
        case .iCloudDrive:
            // "Optimise Mac Storage" evicts local copies, so an archive can become
            // dataless and need re-downloading; and the free tier is 5 GB, far
            // below one iPhone backup.
            return [.mayEvictLocalCopies, .smallFreeTier]
        case .oneDrive, .googleDrive, .dropbox:
            return [.mayEvictLocalCopies]
        case .custom:
            return []
        }
    }
}

public enum CloudArchiveCaveat: String, Equatable, Codable {
    /// The service may replace a local file with a placeholder to save disk space.
    case mayEvictLocalCopies
    /// The default free quota is smaller than a typical iPhone backup.
    case smallFreeTier
}
