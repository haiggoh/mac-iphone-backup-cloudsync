import Foundation

public struct ArchiveEntry: Equatable {
    public let url: URL
    public let filename: String
    public let size: Int64
    public let modified: Date

    public init(url: URL, filename: String, size: Int64, modified: Date) {
        self.url = url
        self.filename = filename
        self.size = size
        self.modified = modified
    }
}

public struct RetentionReport: Equatable {
    /// Newest first.
    public let archives: [ArchiveEntry]
    public let keep: Int

    public init(archives: [ArchiveEntry], keep: Int) {
        self.archives = archives
        self.keep = keep
    }

    /// Archives beyond the keep count — the ones a human might want to remove.
    /// Named "excess", not "deletable": nothing here is deleted by this app.
    ///
    /// **Newest first**, the same order as `archives`. A prune list often reads
    /// better oldest-first, but two properties of one type disagreeing about order
    /// is a trap, so callers that want oldest-first reverse it explicitly. The
    /// order was previously undocumented and a test duly assumed the opposite.
    public var excess: [ArchiveEntry] {
        guard keep >= 0, archives.count > keep else { return [] }
        return Array(archives.dropFirst(keep))
    }

    public var needsAttention: Bool { !excess.isEmpty }

    public var totalBytes: Int64 { archives.reduce(0) { $0 + $1.size } }
    public var excessBytes: Int64 { excess.reduce(0) { $0 + $1.size } }
}

/// Reports on accumulated archives. **It cannot delete anything.**
///
/// Each archive is tens of gigabytes and is a copy of data the user may no longer
/// have anywhere else, so the absence of a delete function is the design, not an
/// omission. An unattended process that runs every five minutes and holds the
/// power to remove 50 GB files is the most dangerous thing this app could contain;
/// a single logic error costs real backups. Warning is nearly as useful and cannot
/// destroy anything, so the capability simply does not exist here — there is no
/// code path to audit, and no future change can accidentally enable one.
public struct ArchiveRetention {

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Lists this app's archives in a destination folder, newest first.
    ///
    /// Matching is restricted to the app's own filename shape, so an unrelated zip
    /// the user keeps in the same folder is never counted and never mentioned.
    public func report(in destination: URL, keep: Int) -> RetentionReport {
        guard let names = try? fileManager.contentsOfDirectory(atPath: destination.path) else {
            return RetentionReport(archives: [], keep: keep)
        }

        let entries: [ArchiveEntry] = names
            .filter(ArchiveNaming.isArchiveFilename)
            .compactMap { name in
                let url = destination.appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date
                else { return nil }
                return ArchiveEntry(url: url, filename: name, size: size, modified: modified)
            }
            // By modification time rather than by parsing the filename: a filename
            // stamp is local-time and would misorder across a DST boundary.
            .sorted { $0.modified > $1.modified }

        return RetentionReport(archives: entries, keep: keep)
    }
}
