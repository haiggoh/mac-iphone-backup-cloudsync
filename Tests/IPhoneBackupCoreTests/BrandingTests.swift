import XCTest
@testable import IPhoneBackupCore

final class BrandingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAutomationLogLinesLeadWithTheMark() throws {
        // The CLI/log banner is a credit moment: the automatic run just happened.
        let main = repoRoot.appendingPathComponent("Sources/iPhoneBackupApp/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        XCTAssertTrue(text.contains("📱 automatic run finished:"), "finished log line carries 📱")
        XCTAssertTrue(text.contains("📱 automatic run failed:"), "failed log line carries 📱")
    }

    func testReadmeH1Exact() throws {
        let readme = repoRoot.appendingPathComponent("README.md")
        let first = try String(contentsOf: readme, encoding: .utf8).split(separator: "\n").first
        XCTAssertEqual(first, "# 📱 iPhone Backup → Cloud")
    }
}
