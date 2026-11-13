import Foundation
import Testing

/// The app's and the widget's `PrivacyInfo.xcprivacy`, read from the source tree.
///
/// Here because this target already reads files outside the package (the OpenAPI contract), and
/// because the client is where the app manifest's two collected data types leave the phone.
@Suite("Privacy manifests")
struct PrivacyManifestTests {
    /// - Parameter bundle: `Floor` or `FloorWidgets`, the folder under `ios/`.
    private func manifest(_ bundle: String) throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // file, APIClientTests, Tests, FloorKit
        url.appendPathComponent("\(bundle)/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func reasons(_ bundle: String) throws -> [String: [String]] {
        let types = try #require(try manifest(bundle)["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: types.compactMap { entry in
            (entry["NSPrivacyAccessedAPIType"] as? String).map { ($0, entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []) }
        })
    }

    @Test(arguments: ["Floor", "FloorWidgets"])
    func declaresNoTracking(bundle: String) throws {
        let plist = try manifest(bundle)
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
    }

    /// The app keeps its own defaults (appearance) and writes the App Group suite the widget reads.
    @Test func theAppGivesBothUserDefaultsReasonsAndNoOtherAPI() throws {
        #expect(try reasons("Floor") == ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"]])
    }

    @Test func theWidgetUsesOnlyTheAppGroup() throws {
        #expect(try reasons("FloorWidgets") == ["NSPrivacyAccessedAPICategoryUserDefaults": ["1C8F.1"]])
    }

    /// The app sends the lookup inputs once, then member ids (which reveal the district) on every
    /// request; the widget sends only the member ids.
    @Test(arguments: [
        ("Floor", Set([
            "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypePhysicalAddress",
            "NSPrivacyCollectedDataTypeCoarseLocation",
        ])),
        ("FloorWidgets", Set(["NSPrivacyCollectedDataTypeCoarseLocation"])),
    ])
    func collectsOnlyLocationUnlinkedForAppFunctionality(bundle: String, types: Set<String>) throws {
        let collected = try #require(manifest(bundle)["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.count == types.count)
        #expect(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == types)
        for entry in collected {
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}
