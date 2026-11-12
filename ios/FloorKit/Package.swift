// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloorKit",
    platforms: [.iOS("17.2"), .macOS(.v14)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "DesignSystem", dependencies: ["Models"]),
        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models"],
            // Real API responses captured from staging; see ModelsTests/Fixtures.
            resources: [.copy("Fixtures")]
        ),
    ]
)
