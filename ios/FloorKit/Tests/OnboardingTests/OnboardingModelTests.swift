import Foundation
import Testing
@testable import Onboarding
import Models

/// Serialized because `StubAPIProtocol` keeps its canned outcome in shared state.
@MainActor
@Suite("Onboarding", .serialized)
struct OnboardingModelTests {
    private func model(_ outcome: StubAPIProtocol.Outcome, store: any DelegationStore = InMemoryDelegationStore())
        -> OnboardingModel {
        OnboardingModel(
            api: StubAPIProtocol.api(outcome),
            store: store,
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
}
