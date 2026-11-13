#if os(iOS)
import APIClient
import BillScreen
import DesignSystem
import Home
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing
import VoteScreen

/// The screens, loaded from the captured responses through `FixtureServer`.
@MainActor
@Suite("Screen snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct ScreenSnapshotTests {
    init() { _ = NoPortraits.installed }

    private var delegation: Delegation {
        get throws { Delegation(reps: try austin(), resolvedAt: Date(timeIntervalSince1970: 0)) }
    }

    // MARK: - Vote

    private func voteScreen(_ id: String) async throws -> some View {
        let delegation = try delegation
        let model = VoteScreenModel(voteId: id, memberIds: delegation.memberIds, api: FixtureServer.api, delegation: delegation.members)
        await model.load()
        return NavigationStack { VoteScreenView(model: model) }
    }

    /// A question with your rep's position, the bill's level and the full roll.
    @Test func voteWithYourRep() async throws {
        assertScreen(try await voteScreen("house-119-1-100"), height: 1400, [.light, .dark])
    }

    /// The same at AX5, tall enough to reach your members' rows, which stack at this size.
    @Test func voteWithYourRepLargestText() async throws {
        assertScreen(try await voteScreen("house-119-1-100"), height: 4000, [.largestText])
    }

    /// Short of the line: cloture at 53 of 60, both senators yea.
    @Test func voteShortOfTheLine() async throws {
        assertScreen(try await voteScreen("senate-119-2-253"), height: 2000, [.light])
    }

    /// The Speaker election's own board, and a ballot that elected nobody.
    @Test func voteSpeakerElection() async throws {
        assertScreen(try await voteScreen("house-118-1-10"), height: 1400, [.light, .dark])
    }

    // MARK: - Bill

    private func billScreen(_ id: String) async throws -> some View {
        let model = BillScreenModel(billId: id, api: FixtureServer.api, members: try delegation.members)
        await model.load()
        return NavigationStack { BillScreenView(model: model, onOpenVote: { _ in }) }
    }

    /// The stepper's three shapes: all the way to law, rejected at a chamber, still moving.
    @Test func billEnacted() async throws {
        assertScreen(try await billScreen("118-hr-3746"), height: 1400, [.light, .dark])
    }

    @Test func billRejectedInTheHouse() async throws {
        assertScreen(try await billScreen("118-hconres-21"), height: 1400, [.light])
    }

    @Test func billStillMoving() async throws {
        assertScreen(try await billScreen("119-hr-9340"), height: 1400, [.light])
    }

    // MARK: - Rep

    /// Cruz: a party-unity figure, crossovers and his recent votes.
    @Test func repWithUnity() async throws {
        let model = RepScreenModel(bioguideId: "C001098", api: FixtureServer.api)
        await model.load()
        assertScreen(NavigationStack { RepScreenView(model: model) }, height: 1400, [.light, .dark])
    }

    // MARK: - Onboarding

    private func onboarding(_ api: FloorAPI, address: String? = nil) async -> some View {
        let model = OnboardingModel(api: api, store: InMemoryDelegationStore(), location: NoLocation())
        if let address {
            model.address = address
            await model.lookUp()
        }
        return OnboardingView(model: model, onFinished: { _ in })
    }

    @Test func onboardingEditing() async throws {
        assertScreen(await onboarding(FixtureServer.api), [.light, .dark])
    }

    /// Austin's three, dealt as cards — three across, or one per row at accessibility sizes.
    @Test func onboardingFound() async throws {
        assertScreen(await onboarding(FixtureServer.api, address: "1100 Congress Ave, Austin, TX"), height: 1200)
    }

    @Test func onboardingFailed() async throws {
        assertScreen(await onboarding(FixtureServer.api(OfflineServer.self), address: "1100 Congress Ave, Austin, TX"), [.light])
    }

    // MARK: - Home

    private func home(_ api: FloorAPI, load: Bool = true) async throws -> some View {
        let model = HomeModel(delegation: try delegation, api: api)
        if load { await model.load() }
        return HomeView(model: model, onChangeAddress: {}, onOpenMember: { _ in }, onOpen: { _ in })
            // The split-flap board scrambles as it appears; drawn settled, as Reduce Motion draws it.
            .environment(\.playsArrivalAnimations, false)
    }

    @Test func homeLoaded() async throws {
        assertScreen(try await home(FixtureServer.api), height: 1600)
    }

    @Test func homeLoading() async throws {
        assertScreen(try await home(FixtureServer.api, load: false), [.light])
    }

    @Test func homeFailed() async throws {
        assertScreen(try await home(FixtureServer.api(OfflineServer.self)), [.light])
    }
}

/// Location that is never asked for: these screens are about the address path.
@MainActor
private final class NoLocation: LocationProvider {
    func requestAuthorization() async -> LocationAuthorization { .denied }
    func currentLocation() async throws -> Coordinate { throw LocationFailure.unavailable }
}
#endif
