#if os(iOS)
import APIClient
import DesignSystem
import Home
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing

/// Round 12, members-elect (https://claude.ai/artifact/Hod9RDLS1DgxapLeBcA3QY): where they show up
/// (A) and the profile (B). Abdul El-Sayed's race, call and FEC totals are real; the undecided seats
/// in `searchPendingSeatSample` are the mock's layout SAMPLE, not a real race.
@MainActor
@Suite("Round 12 snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct Round12SnapshotTests {
    init() { _ = NoPortraits.installed }

    // MARK: - A · Where they show up

    /// A Michigan address (MI-12): Peters leaving, El-Sayed under him. Tlaib (T000481) and Slotkin
    /// (S001208) were checked against Floor's members table. Drawn before the feed loads, so the
    /// strip is what is checked.
    @Test func homeYourThreeChangingHands() async throws {
        let delegation = Delegation(
            district: District(congress: 119, state: "MI", district: 12, countyFips: nil),
            members: [
                Member(bioguideId: "T000481", firstName: "Rashida", lastName: "Tlaib", party: "D", state: "MI", district: 12, chamber: .house),
                Member(bioguideId: "S001208", firstName: "Elissa", lastName: "Slotkin", party: "D", state: "MI", district: nil, chamber: .senate),
                Member(bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D", state: "MI", district: nil, chamber: .senate),
            ],
            resolvedAt: Date(timeIntervalSince1970: 0)
        )
        let model = HomeModel(delegation: delegation, api: FixtureServer.api)
        await model.loadSeats()
        let view = HomeView(model: model, onChangeAddress: {}, onOpenMember: { _ in }, onOpen: { _ in })
            .environment(\.playsArrivalAnimations, false)
            .environment(\.pinnedNow, Date(timeIntervalSince1970: 1_794_700_000))
        assertScreen(view, height: 560)
    }

    private func search(_ query: String, chamber: Chamber) async -> some View {
        let model = FollowSearchModel(api: FixtureServer.api, debounce: .seconds(60))
        model.query = query
        model.chamber = chamber
        await model.searchNow()
        return AddFollowsView(model: model, follows: Follows(store: InMemoryFollowStore()), reps: [],
                              onOpenBill: { _ in }, onOpenTopic: { _ in })
    }

    /// "Michigan", Senate: Slotkin, Peters leaving, El-Sayed under him.
    @Test func searchStateWithElect() async throws {
        assertScreen(await search("michigan", chamber: .senate), height: 560)
    }

    /// A runoff and an uncalled seat: no name in either (layout sample).
    @Test func searchPendingSeatSample() async throws {
        assertScreen(await search("pending sample", chamber: .house), height: 480, [.light, .dark])
    }

    // MARK: - B · The profile

    // The profile itself is the member page's one scroll since v0.2.58: `ArenaSnapshotTests.memberElectPage`.

    /// Unknown, or past taking office: the API's 404.
    @Test func electNoLongerListed() async throws {
        let model = ElectScreenModel(id: "elect-2026-xx-sen", api: FixtureServer.api)
        await model.load()
        assertScreen(NavigationStack { ElectScreenView(model: model) }, height: 360, [.light])
    }
}
#endif
