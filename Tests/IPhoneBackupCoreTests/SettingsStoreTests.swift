import XCTest
@testable import IPhoneBackupCore

final class SettingsStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: SettingsStore!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        let uniqueName = UUID().uuidString
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        settingsURL = tempDirectory.appendingPathComponent("settings.json")
        store = SettingsStore(url: settingsURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDirectory)
        store = nil
        tempDirectory = nil
        settingsURL = nil
    }

    func testLoadDefaultsOnNonexistentFile() throws {
        let settings = store.load()
        XCTAssertEqual(settings.version, 1)
        XCTAssertNil(settings.cloudProvider)
        XCTAssertNil(settings.cloudRootPath)
        XCTAssertEqual(settings.destinationSubdirectory, "_iPhone-BU")
        XCTAssertEqual(settings.archivesToKeep, 3)
        XCTAssertEqual(settings.minimumSettleAge, 900)
        XCTAssertEqual(settings.automationEnabled, false)
        XCTAssertEqual(settings.automationIntervalSeconds, 300)
    }

    func testLoadInvalidJSONReturnsDefaultsAndPreservesFile() throws {
        let invalidJSON = "not json"
        try invalidJSON.write(to: settingsURL, atomically: true, encoding: .utf8)
        let initialData = try Data(contentsOf: settingsURL)

        let settings = store.load()
        XCTAssertEqual(settings.version, 1)
        XCTAssertEqual(settings.archivesToKeep, 3)

        let finalData = try Data(contentsOf: settingsURL)
        XCTAssertEqual(initialData, finalData)
    }

    func testSaveLoadRoundTrip() throws {
        var settings = Settings()
        settings.cloudProvider = .oneDrive
        settings.cloudRootPath = "/Backups"
        settings.destinationSubdirectory = "CustomDir"
        settings.archivesToKeep = 10
        settings.minimumSettleAge = 1200
        settings.automationEnabled = true
        settings.automationIntervalSeconds = 600

        try store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.cloudProvider, .oneDrive)
        XCTAssertEqual(loaded.cloudRootPath, "/Backups")
        XCTAssertEqual(loaded.destinationSubdirectory, "CustomDir")
        XCTAssertEqual(loaded.archivesToKeep, 10)
        XCTAssertEqual(loaded.minimumSettleAge, 1200)
        XCTAssertEqual(loaded.automationEnabled, true)
        XCTAssertEqual(loaded.automationIntervalSeconds, 600)
    }

    func testSaveSetsPermissionsTo600() throws {
        let settings = Settings()
        try store.save(settings)

        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testNeedsFirstRunSetupTrueWhenCloudProviderNil() throws {
        var settings = Settings()
        settings.cloudProvider = nil
        XCTAssertTrue(settings.needsFirstRunSetup)

        settings.automationEnabled = true
        XCTAssertTrue(settings.needsFirstRunSetup)
    }

    func testNeedsFirstRunSetupFalseWhenCloudProviderSet() throws {
        var settings = Settings()
        settings.cloudProvider = .iCloudDrive
        settings.automationEnabled = false
        XCTAssertFalse(settings.needsFirstRunSetup)
    }

    func testValidatedClampsArchivesToKeep() throws {
        var settings = Settings()
        settings.archivesToKeep = -5
        XCTAssertEqual(settings.validated().archivesToKeep, 0)

        settings.archivesToKeep = 500
        XCTAssertEqual(settings.validated().archivesToKeep, 100)

        settings.archivesToKeep = 3
        XCTAssertEqual(settings.validated().archivesToKeep, 3)
    }

    func testValidatedClampsMinimumSettleAge() throws {
        var settings = Settings()
        settings.minimumSettleAge = 0
        XCTAssertEqual(settings.validated().minimumSettleAge, 60)

        settings.minimumSettleAge = 30
        XCTAssertEqual(settings.validated().minimumSettleAge, 60)

        settings.minimumSettleAge = 999999
        XCTAssertEqual(settings.validated().minimumSettleAge, 86400)

        settings.minimumSettleAge = 900
        XCTAssertEqual(settings.validated().minimumSettleAge, 900)
    }

    func testValidatedClampsAutomationIntervalSeconds() throws {
        var settings = Settings()
        settings.automationIntervalSeconds = 1
        XCTAssertEqual(settings.validated().automationIntervalSeconds, 60)

        settings.automationIntervalSeconds = 999999
        XCTAssertEqual(settings.validated().automationIntervalSeconds, 86400)

        settings.automationIntervalSeconds = 300
        XCTAssertEqual(settings.validated().automationIntervalSeconds, 300)
    }

    func testValidatedDestinationSubdirectory() throws {
        var settings = Settings()
        settings.destinationSubdirectory = ""
        XCTAssertEqual(settings.validated().destinationSubdirectory, "_iPhone-BU")

        settings.destinationSubdirectory = "   "
        XCTAssertEqual(settings.validated().destinationSubdirectory, "_iPhone-BU")

        settings.destinationSubdirectory = " x "
        XCTAssertEqual(settings.validated().destinationSubdirectory, " x ")
    }

    func testSaveWritesClampedValues() throws {
        var settings = Settings()
        settings.archivesToKeep = 500
        try store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.archivesToKeep, 100)
    }

    func testUpdateAppliesClosureAndReturnsClampedResult() throws {
        var settings = Settings()
        settings.archivesToKeep = 10
        try store.save(settings)

        let updated = try store.update { $0.archivesToKeep = 200 }
        XCTAssertEqual(updated.archivesToKeep, 100)

        let loaded = store.load()
        XCTAssertEqual(loaded.archivesToKeep, 100)
    }
}