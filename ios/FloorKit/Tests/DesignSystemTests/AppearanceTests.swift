import SwiftUI
import Testing
@testable import DesignSystem

@Suite("Appearance setting")
struct AppearanceTests {
    /// The raw values are what `UserDefaults` holds, so renaming one would reset everyone's choice.
    @Test func storedValuesAreStable() {
        #expect(Appearance.storageKey == "appearance")
        #expect(Appearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    }

    @Test func missingOrUnknownStoredValueFollowsTheSystem() {
        #expect(Appearance(stored: nil) == .system)
        #expect(Appearance(stored: "") == .system)
        #expect(Appearance(stored: "sepia") == .system)
        #expect(Appearance(stored: "dark") == .dark)
        #expect(Appearance(stored: "light") == .light)
    }

    @Test func eachChoiceMapsToItsColorScheme() {
        #expect(Appearance.system.colorScheme == nil)
        #expect(Appearance.light.colorScheme == .light)
        #expect(Appearance.dark.colorScheme == .dark)
    }

    @Test func everyChoiceHasALabelAndSymbol() {
        #expect(Appearance.allCases.map(\.label) == ["System", "Light", "Dark"])
        #expect(Set(Appearance.allCases.map(\.symbol)).count == 3)
    }
}
