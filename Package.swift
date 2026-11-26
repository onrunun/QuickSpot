// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickSpot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickSpotCore", targets: ["QuickSpotCore"]),
        .executable(name: "QuickSpotApp", targets: ["QuickSpotApp"])
    ],
    targets: [
        .target(
            name: "QuickSpotCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "QuickSpotApp",
            dependencies: ["QuickSpotCore"]
        ),
        .testTarget(
            name: "QuickSpotCoreTests",
            dependencies: ["QuickSpotCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
