import Foundation
import Testing
@testable import Onboarding
import Models

/// Serialized because `StubAPIProtocol` keeps its canned outcome in shared state.
@MainActor
@Suite("Onboarding", .serialized)
struct OnboardingModelTests {
    /// Location tests live in `OnboardingLocationTests.swift`, as an extension so they share this
    /// suite's serialization.
    func model(
        _ outcome: StubAPIProtocol.Outcome,
        store: any DelegationStore = InMemoryDelegationStore(),
        location: StubLocation = StubLocation()
    ) -> OnboardingModel {
        OnboardingModel(
            api: StubAPIProtocol.api(outcome),
            store: store,
            location: location,
            now: { Date(timeIntervalSince1970: 1_763_000_000) }
        )
    }

    @Test func resolvesAnAddressToADelegationButDoesNotSaveItYet() async throws {
        let store = InMemoryDelegationStore()
        let model = model(.json(repsJSON), store: store)
        model.address = "1100 Congress Ave, Austin, TX 78701"

        await model.lookUp()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(reps.district.name == "TX-37")
        #expect(reps.members.count == 3)
        // Nothing is stored until the person confirms it is really them.
        #expect(store.load() == nil)
    }

    @Test func savesOnlyOnceConfirmed() async throws {
        let store = InMemoryDelegationStore()
        let model = model(.json(repsJSON), store: store)
        model.address = "1100 Congress Ave, Austin, TX 78701"
        await model.lookUp()

        let saved = try #require(model.confirm())
        #expect(saved.district.district == 37)
        #expect(saved.representative?.lastName == "Doggett")
        #expect(saved.senators.map(\.lastName) == ["Cruz", "Cornyn"])
        #expect(saved.memberIds == ["D000399", "C001098", "C001056"])
        #expect(store.load() == saved)
    }

    /// The address is used for one request and dropped. It must not reach the device's storage,
    /// where a backup or a crash report could carry it off.
    @Test func neverStoresTheAddress() async throws {
        let address = "1100 Congress Ave, Austin, TX 78701"
        let store = InMemoryDelegationStore()
        let model = model(.json(repsJSON), store: store)
        model.address = address
        await model.lookUp()
        let saved = try #require(model.confirm())

        let encoded = try #require(String(data: JSONEncoder().encode(saved), encoding: .utf8))
        #expect(!encoded.contains("Congress Ave"))
        #expect(!encoded.contains("78701"))
        #expect(!encoded.localizedCaseInsensitiveContains(address))
        // What it does keep is the district and the members.
        #expect(encoded.contains("D000399"))
    }

    @Test func confirmingBeforeALookupDoesNothing() {
        let store = InMemoryDelegationStore()
        let model = model(.json(repsJSON), store: store)
        #expect(model.confirm() == nil)
        #expect(store.load() == nil)
    }

    @Test func showsTheAPIsOwnWordingWhenAnAddressIsNotFound() async {
        let model = model(.json(
            #"{"error":"We couldn't find that address. Try adding the city, state and ZIP code."}"#,
            status: 404
        ))
        model.address = "nowhere at all"
        await model.lookUp()

        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message == "We couldn't find that address. Try adding the city, state and ZIP code.")
    }

    @Test func saysSomethingUsableWhenOffline() async {
        let model = model(.failure(URLError(.notConnectedToInternet)))
        model.address = "1100 Congress Ave, Austin, TX 78701"
        await model.lookUp()

        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("connection"))
        // Never a raw error dump.
        #expect(!message.contains("NSURLError"))
    }

    @Test func treatsADistrictWithNoMembersAsOurProblem() async {
        let model = model(.json("""
        {"district":{"congress":119,"state":"TX","district":37,"countyFips":null},"members":[]}
        """))
        model.address = "1100 Congress Ave, Austin, TX 78701"
        await model.lookUp()

        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        // Not "bad address" — the address resolved fine, our member data is behind.
        #expect(message.contains("representatives"))
    }

    @Test func refusesToLookUpSomethingTooShortWithoutCallingTheAPI() async {
        let model = model(.failure(URLError(.badURL)))
        model.address = "TX"
        #expect(model.canLookUp == false)

        await model.lookUp()
        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        // Our own guidance, not a transport failure, so the API was never called.
        #expect(message.contains("street address"))
    }

    @Test func ignoresSurroundingWhitespaceWhenDecidingIfItCanLookUp() {
        let model = model(.json(repsJSON))
        model.address = "        "
        #expect(model.canLookUp == false)
        model.address = "  1100 Congress Ave  "
        #expect(model.canLookUp)
    }

    @Test func goesBackToTheFieldKeepingWhatWasTyped() async {
        let model = model(.json(repsJSON))
        model.address = "1100 Congress Ave, Austin, TX 78701"
        await model.lookUp()
        model.edit()
        #expect(model.phase == .editing)
        #expect(model.address == "1100 Congress Ave, Austin, TX 78701")
    }
}

@Suite("DelegationStore")
struct DelegationStoreTests {
    /// Its own suite so the test never touches the real app's defaults.
    private func defaults() throws -> UserDefaults {
        let name = "floor.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let store = UserDefaultsDelegationStore(defaults: try defaults())
        #expect(store.load() == nil)
        store.save(.sample)
        #expect(store.load() == Delegation.sample)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func treatsAnUnreadableRecordAsNotOnboarded() throws {
        // A record written by an older version may no longer decode. The app must offer onboarding
        // again rather than failing to launch.
        let defaults = try defaults()
        defaults.set(Data("not a delegation".utf8), forKey: UserDefaultsDelegationStore.key)
        #expect(UserDefaultsDelegationStore(defaults: defaults).load() == nil)
    }

    // MARK: - Moving to the App Group, for the widget

    @Test func copiesALegacyDelegationIntoTheGroupOnce() throws {
        let (legacy, group) = (try defaults(), try defaults())
        UserDefaultsDelegationStore(defaults: legacy).save(.sample)

        let store = UserDefaultsDelegationStore.shared(legacy: legacy, group: group)
        #expect(store.movedFromLegacy)
        #expect(store.load() == Delegation.sample)
        #expect(UserDefaultsDelegationStore(defaults: group).load() == Delegation.sample)
        // Kept, so a group that turns out not to work loses nothing.
        #expect(legacy.data(forKey: UserDefaultsDelegationStore.key) != nil)

        // A second launch finds the group already filled: nothing moves, nothing to reload.
        let again = UserDefaultsDelegationStore.shared(legacy: legacy, group: group)
        #expect(!again.movedFromLegacy)
        #expect(again.load() == Delegation.sample)
    }

    @Test func aDelegationAlreadyInTheGroupWins() throws {
        let (legacy, group) = (try defaults(), try defaults())
        var older = Delegation.sample
        older.district = District(congress: 119, state: "WY", district: 0, countyFips: nil)
        UserDefaultsDelegationStore(defaults: legacy).save(older)
        UserDefaultsDelegationStore(defaults: group).save(.sample)

        let store = UserDefaultsDelegationStore.shared(legacy: legacy, group: group)
        #expect(!store.movedFromLegacy)
        #expect(store.load() == Delegation.sample)
    }

    /// "Change address" clears the store. The district from before the move must not reappear on
    /// the next launch — on the phone, or on the widget, which would show where you used to live.
    @Test func clearingRemovesTheRecordFromBothPlaces() throws {
        let (legacy, group) = (try defaults(), try defaults())
        UserDefaultsDelegationStore(defaults: legacy).save(.sample)

        UserDefaultsDelegationStore.shared(legacy: legacy, group: group).clear()
        #expect(legacy.data(forKey: UserDefaultsDelegationStore.key) == nil)
        #expect(group.data(forKey: UserDefaultsDelegationStore.key) == nil)
        #expect(UserDefaultsDelegationStore.shared(legacy: legacy, group: group).load() == nil)
    }

    /// A new district makes the legacy copy stale; it must not come back if the group is ever empty.
    @Test func savingANewDelegationDropsTheLegacyCopy() throws {
        let (legacy, group) = (try defaults(), try defaults())
        UserDefaultsDelegationStore(defaults: legacy).save(.sample)
        var moved = Delegation.sample
        moved.district = District(congress: 119, state: "WY", district: 0, countyFips: nil)

        UserDefaultsDelegationStore.shared(legacy: legacy, group: group).save(moved)
        #expect(legacy.data(forKey: UserDefaultsDelegationStore.key) == nil)
        #expect(UserDefaultsDelegationStore(defaults: group).load() == moved)
    }

    @Test func nothingSavedMeansNothingMoved() throws {
        let (legacy, group) = (try defaults(), try defaults())
        let store = UserDefaultsDelegationStore.shared(legacy: legacy, group: group)
        #expect(!store.movedFromLegacy)
        #expect(store.load() == nil)
        #expect(group.data(forKey: UserDefaultsDelegationStore.key) == nil)
    }

    @Test func withoutTheGroupTheAppKeepsItsOwnCopy() throws {
        let legacy = try defaults()
        UserDefaultsDelegationStore(defaults: legacy).save(.sample)
        let store = UserDefaultsDelegationStore.shared(legacy: legacy, group: nil)
        #expect(store.load() == Delegation.sample)
        #expect(!store.movedFromLegacy)
    }

    @Test func theGroupComesFromTheInfoPlistWithAFallback() {
        // `swift test` has no FloorAppGroup key, so the fallback is used.
        #expect(UserDefaultsDelegationStore.appGroup(in: Bundle(for: BundleMarker.self)) == "group.app.floor.ios")
        #expect(UserDefaultsDelegationStore.defaultAppGroup == "group.app.floor.ios")
    }

    /// Both targets take the group from one build setting, `group.$(FLOOR_BUNDLE_ID)`, so a
    /// personal build with its own bundle id can't end up registering ours, and the app and widget
    /// can't disagree.
    @Test func bothTargetsTakeTheGroupFromOneSetting() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() } // OnboardingTests, Tests, FloorKit, ios
        let spec = try String(contentsOf: dir.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(spec.contains("FLOOR_BUNDLE_ID: app.floor.ios"))
        #expect(spec.contains("FLOOR_APP_GROUP: group.$(FLOOR_BUNDLE_ID)"))
        #expect(spec.components(separatedBy: "com.apple.security.application-groups: [$(FLOOR_APP_GROUP)]").count - 1 == 2)
        #expect(spec.components(separatedBy: "FloorAppGroup: $(FLOOR_APP_GROUP)").count - 1 == 2)
        #expect(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: $(FLOOR_BUNDLE_ID)\n"))
        #expect(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: $(FLOOR_BUNDLE_ID).widgets"))
        // No literal group id left for a personal build to inherit.
        #expect(!spec.contains("group.app.floor.ios"))
    }
}

private final class BundleMarker {}
