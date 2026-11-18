#if os(iOS)
import APIClient
import DesignSystem
import Foundation
import Home
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing

/// Round 13 (https://claude.ai/artifact/M81jJLKd2HUNDjZJW3angV): Said as the swipe deck (A,
/// direction 2) and its no-platform frame, Contact's official accounts (B), and posts on the member
/// screen and Following's wall (C). Real content throughout: Slotkin's and Gillibrand's 2024 sites as
/// the Internet Archive kept them, Schumer's handles and posts, the members' records as the API
/// served them on 2026-11-16.
@MainActor
@Suite("Round 13 snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct Round13SnapshotTests {
    init() { _ = NoPortraits.installed }

    /// One segment whole, on its own screen, as the member page's block links open it.
    private func member(_ id: String, _ section: MemberSection, card: Int = 0) async -> some View {
        let model = RepScreenModel(bioguideId: id, api: FixtureServer.api)
        await model.load()
        await model.promises.load()
        await model.posts.load()
        model.promiseCard = card
        return NavigationStack { MemberSectionPage(model: model, section: section, onOpenTopic: { _ in }) }
    }

    // MARK: - A · Said

    /// The mock's card: "Middle class · 2 of 3", the heading written out whole.
    @Test func saidDeck() async throws {
        assertScreen(await member("S001208", .said, card: 1), height: 760)
    }

    @Test func saidDeckFirstCard() async throws {
        assertScreen(await member("S001208", .said), height: 760, [.light])
    }

    /// Gillibrand's 2024 site listed no issues: the browser frame, nothing filled in.
    @Test func saidNoPlatform() async throws {
        assertScreen(await member("G000555", .said), height: 620, [.light, .dark])
    }

    /// Nadler's site hasn't been read (no promises route answers for him): the dashed placeholder.
    @Test func saidNotReadYet() async throws {
        assertScreen(await member("N000002", .said), height: 420, [.light])
    }

    // MARK: - B · Contact

    @Test func contactAccounts() async throws {
        assertScreen(await member("S000148", .contact), height: 760)
    }

    // MARK: - C · Posts (rebuilt in v0.2.58)

    /// All of Schumer's posts, the full list "All ›" opens: video, photo and text cards, full text.
    @Test func memberPosts() async throws {
        assertScreen(await member("S000148", .posts), height: 1600)
    }

    /// Schumer and Nadler on Following › Posts: the title, the member filters, day dividers in the
    /// reader's zone against noon Eastern on Nov 17, Nadler's link card and his threads.
    @Test func followingPostsWall() async throws {
        let schumer: MemberDetail = try fixture("member-detail-schumer-2026-11-17")
        let nadler: MemberDetail = try fixture("member-detail-nadler")
        var state = FollowState()
        state.follow(member: nadler.member, at: Date(timeIntervalSince1970: 1))
        state.follow(member: schumer.member, at: Date(timeIntervalSince1970: 2))
        let model = HomeModel(delegation: nil, follows: Follows(store: InMemoryFollowStore(state)), api: FixtureServer.api)
        await model.loadWall()
        let view = FollowingView(model: model, segment: .posts, onOpenMember: { _ in }, onFindReps: {}, onChangeAddress: {})
            .environment(\.pinnedNow, Formats.instant("2026-11-17T17:00:00.000Z"))
        assertScreen(view, height: 2200)
    }
}
#endif
