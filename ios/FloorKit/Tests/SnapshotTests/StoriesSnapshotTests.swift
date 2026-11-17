#if os(iOS)
import APIClient
import DesignSystem
import Foundation
@testable import Home
import Models
import Onboarding
import SwiftUI
import Testing

/// The Finals feed as stories (v0.2.57, the locked option B styled "Arena"), on New York's NY-12
/// delegation — Nadler, Schumer, Gillibrand — and the week of Nov 9–17, 2026 as the API served it
/// (this branch's API reading production on 2026-11-17): H.R. 2102 with its discharge and rule,
/// Domenico, Cook and St. John with their clotures, the unnamed 70–27 cloture.
@MainActor
@Suite("Stories snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct StoriesSnapshotTests {
    init() { _ = NoPortraits.installed }

    /// 2026-11-17, 4 p.m. in Washington: "This week" is Nov 15–21.
    static let now = Date(timeIntervalSince1970: 1_794_949_200)

    static let delegation = Delegation(
        district: District(congress: 119, state: "NY", district: 12, countyFips: nil),
        members: [
            Member(bioguideId: "N000002", firstName: "Jerrold", lastName: "Nadler", party: "D", state: "NY", district: 12, chamber: .house),
            Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D", state: "NY", district: nil, chamber: .senate),
            Member(bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: nil, chamber: .senate),
        ],
        resolvedAt: Date(timeIntervalSince1970: 0)
    )

    private func model() async -> HomeModel {
        let model = HomeModel(delegation: Self.delegation, api: FixtureServer.api(StoriesServer.self))
        model.scope = .all
        await model.load()
        return model
    }

    private func home(_ model: HomeModel) -> some View {
        HomeView(model: model, onChangeAddress: {}, onOpenMember: { _ in }, onOpen: { _ in })
            .environment(\.playsArrivalAnimations, false)
            .environment(\.pinnedNow, Self.now)
    }

    @Test func homeStories() async throws {
        assertScreen(home(await model()), height: 3200)
    }

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func story(_ id: String) async throws -> Story {
        let weeks = Stories.group((await model()).visibleItems, now: Self.now, calendar: calendar())
        return try #require(weeks.flatMap { $0.stories + $0.minis }.first { $0.id == id })
    }

    /// H.R. 2102: CRS's lead, three steps, the party split, Nadler yea on all three.
    @Test func storyCardBill() async throws {
        let story = try await story("119-hr-2102")
        assertCard(StoryCard(story: story, members: Stories.members(story), calendar: calendar(), onOpen: { _ in }))
    }

    /// Domenico: a nomination, cloture then confirmation, both senators.
    @Test func storyCardNomination() async throws {
        let story = try await story("119-pn-999-2")
        assertCard(StoryCard(story: story, members: Stories.members(story), calendar: calendar(), onOpen: { _ in }))
    }

    /// The unnamed 70–27 cloture and H.R. 2347's motion to take it up.
    @Test func miniRows() async throws {
        let unnamed = try await story("vote:senate-119-2-264")
        let proceed = try await story("119-hr-2347")
        assertCard(VStack(spacing: 8) {
            MiniStoryRow(story: unnamed, calendar: calendar())
            MiniStoryRow(story: proceed, calendar: calendar())
        })
    }
}

/// The routes the NY-12 feed asks for, answered from the 2026-11-17 captures; anything else is a 404.
final class StoriesServer: URLProtocol {
    static let routes: [String: String] = [
        "/v1/votes": "votes-recent-2026-11-17",
        "/v1/members/N000002/votes": "member-votes-nadler-2026-11-17",
        "/v1/members/S000148/votes": "member-votes-schumer-2026-11-17",
        "/v1/members/G000555/votes": "member-votes-gillibrand-2026-11-17",
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
