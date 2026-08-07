// swift-tools-version: 5.9
import PackageDescription

// The app is deliberately split in two. IPhoneBackupCore holds everything that
// decides *whether* and *what* to archive and never imports SwiftUI, so it can
// be exercised by `swift test` against temporary fixtures instead of a real
// 50 GB backup. iPhoneBackupApp is the thin AppKit/SwiftUI shell.
//
// Core deliberately returns structured values (enums, Results) rather than
// user-facing strings: the UI owns localization, so tests can assert on outcomes
// that do not shift when wording or language changes.
//
// build.sh assembles the .app bundle around the executable this produces, so the
// distribution artifact is unchanged from the pre-package layout.
let package = Package(
    name: "iPhoneBackupCloudSync",
    // 13.0 matches Info.plist's LSMinimumSystemVersion and the previous
    // swiftc -target. Keep the three in sync or the app will claim support it
    // does not have.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IPhoneBackupCore", targets: ["IPhoneBackupCore"]),
        .executable(name: "iPhoneBackup", targets: ["iPhoneBackupApp"]),
    ],
    targets: [
        .target(name: "IPhoneBackupCore"),
        .executableTarget(
            name: "iPhoneBackupApp",
            dependencies: ["IPhoneBackupCore"]
        ),
        .testTarget(
            name: "IPhoneBackupCoreTests",
            dependencies: ["IPhoneBackupCore"]
        ),
    ]
)
