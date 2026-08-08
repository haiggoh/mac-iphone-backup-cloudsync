import XCTest
@testable import IPhoneBackupCore

final class ArchiveRetentionTests: XCTestCase {
    private var dir: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        let uniqueName = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dir = tempDir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
    }

    private func makeArchive(_ name: String, bytes: Int, modified: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testReportOnNonExistentDirectory() throws {
        let retention = ArchiveRetention(fileManager: fileManager)
        let nonExistentDir = dir.appendingPathComponent("does_not_exist")
        let report = retention.report(in: nonExistentDir, keep: 5)

        XCTAssertTrue(report.archives.isEmpty)
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(report.keep, 5)
        XCTAssertEqual(report.totalBytes, 0)
        XCTAssertEqual(report.excessBytes, 0)
    }

    func testReportOnEmptyDirectory() throws {
        let retention = ArchiveRetention(fileManager: fileManager)
        let report = retention.report(in: dir, keep: 5)

        XCTAssertTrue(report.archives.isEmpty)
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(report.keep, 5)
        XCTAssertEqual(report.totalBytes, 0)
        XCTAssertEqual(report.excessBytes, 0)
    }

    func testArchivesSortedNewestFirst() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        // Create archives with distinct modification dates but names that don't imply order
        let date1 = Date(timeIntervalSince1970: 1000) // Oldest
        let date2 = Date(timeIntervalSince1970: 2000) // Middle
        let date3 = Date(timeIntervalSince1970: 3000) // Newest

        let name1 = "iPhone_Backup_2026-01-01_00-00-00.zip"
        let name2 = "iPhone_Backup_2026-02-01_00-00-00.zip"
        let name3 = "iPhone_Backup_2026-03-01_00-00-00.zip"

        // Assign dates deliberately out of order relative to names if we wanted, 
        // but here we just ensure distinct dates. 
        // Let's swap dates to ensure sorting is by date, not name.
        // Name 1 gets Newest date
        // Name 2 gets Oldest date
        // Name 3 gets Middle date
        
        _ = try makeArchive(name1, bytes: 100, modified: date3) // Newest
        _ = try makeArchive(name2, bytes: 100, modified: date1) // Oldest
        _ = try makeArchive(name3, bytes: 100, modified: date2) // Middle

        let report = retention.report(in: dir, keep: 10)

        XCTAssertEqual(report.archives.count, 3)
        
        // Newest first
        XCTAssertEqual(report.archives[0].filename, name1)
        XCTAssertEqual(report.archives[1].filename, name3)
        XCTAssertEqual(report.archives[2].filename, name2)
    }

    func testNonArchivesIgnored() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        // Create valid archive
        let validName = "iPhone_Backup_2026-08-05_17-25-00.zip"
        _ = try makeArchive(validName, bytes: 100, modified: Date(timeIntervalSince1970: 1000))

        // Create non-archives
        let nonArchive1 = "notes.txt"
        let nonArchive2 = "SomethingElse.zip" // Wrong prefix
        let nonArchive3 = "iPhone_Backup_2026-01-01_00-00-00.txt" // Wrong extension

        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent(nonArchive1))
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent(nonArchive2))
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent(nonArchive3))

        let report = retention.report(in: dir, keep: 5)

        XCTAssertEqual(report.archives.count, 1)
        XCTAssertEqual(report.archives[0].filename, validName)
    }

    func testKeepMoreThanPresent() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        _ = try makeArchive("iPhone_Backup_2026-01-01_00-00-00.zip", bytes: 100, modified: date1)
        _ = try makeArchive("iPhone_Backup_2026-02-01_00-00-00.zip", bytes: 200, modified: date2)

        let report = retention.report(in: dir, keep: 3)

        XCTAssertEqual(report.archives.count, 2)
        XCTAssertTrue(report.excess.isEmpty)
        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(report.keep, 3)
    }

    func testExcessContainsOldest() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        // Create 5 archives with distinct dates
        let dates = [1000, 2000, 3000, 4000, 5000].map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let names = (1...5).map { "iPhone_Backup_2026-0\($0)-01_00-00-00.zip" }

        for (i, name) in names.enumerated() {
            _ = try makeArchive(name, bytes: 100, modified: dates[i])
        }

        let report = retention.report(in: dir, keep: 2)

        XCTAssertEqual(report.archives.count, 5)
        XCTAssertEqual(report.excess.count, 3)
        XCTAssertTrue(report.needsAttention)

        // Excess is the 3 oldest files (dates 1000, 2000, 3000 -> names 0, 1, 2),
        // reported NEWEST FIRST to match `archives`. Asserting the set as well as
        // the order, so a future ordering change fails loudly rather than silently
        // reporting the wrong files.
        let expectedNewestFirst = [names[2], names[1], names[0]]
        let actualExcessNames = report.excess.map { $0.filename }
        XCTAssertEqual(actualExcessNames, expectedNewestFirst)
        XCTAssertEqual(Set(actualExcessNames), Set([names[0], names[1], names[2]]))
    }

    func testExcessEmptyWhenKeepEqualsCount() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        _ = try makeArchive("iPhone_Backup_2026-01-01_00-00-00.zip", bytes: 100, modified: date1)
        _ = try makeArchive("iPhone_Backup_2026-02-01_00-00-00.zip", bytes: 200, modified: date2)

        let report = retention.report(in: dir, keep: 2)

        XCTAssertEqual(report.archives.count, 2)
        XCTAssertTrue(report.excess.isEmpty)
        XCTAssertFalse(report.needsAttention)
    }

    func testKeepZeroMeansAllExcess() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        _ = try makeArchive("iPhone_Backup_2026-01-01_00-00-00.zip", bytes: 100, modified: date1)
        _ = try makeArchive("iPhone_Backup_2026-02-01_00-00-00.zip", bytes: 200, modified: date2)

        let report = retention.report(in: dir, keep: 0)

        XCTAssertEqual(report.archives.count, 2)
        XCTAssertEqual(report.excess.count, 2)
        XCTAssertTrue(report.needsAttention)
    }

    func testTotalAndExcessBytes() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        // Create 3 archives with distinct sizes
        let date1 = Date(timeIntervalSince1970: 1000) // Oldest
        let date2 = Date(timeIntervalSince1970: 2000) // Middle
        let date3 = Date(timeIntervalSince1970: 3000) // Newest

        let size1 = 1000
        let size2 = 2000
        let size3 = 3000

        _ = try makeArchive("iPhone_Backup_2026-01-01_00-00-00.zip", bytes: size1, modified: date1)
        _ = try makeArchive("iPhone_Backup_2026-02-01_00-00-00.zip", bytes: size2, modified: date2)
        _ = try makeArchive("iPhone_Backup_2026-03-01_00-00-00.zip", bytes: size3, modified: date3)

        let report = retention.report(in: dir, keep: 2)

        // Total bytes should be sum of all
        XCTAssertEqual(report.totalBytes, Int64(size1 + size2 + size3))

        // Excess should be the oldest one (size1)
        XCTAssertEqual(report.excess.count, 1)
        XCTAssertEqual(report.excessBytes, Int64(size1))
    }

    func testNegativeKeepDoesNotCrash() throws {
        let retention = ArchiveRetention(fileManager: fileManager)

        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        _ = try makeArchive("iPhone_Backup_2026-01-01_00-00-00.zip", bytes: 100, modified: date1)
        _ = try makeArchive("iPhone_Backup_2026-02-01_00-00-00.zip", bytes: 200, modified: date2)

        let report = retention.report(in: dir, keep: -1)

        // Should not crash
        // Excess should be empty as per requirement
        XCTAssertTrue(report.excess.isEmpty)
        XCTAssertFalse(report.needsAttention)
    }
}