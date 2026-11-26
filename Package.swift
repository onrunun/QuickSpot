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
    dependencies: [
        .package(url: "https://github.com/maralski/gemma-embed-swift.git", exact: "0.4.1")
    ],
    targets: [
        .target(
            name: "QuickSpotCore",
            dependencies: [
                .product(name: "GemmaEmbed", package: "gemma-embed-swift")
            ],
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
