// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenVoyage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VoyageCore"),
        .executableTarget(name: "TokenVoyage", dependencies: ["VoyageCore"]),
        .testTarget(name: "VoyageCoreTests", dependencies: ["VoyageCore"], resources: [.copy("Fixtures")]),
    ]
)
