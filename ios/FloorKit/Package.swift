// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloorKit",
    platforms: [.iOS("17.2"), .macOS(.v14)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "APIClient", targets: ["APIClient"]),
        .library(name: "Onboarding", targets: ["Onboarding"]),
        .library(name: "VoteScreen", targets: ["VoteScreen"]),
        .library(name: "BillScreen", targets: ["BillScreen"]),
        .library(name: "Home", targets: ["Home"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "APIClient", dependencies: ["Models"]),
        .target(name: "DesignSystem", dependencies: ["Models"]),
        .target(name: "Onboarding", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .target(name: "VoteScreen", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .target(name: "BillScreen", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .target(
            name: "Home",
            dependencies: ["Models", "APIClient", "DesignSystem", "Onboarding", "VoteScreen", "BillScreen"]
        ),
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
        .testTarget(name: "HomeTests", dependencies: ["Home"]),
        // Reads ModelsTests' captured responses from the source tree, as APIClientTests does.
        .testTarget(name: "VoteScreenTests", dependencies: ["VoteScreen"]),
        .testTarget(name: "BillScreenTests", dependencies: ["BillScreen"]),
    ]
)
