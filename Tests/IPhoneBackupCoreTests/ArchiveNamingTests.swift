import XCTest
@testable import IPhoneBackupCore

final class ArchiveNamingTests: XCTestCase {
    func testIdentityStampExactUTCValue() {
        let date = Date(timeIntervalSince1970: 1785943354)
        let stamp = ArchiveNaming.identityStamp(date)
        XCTAssertEqual(stamp, "2026-08-05_15-22-34")
    }

    func testFilenameStampStructuralShape() {
        let date = Date()
        let stamp = ArchiveNaming.filenameStamp(date)
        
        XCTAssertTrue(stamp.hasPrefix("20"))
        XCTAssertTrue(stamp.hasSuffix(""))
        
        let pattern = "^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}$"
        let range = stamp.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(range)
    }

    func testSanitizeStripsSpacesAndPunctuation() {
        let result = ArchiveNaming.sanitize(deviceName: "My iPhone 12")
        XCTAssertEqual(result, "My-iPhone-12")
    }

    func testSanitizeCollapsesRunsOfSeparators() {
        let result = ArchiveNaming.sanitize(deviceName: "Device---Name")
        XCTAssertEqual(result, "Device-Name")
    }

    func testSanitizeCapsLengthAt32() {
        let longName = String(repeating: "A", count: 50)
        let result = ArchiveNaming.sanitize(deviceName: longName)
        XCTAssertEqual(result?.count, 32)
    }

    func testSanitizeReturnsNilForNoAlphanumerics() {
        let result = ArchiveNaming.sanitize(deviceName: "---!!!---")
        XCTAssertNil(result)
    }

    func testFilenameWithoutDeviceNameWhenMultipleDevicesIsFalse() {
        let date = Date()
        let candidate = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: "My Device",
            productVersion: nil,
            completionDate: date,
            dateSource: .statusPlist
        )
        let filename = ArchiveNaming.filename(for: candidate, multipleDevices: false)
        
        XCTAssertTrue(filename.hasPrefix(ArchiveNaming.filenamePrefix))
        XCTAssertTrue(filename.hasSuffix(".\(ArchiveNaming.filenameExtension)"))
        
        let pattern = "^iPhone_Backup_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}\\.zip$"
        let range = filename.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(range)
    }

    func testFilenameIncludesSanitizedDeviceNameWhenMultipleDevicesIsTrue() {
        let date = Date()
        let candidate = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: "My Device!",
            productVersion: nil,
            completionDate: date,
            dateSource: .statusPlist
        )
        let filename = ArchiveNaming.filename(for: candidate, multipleDevices: true)
        
        XCTAssertTrue(filename.hasPrefix(ArchiveNaming.filenamePrefix))
        XCTAssertTrue(filename.hasSuffix(".\(ArchiveNaming.filenameExtension)"))
        XCTAssertTrue(filename.contains("My-Device"))
    }

    func testFilenameOmitsDeviceNameWhenMultipleDevicesIsTrueButDeviceNameIsNil() {
        let date = Date()
        let candidate = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: nil,
            productVersion: nil,
            completionDate: date,
            dateSource: .statusPlist
        )
        let filename = ArchiveNaming.filename(for: candidate, multipleDevices: true)
        
        let pattern = "^iPhone_Backup_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}\\.zip$"
        let range = filename.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(range)
    }

    func testIsArchiveFilenameAcceptsRealArchiveName() {
        let validName = "iPhone_Backup_2026-08-05_15-22-34.zip"
        XCTAssertTrue(ArchiveNaming.isArchiveFilename(validName))
    }

    func testIsArchiveFilenameRejectsWrongPrefix() {
        let invalidName = "Backup_2026-08-05_15-22-34.zip"
        XCTAssertFalse(ArchiveNaming.isArchiveFilename(invalidName))
    }

    func testIsArchiveFilenameRejectsWrongExtension() {
        let invalidName = "iPhone_Backup_2026-08-05_15-22-34.tar"
        XCTAssertFalse(ArchiveNaming.isArchiveFilename(invalidName))
    }

    func testTwoCandidatesSameDirectoryDifferentDatesProduceDifferentIdentity() {
        let date1 = Date(timeIntervalSince1970: 1785943354)
        let date2 = Date(timeIntervalSince1970: 1785943355)
        
        let candidate1 = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: nil,
            productVersion: nil,
            completionDate: date1,
            dateSource: .statusPlist
        )
        
        let candidate2 = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: nil,
            productVersion: nil,
            completionDate: date2,
            dateSource: .statusPlist
        )
        
        XCTAssertFalse(candidate1.identity == candidate2.identity)
    }

    func testTwoCandidatesSameDirectorySameDateProduceEqualIdentity() {
        let date = Date(timeIntervalSince1970: 1785943354)
        
        let candidate1 = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: nil,
            productVersion: nil,
            completionDate: date,
            dateSource: .statusPlist
        )
        
        let candidate2 = BackupCandidate(
            directoryURL: URL(fileURLWithPath: "/tmp/does-not-matter"),
            directoryName: "backup1",
            deviceName: nil,
            productVersion: nil,
            completionDate: date,
            dateSource: .statusPlist
        )
        
        XCTAssertEqual(candidate1.identity, candidate2.identity)
    }
}

final class ConfigurationArgumentTests: XCTestCase {
    func testReadsValueAfterFlag() {
        let arguments = ["--output", "/path/to/output"]
        let value = Configuration.value(for: "--output", in: arguments)
        XCTAssertEqual(value, "/path/to/output")
    }

    func testReturnsNilWhenFlagIsMissing() {
        let arguments = ["--other", "value"]
        let value = Configuration.value(for: "--output", in: arguments)
        XCTAssertNil(value)
    }

    func testReturnsNilWhenFlagIsLastArgument() {
        let arguments = ["--output"]
        let value = Configuration.value(for: "--output", in: arguments)
        XCTAssertNil(value)
    }

    func testReturnsNilWhenNextArgumentStartsWithDashDash() {
        let arguments = ["--output", "--other"]
        let value = Configuration.value(for: "--output", in: arguments)
        XCTAssertNil(value)
    }

    func testPicksCorrectValueWhenSeveralFlagsArePresent() {
        let arguments = ["--input", "/path/to/input", "--output", "/path/to/output"]
        let inputValue = Configuration.value(for: "--input", in: arguments)
        let outputValue = Configuration.value(for: "--output", in: arguments)
        
        XCTAssertEqual(inputValue, "/path/to/input")
        XCTAssertEqual(outputValue, "/path/to/output")
    }
}