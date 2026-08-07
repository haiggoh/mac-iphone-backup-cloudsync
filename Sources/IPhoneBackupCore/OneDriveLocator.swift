import Foundation

/// A cloud-sync destination root the archive can be written into.
public struct CloudRoot: Equatable, Hashable {
    public let url: URL
    /// Symlinks resolved. Two entries with the same canonical path are one root,
    /// not two — see `discover`.
    public let canonicalPath: String
    /// What to show a human choosing between roots. The folder name, which for
    /// business accounts contains the tenant, so it is never logged.
    public let displayName: String

    public init(url: URL) {
        self.url = url
        self.canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.displayName = url.lastPathComponent
    }
}

public enum CloudRootResolution: Equatable {
    case resolved(CloudRoot)
    case ambiguous([CloudRoot])
    case none
}

/// Finds the OneDrive folder without knowing anything about the machine it runs on.
///
/// Four layers, in order of authority:
///   1. an explicit user-configured path, which wins outright — this is what makes
///      an unusual setup reachable at all (custom sync location, external volume,
///      or a folder that is not OneDrive);
///   2. `~/Library/CloudStorage/OneDrive*`, where modern OneDrive actually lives;
///   3. legacy `~/OneDrive*` in the home folder;
///   4. canonical-path dedupe across 2 and 3.
///
/// Layer 4 is not cosmetic. macOS commonly leaves `~/OneDrive - Company` as a
/// symlink to the CloudStorage folder, so a naive scan finds two entries, concludes
/// the setup is ambiguous, and refuses to run unattended — on a machine with
/// exactly one account. Confirmed on the development machine.
///
/// Prefix matching (not an exact name) is what makes it universal: it covers bare
/// `OneDrive`, `OneDrive-Personal`, and `OneDrive - Any Company Name` alike, with
/// no tenant string anywhere in the source.
public struct CloudRootLocator {

    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(fileManager: FileManager = .default, homeDirectory: URL? = nil) {
        self.fileManager = fileManager
        // Resolved through Foundation rather than interpolating a username.
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    /// Directories that OneDrive is known to use, most modern first.
    private var searchLocations: [(container: URL, prefix: String)] {
        [
            (homeDirectory.appendingPathComponent("Library/CloudStorage"), "OneDrive"),
            (homeDirectory, "OneDrive"),
        ]
    }

    /// Every distinct root on this machine, in discovery order, deduped by
    /// canonical path. The first occurrence wins, so a modern CloudStorage entry
    /// is preferred over the legacy symlink pointing at it.
    public func discover() -> [CloudRoot] {
        var seen = Set<String>()
        var roots: [CloudRoot] = []

        for location in searchLocations {
            guard let names = try? fileManager.contentsOfDirectory(
                atPath: location.container.path
            ) else { continue }

            for name in names.sorted() where name.hasPrefix(location.prefix) {
                let candidate = location.container.appendingPathComponent(name)
                guard isUsableDirectory(candidate) else { continue }

                let root = CloudRoot(url: candidate)
                // The dedupe that keeps one account from looking like two.
                guard seen.insert(root.canonicalPath).inserted else { continue }
                roots.append(root)
            }
        }
        return roots
    }

    /// Resolves the root to actually use.
    ///
    /// - Parameter configuredPath: a path the user chose previously. It takes
    ///   precedence over discovery entirely, and its absence is reported rather
    ///   than silently falling back — a missing configured destination means an
    ///   unmounted volume or a removed account, and quietly writing 50 GB
    ///   somewhere else would be worse than stopping.
    public func resolve(configuredPath: String?) -> CloudRootResolution {
        if let configuredPath, !configuredPath.isEmpty {
            let url = URL(fileURLWithPath: configuredPath)
            return isUsableDirectory(url) ? .resolved(CloudRoot(url: url)) : .none
        }

        let roots = discover()
        switch roots.count {
        case 0: return .none
        case 1: return .resolved(roots[0])
        default: return .ambiguous(roots)
        }
    }

    private func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return true
    }
}
