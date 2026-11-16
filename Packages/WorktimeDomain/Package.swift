// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktimeDomain",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorktimeDomain", targets: ["WorktimeDomain"]),
        .library(name: "WorktimeStore", targets: ["WorktimeStore"])
    ],
    targets: [
        .target(name: "WorktimeDomain"),
        .testTarget(name: "WorktimeDomainTests", dependencies: ["WorktimeDomain"]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "WorktimeStore", dependencies: ["CSQLite", "WorktimeDomain"]),
        .testTarget(name: "WorktimeStoreTests", dependencies: ["WorktimeStore", "WorktimeDomain"])
    ]
)
