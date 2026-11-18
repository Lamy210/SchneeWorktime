// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktimeDomain",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorktimeDomain", targets: ["WorktimeDomain"]),
        .library(name: "WorktimeStore", targets: ["WorktimeStore"]),
        .executable(name: "SchneeWorktime", targets: ["SchneeWorktime"])
    ],
    targets: [
        .target(name: "WorktimeDomain"),
        .testTarget(name: "WorktimeDomainTests", dependencies: ["WorktimeDomain"]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "WorktimeStore", dependencies: ["CSQLite", "WorktimeDomain"]),
        .testTarget(name: "WorktimeStoreTests", dependencies: ["WorktimeStore", "WorktimeDomain", "CSQLite"]),
        .target(name: "WorktimeApplication", dependencies: ["WorktimeStore", "WorktimeDomain"]),
        .testTarget(
            name: "WorktimeApplicationTests", dependencies: ["WorktimeApplication", "WorktimeStore", "WorktimeDomain"]
        ),
        .executableTarget(name: "SchneeWorktime", dependencies: ["WorktimeApplication", "WorktimeDomain"])
    ]
)
