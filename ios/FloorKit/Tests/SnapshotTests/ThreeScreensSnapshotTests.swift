#if os(iOS)
import APIClient
import DesignSystem
import Foundation
@testable import Home
import Models
import Onboarding
import SwiftUI
import Testing

/// v0.2.59, the locked "Your picks" of <https://claude.ai/artifact/T7fxxQyFCYdPaJnewnNpT2>: Catch up
/// as a swipe deck, Week as headliners, Bills as a topic ledger of progress cards. Drawn from the
/// 2026-11-17 captures: `/v1/votes` (each bill's stage from `/v1/bills/{id}` that day), the week of
/// Nov 16 as `/v1/schedule` served it, and the records of Gillibrand, Schumer and Blackburn.
@MainActor
@Suite("Catch up, Week and Bills snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct ThreeScreensSnapshotTests {
    init() { _ = NoPortraits.installed }

    /// Tuesday 2026-11-17, 4 p.m. in Washington.
    static let now = Date(timeIntervalSince1970: 1_794_949_200)

    /// New York's NY-12 (Nadler, Gillibrand, Schumer) and Blackburn, followed.
    static let delegation = Delegation(
        district: District(congress: 119, state: "NY", district: 12, countyFips: nil),
        members: [
            Member(bioguideId: "N000002", firstName: "Jerrold", lastName: "Nadler", party: "D", state: "NY", district: 12, chamber: .house),
            Member(bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: nil, chamber: .senate),
            Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D", state: "NY", district: nil, chamber: .senate),
        ],
        resolvedAt: Date(timeIntervalSince1970: 0)
    )

    static let blackburn = Member(bioguideId: "B001243", firstName: "Marsha", lastName: "Blackburn", party: "R", state: "TN", district: nil, chamber: .senate)

    private func home(delegation: Delegation?) async -> HomeModel {
        var state = FollowState()
        if delegation != nil { state.follow(member: Self.blackburn) }
        let model = HomeModel(delegation: delegation, follows: Follows(store: InMemoryFollowStore(state)), api: FixtureServer.api(ThreeServer.self))
        model.scope = .all
        await model.load()
        return model
    }

    /// The Ratepayer card on top: 57–43 and still blocked, 60 needed, R 53–0, D 4–41, I 0–2;
    /// Gillibrand and Schumer nay, Blackburn yea; two ghost cards under it.
    @Test func catchUpRatepayer() async throws {
        let model = await home(delegation: Self.delegation)
        #expect(model.deck.first?.measure?.title == "Ratepayer Protection Act")
        let view = CatchUpDeckView(model: model, onOpenVote: { _ in })
            .environment(\.playsArrivalAnimations, false)
        assertScreen(view, height: 1000)
    }

    private func week(votes: [FeedItem]) async -> (WeekModel, [FeedItem]) {
        let model = WeekModel(api: FixtureServer.api(ThreeServer.self), follows: Follows(store: InMemoryFollowStore()), now: { Self.now })
        await model.load()
        return (model, votes)
    }

    /// The week of Nov 16: H.R. 2347 riding the Affordability and Jobs Act, the two rule bills under
    /// H.Res. 1665, Tuesday's Senate meeting, thirteen fast-track bills in five families, H.Res. 1665 listed.
    @Test func weekHeadliners() async throws {
        let home = await home(delegation: nil)
        let (model, votes) = await week(votes: home.loadedVotes)
        assertScreen(WeekView(model: model, votes: votes, onOpenBill: { _ in }), height: 2000)
    }

    /// A fast-track tile's rows: Rights, four bills.
    @Test func weekFastTrackRights() async throws {
        let (model, _) = await week(votes: [])
        assertScreen(FastTrackView(model: model, group: .rights, onOpenBill: { _ in }), height: 700, [.light, .dark])
    }

    /// Every bill in the latest finals as a progress card, in topic sections: H.R. 2102 with its rule
    /// folded in, H.R. 1013 with its two, then the rest.
    @Test func billsLedger() async throws {
        assertScreen(BillsView(model: await home(delegation: nil), onOpenBill: { _ in }), height: 2400)
    }
}

/// The routes these screens ask for, answered from the 2026-11-17 captures; anything else is a 404.
final class ThreeServer: URLProtocol {
    static let routes: [String: String] = [
        "/v1/votes": "votes-recent-40-2026-11-17",
        "/v1/schedule": "schedule-2026-11-16-at-2026-11-17",
        "/v1/members/G000555/votes": "member-votes-gillibrand-40",
        "/v1/members/S000148/votes": "member-votes-schumer-40-2026-11-17",
        "/v1/members/N000002/votes": "member-votes-nadler-2026-11-17",
        "/v1/members/B001243/votes": "member-votes-blackburn-40-2026-11-17",
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let name = Self.routes[url.path]
        let body = (try? name.map { try fixtureData($0) }) ?? nil
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
