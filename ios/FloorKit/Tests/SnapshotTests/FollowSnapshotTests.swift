#if os(iOS)
import APIClient
import BillScreen
import DesignSystem
import Foundation
import Home
import Models
import Onboarding
import SnapshotTesting
import SwiftUI
import Testing

/// Round 10's screens (<https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>): the Following tab's
/// Bills and Topics, a topic's page, the "+ Add" search, the bill screen with Follow, and a Finals
/// card that says which followed bill and topic it is there for. All from responses captured from
/// the API on 2026-11-13 (`ModelsTests/Fixtures`), through `FixtureServer`.
@MainActor
@Suite("Follow snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct FollowSnapshotTests {
    init() { _ = NoPortraits.installed }

    private func fixtureRows() throws -> (hr1013: BillListItem, law: BillListItem) {
        let number: SearchResults = try fixture("search-hr1013")
        let health: TopicBills = try fixture("topic-bills-health")
        return (try #require(number.bills.first), try #require(health.bills.first { $0.citation == "H.R. 1703" }))
    }

    private func follows(bills: [BillListItem] = [], topics: [String] = []) -> Follows {
        var state = FollowState()
        for bill in bills.reversed() { state.follow(bill: bill) }
        for topic in topics.reversed() { state.follow(topic: topic) }
        return Follows(store: InMemoryFollowStore(state))
    }

    // MARK: - Following tab

    /// Four followed bills: law, in committee after passing the House, the Senate's failed motion to
    /// proceed, and one not staged yet whose latest action puts it in committee.
    @Test func followingBills() throws {
        let rows = try fixtureRows()
        let model = HomeModel(delegation: nil, follows: follows(bills: [rows.law, rows.hr1013, .sampleDisapproval, .sample]),
                              api: FixtureServer.api)
        let view = FollowingView(model: model, segment: .bills, onOpenMember: { _ in }, onFindReps: {}, onChangeAddress: {})
        assertScreen(view, height: 1000, [.light, .dark])
    }

    @Test func followingBillsLargestText() throws {
        let rows = try fixtureRows()
        let model = HomeModel(delegation: nil, follows: follows(bills: [rows.law, rows.hr1013]), api: FixtureServer.api)
        let view = FollowingView(model: model, segment: .bills, onOpenMember: { _ in }, onFindReps: {}, onChangeAddress: {})
        assertScreen(view, height: 1800, [.largestText])
    }

    /// Two followed topics with their counts, then the six biggest others to follow.
    @Test func followingTopics() async throws {
        let model = HomeModel(delegation: nil, follows: follows(topics: ["Health", "Immigration"]), api: FixtureServer.api)
        await model.loadTopics()
        let view = FollowingView(model: model, segment: .topics, onOpenMember: { _ in }, onFindReps: {}, onChangeAddress: {})
        assertScreen(view, height: 1100, [.light, .dark])
    }

    @Test func followingNothingYet() throws {
        let model = HomeModel(delegation: nil, follows: follows(), api: FixtureServer.api)
        let view = FollowingView(model: model, segment: .bills, onOpenMember: { _ in }, onFindReps: {}, onChangeAddress: {})
        assertScreen(view, height: 600, [.light])
    }

    // MARK: - Topic page

    @Test func topicPage() async throws {
        let model = TopicPageModel(name: "Health", api: FixtureServer.api)
        await model.load()
        let view = NavigationStack { TopicPageView(model: model, follows: follows(topics: ["Health"]), onOpenBill: { _ in }) }
        assertScreen(view, height: 1400, [.light, .dark])
    }

    @Test func topicPageFailed() async throws {
        let model = TopicPageModel(name: "Health", api: FixtureServer.api(OfflineServer.self))
        await model.load()
        let view = NavigationStack { TopicPageView(model: model, follows: follows(), onOpenBill: { _ in }) }
        assertScreen(view, height: 600, [.light])
    }

    // MARK: - Search

    private func search(_ query: String, follows: Follows) async -> some View {
        // A long pause, so the sheet's own `.task` does not search again while the image is drawn.
        let model = FollowSearchModel(api: FixtureServer.api, debounce: .seconds(60))
        model.query = query
        await model.searchNow()
        return AddFollowsView(model: model, follows: follows, reps: [], onOpenBill: { _ in }, onOpenTopic: { _ in })
    }

    /// Words: bills (one followed), and the no-members card under Members.
    @Test func searchWords() async throws {
        let view = await search("rural health", follows: follows(bills: [.sample]))
        assertScreen(view, height: 1000, [.light, .dark])
    }

    /// A bill number: that bill alone, with its latest step.
    @Test func searchBillNumber() async throws {
        assertScreen(await search("hr 1013", follows: follows()), height: 500, [.light])
    }

    /// At AX5 the Follow pill goes under the bill's text, and the label gets its lines.
    @Test func searchBillNumberLargestText() async throws {
        assertScreen(await search("hr 1013", follows: follows()), height: 1600, [.largestText])
    }

    // MARK: - Bill screen

    /// Follow bill in the bar, the citation above the title, and the topic followed.
    @Test func billWithFollow() async throws {
        let model = BillScreenModel(billId: "119-hr-1013", api: FixtureServer.api)
        await model.load()
        let following = follows(bills: [try fixtureRows().hr1013], topics: ["Finance and Financial Sector"])
        let view = NavigationStack {
            BillScreenView(model: model, follows: following, onOpenTopic: { _ in }, onOpenVote: { _ in })
        }
        assertScreen(view, height: 1400, [.light, .dark])
    }

    // MARK: - Finals

    /// The H.R. 1013 card in Finals' Following: a followed bill and its followed topic, and the member.
    @Test func finalsCardSaysWhatMatched() throws {
        let entry = try memberVote("member-votes-doggett-40", "house-119-2-321")
        let doggett = try #require(try austin().members.first { $0.lastName == "Doggett" })
        let card = ScoreboardCard(
            vote: entry.vote, title: entry.measure?.title ?? entry.vote.question, citation: entry.measure?.citation,
            positions: [MemberPosition(member: doggett, position: entry.position, choice: entry.choice)],
            matches: [.bill(citation: "H.R. 1013"), .topic("Finance and Financial Sector")]
        )
        assertCard(card)
    }
}
#endif
