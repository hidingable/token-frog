// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenVoyage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "voyage-content", targets: ["VoyageContent"]),
    ],
    targets: [
        .target(name: "VoyageCore"),
        .executableTarget(name: "VoyageContent", dependencies: ["VoyageCore"]),
        .executableTarget(name: "TokenVoyage", dependencies: ["VoyageCore"], resources: [.process("Resources")]),
        .testTarget(name: "VoyageCoreTests", dependencies: ["VoyageCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TokenVoyageTests", dependencies: ["TokenVoyage"], exclude: ["Fixtures"]),
    ]
)
