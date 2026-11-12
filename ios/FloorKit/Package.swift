// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloorKit",
    platforms: [.iOS("17.2"), .macOS(.v14)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "APIClient", targets: ["APIClient"]),
        .library(name: "Onboarding", targets: ["Onboarding"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "APIClient", dependencies: ["Models"]),
        .target(name: "DesignSystem", dependencies: ["Models"]),
        .target(name: "Onboarding", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models"],
            // Real API responses captured from staging; see ModelsTests/Fixtures.
            resources: [.copy("Fixtures")]
        ),
        // Reads the same fixtures from the source tree rather than copying them into a second
        // bundle, so there is one set of captured responses to keep current.
        .testTarget(name: "APIClientTests", dependencies: ["APIClient"]),
        .testTarget(name: "OnboardingTests", dependencies: ["Onboarding"]),
    ]
)
