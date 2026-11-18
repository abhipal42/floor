#if os(iOS)
import APIClient
import DesignSystem
import Foundation
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing

/// v0.2.58, Arena everywhere (https://claude.ai/artifact/HP3nZFoQ4jUppnjKsC1MfV, direction 1) and
/// the one-scroll member page (https://claude.ai/artifact/Jaqz5c8EGoCQd8Wb8ELBns, option B). Real
/// data throughout: Schumer's record, money, 2022 promises and posts as the API served them on
/// 2026-11-17, and El-Sayed as a member-elect. Light mode is Arena's structure on the Marble
/// palette, which the mock did not draw.
@MainActor
@Suite("Arena snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct ArenaSnapshotTests {
    init() { _ = NoPortraits.installed }

    /// A senator with everything: the hero, the chips, three votes, the promise rail, two posts,
    /// money and contact. He is one of your senators, so the eyebrow says so and there is no Follow.
    @Test func memberPage() async throws {
        let model = RepScreenModel(bioguideId: "S000148", api: FixtureServer.api)
        await model.load()
        await model.promises.load()
        await model.posts.load()
        await model.money.load()
        let view = NavigationStack {
            RepScreenView(model: model, follows: Follows(store: InMemoryFollowStore()), reps: ["S000148"])
        }
        .environment(\.pinnedNow, Formats.instant("2026-11-17T17:00:00.000Z"))
        assertScreen(view, height: 3000)
    }

    /// Someone you follow and who isn't your rep: Follow on the hero, the eyebrow says FOLLOWING.
    @Test func memberPageFollowing() async throws {
        let model = RepScreenModel(bioguideId: "S000148", api: FixtureServer.api)
        await model.load()
        await model.promises.load()
        await model.posts.load()
        await model.money.load()
        let detail: MemberDetail = try fixture("member-detail-schumer-2026-11-17")
        var state = FollowState()
        state.follow(member: detail.member, at: Date(timeIntervalSince1970: 1))
        let view = NavigationStack {
            RepScreenView(model: model, follows: Follows(store: InMemoryFollowStore(state)))
        }
        assertScreen(view, height: 700, [.light])
    }

    /// A member-elect: the same hero, no stats or streak, then Money and Contact.
    @Test func memberElectPage() async throws {
        let model = ElectScreenModel(id: "elect-2026-mi-sen", api: FixtureServer.api)
        await model.load()
        assertScreen(NavigationStack { ElectScreenView(model: model) }, height: 1100)
    }
}
#endif
