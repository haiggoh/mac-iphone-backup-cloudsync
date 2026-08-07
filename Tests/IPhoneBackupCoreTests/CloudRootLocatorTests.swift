import XCTest
@testable import IPhoneBackupCore

final class CloudRootLocatorTests: XCTestCase {

    private var home: URL!
    private var cloudStorage: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-home-\(UUID().uuidString)")
        cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        try FileManager.default.createDirectory(at: cloudStorage, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        try super.tearDownWithError()
    }

    private func locator() -> CloudRootLocator {
        CloudRootLocator(homeDirectory: home)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: Discovery

    func testFindsModernCloudStorageRoot() throws {
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-SomeCompanyGmbH"))

        guard case .resolved(let root) = locator().resolve(configuredPath: nil) else {
            return XCTFail("a single modern root must resolve without asking the user")
        }
        XCTAssertEqual(root.displayName, "OneDrive-SomeCompanyGmbH")
    }

    func testFindsLegacyHomeRoot() throws {
        try makeDirectory(home.appendingPathComponent("OneDrive"))

        guard case .resolved(let root) = locator().resolve(configuredPath: nil) else {
            return XCTFail("a bare legacy ~/OneDrive must resolve")
        }
        XCTAssertEqual(root.displayName, "OneDrive")
    }

    /// Tenant names vary per user, so matching is by prefix. Personal accounts,
    /// business accounts and the bare folder must all be found without any tenant
    /// string appearing in the source.
    func testMatchesAnyTenantNamingByPrefix() throws {
        for name in ["OneDrive", "OneDrive-Personal", "OneDrive - Any Company Name"] {
            let scratch = home.appendingPathComponent("scratch-\(UUID().uuidString)")
            try makeDirectory(scratch.appendingPathComponent("Library/CloudStorage")
                .appendingPathComponent(name))

            let found = CloudRootLocator(homeDirectory: scratch).discover()
            XCTAssertEqual(found.count, 1, "\(name) should be discovered")
            XCTAssertEqual(found.first?.displayName, name)
        }
    }

    /// THE REGRESSION TEST.
    ///
    /// macOS commonly leaves `~/OneDrive - Company` as a symlink to the
    /// CloudStorage folder — confirmed on the development machine. Counting both
    /// makes one account look ambiguous, which would make automatic mode report
    /// "configuration required" and never archive anything. Deduping by canonical
    /// path is what prevents that.
    func testLegacySymlinkToModernRootCountsAsOneRoot() throws {
        let modern = cloudStorage.appendingPathComponent("OneDrive-SomeCompanyGmbH")
        try makeDirectory(modern)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("OneDrive - Some Company GmbH"),
            withDestinationURL: modern
        )

        let roots = locator().discover()
        XCTAssertEqual(roots.count, 1, "a symlink and its target are one root, not two")

        guard case .resolved(let root) = locator().resolve(configuredPath: nil) else {
            return XCTFail("one real account must resolve, not report ambiguity")
        }
        // Discovery order prefers the modern location over the legacy alias.
        XCTAssertEqual(root.displayName, "OneDrive-SomeCompanyGmbH")
    }

    func testGenuinelyDistinctRootsAreAmbiguous() throws {
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-CompanyOne"))
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-Personal"))

        guard case .ambiguous(let roots) = locator().resolve(configuredPath: nil) else {
            return XCTFail("two separate accounts must require an explicit choice")
        }
        XCTAssertEqual(roots.count, 2)
    }

    func testNoRootFound() throws {
        guard case .none = locator().resolve(configuredPath: nil) else {
            return XCTFail("an empty home must report no root")
        }
    }

    /// Files are not destinations.
    func testIgnoresAFileNamedLikeARoot() throws {
        try Data("not a folder".utf8)
            .write(to: cloudStorage.appendingPathComponent("OneDrive-NotADirectory"))

        XCTAssertTrue(locator().discover().isEmpty)
    }

    // MARK: Configured override

    /// The layer that makes an unusual setup reachable: a custom sync location or
    /// an external volume that discovery would never guess.
    func testConfiguredPathWinsOverDiscovery() throws {
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-Discovered"))
        let custom = home.appendingPathComponent("Volumes/Elsewhere/MyArchives")
        try makeDirectory(custom)

        guard case .resolved(let root) = locator().resolve(configuredPath: custom.path) else {
            return XCTFail("an explicitly configured path must be used")
        }
        XCTAssertEqual(root.displayName, "MyArchives")
    }

    /// An unmounted volume or a removed account must stop the run, not silently
    /// fall back to writing 50 GB somewhere the user did not choose.
    func testMissingConfiguredPathDoesNotFallBackToDiscovery() throws {
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-Discovered"))

        let result = locator().resolve(
            configuredPath: home.appendingPathComponent("gone").path)
        guard case .none = result else {
            return XCTFail("a missing configured root must not fall back to discovery")
        }
    }

    func testEmptyConfiguredPathFallsBackToDiscovery() throws {
        try makeDirectory(cloudStorage.appendingPathComponent("OneDrive-Discovered"))

        guard case .resolved = locator().resolve(configuredPath: "") else {
            return XCTFail("an empty setting means unset, so discovery should run")
        }
    }
}
