// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktimeDomain",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WorktimeDomain", targets: ["WorktimeDomain"])],
    targets: [
        .target(name: "WorktimeDomain"),
        .testTarget(name: "WorktimeDomainTests", dependencies: ["WorktimeDomain"])
    ]
)
