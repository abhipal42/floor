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
        .library(name: "RepScreen", targets: ["RepScreen"]),
        .library(name: "Home", targets: ["Home"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "WidgetFeed", targets: ["WidgetFeed"]),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "APIClient", dependencies: ["Models"]),
        // Barlow Condensed (SIL Open Font License, Fonts/OFL.txt), registered at runtime by
        // `FloorFonts.register()` so the package's previews and the app both find it.
        .target(name: "DesignSystem", dependencies: ["Models"], resources: [.copy("Fonts")]),
        .target(name: "Onboarding", dependencies: ["Models", "APIClient", "DesignSystem"]),
        // BillScreen for `LawLevels`: the vote screen's bill card says which of six levels it reached.
        .target(name: "VoteScreen", dependencies: ["Models", "APIClient", "DesignSystem", "BillScreen"]),
        .target(name: "BillScreen", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .target(name: "RepScreen", dependencies: ["Models", "APIClient", "DesignSystem"]),
        .target(
            name: "Home",
            dependencies: [
                "Models", "APIClient", "DesignSystem", "Onboarding", "VoteScreen", "BillScreen",
                "RepScreen",
            ]
        ),
        // What the home-screen widgets show, and how they fetch it. No views: those live in the
        // widget extension (`ios/FloorWidgets`), so this stays testable on macOS.
        .target(name: "WidgetFeed", dependencies: ["Models", "APIClient", "Onboarding"]),
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
        .testTarget(name: "RepScreenTests", dependencies: ["RepScreen"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        // Reads ModelsTests' captured responses from the source tree, as APIClientTests does.
        .testTarget(name: "WidgetFeedTests", dependencies: ["WidgetFeed"]),
    ]
)
