import APIClient
import Foundation
@testable import Home
import Models
import Onboarding
import Testing

// Round 10 on the phone: following bills and topics, the Following tab's segments, a topic's page,
// and Finals' "Following" (members, bills and topics, one card per vote).

private let doggett = Member(bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
                             district: 37, chamber: .house)
private let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
                          district: nil, chamber: .senate)
private let texas = Delegation(district: District(congress: 119, state: "TX", district: 37, countyFips: nil),
                               members: [doggett, cruz])

private let finance = "Finance and Financial Sector"

/// H.R. 1013 as search lists it (captured 2026-11-13).
private func hr1013Row() throws -> BillListItem {
    try #require(try JSONDecoder().decode(SearchResults.self, from: HomeStub.fixture("search-hr1013")).bills.first)
}

private func vote(_ id: String, chamber: Chamber = .house, at: String, billId: String?) -> Vote {
    Vote(
        id: id, kind: .question, chamber: chamber, congress: 119, session: 2, rollNumber: 1,
        question: "On Passage", billId: billId, nominationId: nil, billRef: nil,
        occurredAt: at, state: .final, threshold: .majority,
        totals: VoteTotals(yea: 300, nay: 100, present: 0, notVoting: 33), candidates: [], result: "Passed"
    )
}

@MainActor
private func follows(bills: [BillListItem] = [], topics: [String] = []) -> Follows {
    var state = FollowState()
    for bill in bills.reversed() { state.follow(bill: bill) }
    for topic in topics.reversed() { state.follow(topic: topic) }
    return Follows(store: InMemoryFollowStore(state))
}

private let offline = FloorAPI(baseURL: URL(string: "https://x.test")!)

@Suite("Finals matching")
struct FinalsMatchingTests {
    /// A card says which bill and topic you follow put it there; neither for a nomination.
    @Test func matchesNameTheBillAndTheTopic() {
        let measure = MeasureSummary(id: "119-hr-1013", kind: .bill, citation: "H.R. 1013", title: "x", policyArea: finance)
        let item = FeedItem(vote: vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z", billId: "119-hr-1013"),
                            measure: measure, positions: [])
        #expect(HomeModel.matches(item, bills: ["119-hr-1013"], topics: [finance])
            == [.bill(citation: "H.R. 1013"), .topic(finance)])
        #expect(HomeModel.matches(item, bills: [], topics: [finance]) == [.topic(finance)])
        #expect(HomeModel.matches(item, bills: ["119-hr-1013"], topics: ["Health"]) == [.bill(citation: "H.R. 1013")])
        #expect(HomeModel.matches(item, bills: [], topics: []).isEmpty)
        let nomination = FeedItem(vote: vote("senate-119-2-1", chamber: .senate, at: "2026-11-11T19:43:00.000Z", billId: nil),
                                  measure: MeasureSummary(id: "119-pn-1", kind: .nomination, citation: "PN1", title: "x"),
                                  positions: [])
        #expect(HomeModel.matches(nomination, bills: ["119-pn-1"], topics: [finance]).isEmpty)
        #expect(FollowMatch.bill(citation: "H.R. 1013").shown == "H.R. 1013 you follow")
        #expect(FollowMatch.topic("Health").shown == "Health")
    }

    /// One vote reached three ways — a member's record, the bill's own votes and the topic's — is
    /// one card: the member's chip, and the measure's topic filled in from the fuller copy.
    @Test func aVoteMatchedSeveralWaysIsOneCard() {
        let passage = vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z", billId: "119-hr-1013")
        let bare = MeasureSummary(id: "119-hr-1013", kind: .bill, citation: "H.R. 1013", title: "Retirement Fairness Act")
        var full = bare
        full.policyArea = finance
        let mine = HomeModel.merge([(doggett, [MemberVote(vote: passage, position: .nay, choice: nil, measure: bare)])],
                                   order: [doggett.bioguideId])
        let other = vote("house-119-2-990", at: "2026-11-01T15:00:00.000Z", billId: "119-hr-9")
        let items = HomeModel.combine(mine, with: [
            RecentVote(vote: passage, measure: full),
            RecentVote(vote: passage, measure: full),
            RecentVote(vote: other, measure: MeasureSummary(id: "119-hr-9", kind: .bill, citation: "H.R. 9", title: "y", policyArea: finance)),
        ])
        #expect(items.map(\.vote.id) == ["house-119-2-321", "house-119-2-990"])
        #expect(items[0].positions.map(\.member.lastName) == ["Doggett"])
        #expect(items[0].measure?.policyArea == finance)
        #expect(HomeModel.matches(items[0], bills: ["119-hr-1013"], topics: [finance])
            == [.bill(citation: "H.R. 1013"), .topic(finance)])
        #expect(items[1].positions.isEmpty)
    }

    /// "Following" shows whenever anything is followed, members or not.
    @MainActor
    @Test func followingABillOrATopicAloneIsAFollowingFeed() throws {
        let byBill = HomeModel(delegation: nil, follows: follows(bills: [try hr1013Row()]), api: offline)
        #expect(byBill.followsAnything)
        #expect(byBill.scope == .yours)
        #expect(byBill.shownScope == .yours)
        let byTopic = HomeModel(delegation: nil, follows: follows(topics: ["Health"]), api: offline)
        #expect(byTopic.shownScope == .yours)
        let nothing = HomeModel(delegation: nil, follows: follows(), api: offline)
        #expect(!nothing.followsAnything)
        #expect(nothing.shownScope == .all)
    }
}

@Suite("Following segments")
struct FollowingSegmentsTests {
    @Test func segmentTitlesCarryTheirCounts() {
        #expect(FollowingView.segmentTitle(.members, count: 6) == "MEMBERS · 6")
        #expect(FollowingView.segmentTitle(.bills, count: 3) == "BILLS · 3")
        #expect(FollowingView.segmentTitle(.topics, count: 0) == "TOPICS · 0")
    }

    /// Bills: the fresh record when loaded, else the row saved at follow time; a record from a
    /// response saved before the API sent stages keeps the saved stage and label.
    @MainActor
    @Test func billsPreferTheFreshRecordButKeepWhatItLacks() throws {
        let saved = try hr1013Row()
        let model = HomeModel(delegation: nil, follows: follows(bills: [saved, .sample]), api: offline)
        #expect(model.followedBills.map(\.id) == ["119-hr-1013", "119-hr-2493"])
        var record = try JSONDecoder().decode(Bill.self, from: HomeStub.fixture("bill-hr1013"))
        #expect(record.stage == nil) // captured before the API sent it
        record.latestAction = LatestAction(on: "2026-11-13", text: "Placed on Senate Legislative Calendar under General Orders.")
        model.billRecords[record.id] = record
        let row = try #require(model.followedBills.first)
        #expect(row.stage == .passedHouse)
        #expect(row.label == saved.label)
        #expect(row.chip == StageChip("SENATE CALENDAR", .neutral))
        #expect(row.roadSteps == 2)
    }
}

extension HomeNetworkTests {
    @Suite("Topic suggestions")
    struct TopicSuggestionTests {
        /// Suggestions: topics not followed, biggest first, none empty, at most six.
        @MainActor
        @Test func suggestionsAreTheBiggestTopicsNotFollowed() async throws {
            let api = HomeStub.api { _ in (200, try HomeStub.fixture("topics")) }
            let model = HomeModel(delegation: nil, follows: follows(topics: ["Health"]), api: api)
            await model.loadTopics()
            let list = try #require(model.topicList)
            #expect(list.topics.count == 32)
            let suggested = model.suggestedTopics
            #expect(suggested.count == 6)
            #expect(!suggested.contains { $0.name == "Health" })
            #expect(suggested.map(\.bills) == suggested.map(\.bills).sorted(by: >))
            let health = try #require(model.followedTopicRows.first)
            #expect(health.name == "Health")
            #expect(health.topic?.bills == list.topics.first { $0.name == "Health" }?.bills)
        }
    }

    /// Finals' Following feed with bills and topics: what it asks for, and when.
    @Suite("Following bills and topics")
    struct BillsAndTopicsTests {
        /// The topics' finals: one H.R. 1013 vote (also on Doggett's record and the bill's own list)
        /// and one other bill in the topic.
        static func topicVotes() throws -> Data {
            let passage = vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z", billId: "119-hr-1013")
            let other = vote("house-119-2-990", at: "2026-11-01T15:00:00.000Z", billId: "119-hr-9")
            return try JSONEncoder().encode(RecentVotes(votes: [
                RecentVote(vote: passage, measure: MeasureSummary(id: "119-hr-1013", kind: .bill, citation: "H.R. 1013",
                                                                  title: "Retirement Fairness", policyArea: finance)),
                RecentVote(vote: other, measure: MeasureSummary(id: "119-hr-9", kind: .bill, citation: "H.R. 9",
                                                                title: "Another", policyArea: finance)),
            ]))
        }

        @MainActor
        private func loaded(_ following: Follows) async throws -> HomeModel {
            let api = HomeStub.api { path in
                switch path {
                case "/v1/votes": (200, try HomeStub.fixture("votes-recent"))
                case "/v1/members/D000399/votes": (200, try HomeStub.fixture("member-votes-doggett-40"))
                case "/v1/members/C001098/votes": (200, try HomeStub.fixture("member-votes-cruz-40"))
                case "/v1/bills/119-hr-1013": (200, try HomeStub.fixture("bill-hr1013"))
                case "/v1/bills/119-hr-2493": (500, Data(#"{"error":"boom"}"#.utf8))
                default: (200, try HomeStub.fixture("member-detail"))
                }
            }
            let model = HomeModel(delegation: texas, follows: following, api: api)
            await model.load()
            #expect(model.phase == .loaded)
            return model
        }

        /// The topics' route answers by query; this stands in for it beside the rest.
        @MainActor
        private func loadedWithTopics(_ following: Follows) async throws -> HomeModel {
            let api = HomeStub.byURL { url in
                let topics = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "topic" } ?? []
                switch url.path {
                case "/v1/votes": return topics.isEmpty ? (200, try HomeStub.fixture("votes-recent")) : (200, try Self.topicVotes())
                case "/v1/members/D000399/votes": return (200, try HomeStub.fixture("member-votes-doggett-40"))
                case "/v1/members/C001098/votes": return (200, try HomeStub.fixture("member-votes-cruz-40"))
                case "/v1/bills/119-hr-1013": return (200, try HomeStub.fixture("bill-hr1013"))
                default: return (200, try HomeStub.fixture("member-detail"))
                }
            }
            let model = HomeModel(delegation: texas, follows: following, api: api)
            await model.load()
            #expect(model.phase == .loaded)
            return model
        }

        private func topicQueries() -> [[String]] {
            HomeStub.urls.filter { $0.path == "/v1/votes" }.compactMap { url in
                let topics = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .filter { $0.name == "topic" }.compactMap(\.value) ?? []
                return topics.isEmpty ? nil : topics
            }
        }

        /// A followed bill and topic, with your members: one card per vote, saying what matched; one
        /// request per bill and one for all the topics, sent as repeated `topic=` (names hold commas).
        @MainActor
        @Test func billsAndTopicsJoinYourMembersFeed() async throws {
            var stale = try hr1013Row()
            stale.latestAction = LatestAction(on: "2026-01-01", text: "Introduced in House")
            let following = follows(bills: [stale], topics: [finance, "Arts, Culture, Religion"])
            let model = try await loadedWithTopics(following)
            let passage = try #require(model.items.first { $0.vote.id == "house-119-2-321" })
            #expect(model.items.filter { $0.vote.id == "house-119-2-321" }.count == 1)
            #expect(passage.positions.map(\.member.lastName) == ["Doggett"])
            #expect(model.matches(passage) == [.bill(citation: "H.R. 1013"), .topic(finance)])
            let other = try #require(model.items.first { $0.vote.id == "house-119-2-990" })
            #expect(other.positions.isEmpty)
            #expect(model.matches(other) == [.topic(finance)])
            #expect(HomeStub.paths.filter { $0.hasPrefix("/v1/bills/") }.count == 1)
            #expect(topicQueries() == [[finance, "Arts, Culture, Religion"]])
            let raw = try #require(HomeStub.urls.first { $0.query?.contains("topic=") == true }?.query)
            #expect(raw.contains("topic=Arts,%20Culture,%20Religion") || raw.contains("topic=Arts%2C%20Culture%2C%20Religion"))
            // The bill's saved row followed the fresh record.
            #expect(following.state.followedBills.first?.latestAction?.on == "2026-11-12")
        }

        /// Following a bill fetches just it; a topic, the topics' finals; unfollowing either, nothing.
        @MainActor
        @Test func followingFetchesOnlyWhatIsNew() async throws {
            let following = follows()
            let model = try await loadedWithTopics(following)
            #expect(topicQueries().isEmpty)
            var before = HomeStub.paths.count
            following.toggle(bill: try hr1013Row())
            await model.sync()
            #expect(Array(HomeStub.paths.dropFirst(before)) == ["/v1/bills/119-hr-1013"])
            #expect(model.items.contains { model.matches($0) == [.bill(citation: "H.R. 1013")] })

            before = HomeStub.paths.count
            following.toggle(topic: finance)
            await model.sync()
            #expect(Array(HomeStub.paths.dropFirst(before)) == ["/v1/votes"])
            #expect(model.items.contains { $0.vote.id == "house-119-2-990" })

            before = HomeStub.paths.count
            following.toggle(topic: finance)
            await model.sync()
            following.update { $0.unfollow(bill: "119-hr-1013") }
            await model.sync()
            #expect(HomeStub.paths.count == before)
            #expect(!model.items.contains { $0.vote.id == "house-119-2-990" })
            #expect(model.items.allSatisfy { model.matches($0).isEmpty })
        }

        /// A followed bill that fails to load leaves the rest of the feed and is named under it.
        @MainActor
        @Test func aFailingBillDoesNotBlankTheFeed() async throws {
            let following = follows(bills: [try hr1013Row(), .sample])
            let model = try await loaded(following)
            #expect(!model.items.isEmpty)
            #expect(model.unavailableBills == ["119-hr-2493"])
            #expect(model.unavailableNote == "Couldn't load H.R. 2493.")
            // The Bills list says only the bills' part; Finals says both.
            #expect(model.unavailableBillsNote == "Couldn't load H.R. 2493.")
            #expect(model.unavailableMembersNote == nil)
            #expect(model.billRecords["119-hr-1013"] != nil)
            #expect(model.followedBills.map(\.id) == ["119-hr-1013", "119-hr-2493"])
        }

        /// Following more bills than the feed fetches: the 20 most recently followed are fetched,
        /// the rest listed as saved, and both lists say so.
        @MainActor
        @Test func billFetchesAreBounded() async throws {
            let base = try hr1013Row()
            var state = FollowState()
            for n in 1...25 {
                var row = base
                row.id = "119-hr-\(n)"
                row.citation = "H.R. \(n)"
                state.follow(bill: row, at: Date(timeIntervalSince1970: Double(n) * 1000))
            }
            // Reorder so your order is not the follow order: the oldest five sit at the top.
            state.move(.bill, fromOffsets: IndexSet(20..<25), toOffset: 0)
            let following = Follows(store: InMemoryFollowStore(state))
            let api = HomeStub.api { path in
                path == "/v1/votes" ? (200, try HomeStub.fixture("votes-recent")) : (200, try HomeStub.fixture("bill-hr1013"))
            }
            let model = HomeModel(delegation: nil, follows: following, api: api)
            #expect(model.fetchedBillIds.count == 20)
            #expect(Set(model.fetchedBillIds) == Set((6...25).map { "119-hr-\($0)" }))
            await model.load()
            #expect(HomeStub.paths.filter { $0.hasPrefix("/v1/bills/") }.count == 20)
            #expect(model.billLimitNote == "Finals has votes on your 20 most recently followed bills. The other 5 are listed as last saved.")
            #expect(model.followedBills.count == 25)
            // A sync fetches none of the five either.
            let before = HomeStub.paths.count
            await model.sync()
            #expect(HomeStub.paths.count == before)
        }

        /// The topics' finals are asked for in the chamber on screen, and again when it changes.
        @MainActor
        @Test func topicVotesFollowTheChamberFilter() async throws {
            let following = follows(topics: [finance, "Not A Topic"])
            let model = try await loadedWithTopics(following)
            func topicChambers() -> [String?] {
                HomeStub.urls.filter { $0.path == "/v1/votes" && $0.query?.contains("topic=") == true }.map { url in
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "chamber" }?.value
                }
            }
            #expect(topicChambers() == [nil])
            // Only the real topic is sent.
            #expect(topicQueries() == [[finance]])
            model.filter = .senate
            await model.sync()
            #expect(topicChambers() == [nil, "senate"])
            let before = HomeStub.paths.count
            await model.sync()
            #expect(HomeStub.paths.count == before)
            model.filter = .all
            await model.sync()
            #expect(topicChambers() == [nil, "senate", nil])
        }

        /// Bills or topics alone are a Following feed: the latest finals failing beside it does not
        /// fail it.
        @MainActor
        @Test func aBillsOnlyFeedSurvivesTheLatestFinalsFailing() async throws {
            let api = HomeStub.api { path in
                switch path {
                case "/v1/bills/119-hr-1013": (200, try HomeStub.fixture("bill-hr1013"))
                default: (500, Data(#"{"error":"down"}"#.utf8))
                }
            }
            let model = HomeModel(delegation: nil, follows: follows(bills: [try hr1013Row()]), api: api)
            await model.load()
            #expect(model.phase == .loaded)
            #expect(model.visibleItems.map(\.vote.id) == ["house-119-2-321"])
        }

        /// No district and only a bill followed: the bill's votes are the Following feed.
        @MainActor
        @Test func aBillAloneIsAFeed() async throws {
            let api = HomeStub.api { path in
                switch path {
                case "/v1/votes": (200, try HomeStub.fixture("votes-recent"))
                case "/v1/bills/119-hr-1013": (200, try HomeStub.fixture("bill-hr1013"))
                default: (404, Data(#"{"error":"no"}"#.utf8))
                }
            }
            let model = HomeModel(delegation: nil, follows: follows(bills: [try hr1013Row()]), api: api)
            await model.load()
            #expect(model.phase == .loaded)
            #expect(model.visibleItems.map(\.vote.id) == ["house-119-2-321"])
            #expect(model.visibleItems.first?.measure?.policyArea == finance)
            #expect(!model.needsRefresh)
        }
    }

    @Suite("Topic page")
    struct TopicPageTests {
        static func secondPage() throws -> Data {
            let first = try JSONDecoder().decode(TopicBills.self, from: HomeStub.fixture("topic-bills-health"))
            // The next page repeats the first page's last bill (its action moved mid-scroll) and ends.
            let next = TopicBills(congress: 119, topic: first.topic, filter: .all,
                                  bills: [first.bills.last!, .sample, .sampleDisapproval], nextCursor: nil)
            return try JSONEncoder().encode(next)
        }

        @MainActor
        private func model(failingMore: Bool = false) -> TopicPageModel {
            let api = HomeStub.byURL { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard url.path == "/v1/topics/Health/bills" else { return (404, Data(#"{"error":"no"}"#.utf8)) }
                if items.contains(where: { $0.name == "cursor" }) {
                    return failingMore ? (500, Data(#"{"error":"down"}"#.utf8)) : (200, try Self.secondPage())
                }
                if items.first(where: { $0.name == "filter" })?.value == "law" {
                    let empty = TopicBills(congress: 119, topic: .sample, filter: .law, bills: [], nextCursor: nil)
                    return (200, try JSONEncoder().encode(empty))
                }
                return (200, try HomeStub.fixture("topic-bills-health"))
            }
            return TopicPageModel(name: "Health", api: api)
        }

        @MainActor
        @Test func pagesWithTheCursorAndListsEachBillOnce() async throws {
            let page = model()
            await page.load()
            #expect(page.phase == .loaded)
            #expect(page.bills.count == 25)
            #expect(page.hasMore)
            #expect(page.topic?.name == "Health")
            await page.loadMore()
            let cursor = HomeStub.urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first { $0.name == "cursor" }?.value
            #expect(cursor == "WyIyMDI2LTEwLTI2IiwiMTE5LWhyLTEwOTA4Il0")
            #expect(page.bills.count == 27) // 25 + 3, one repeated
            #expect(Set(page.bills.map(\.id)).count == page.bills.count)
            #expect(!page.hasMore)
            // At the end, nothing more is asked for.
            let asked = HomeStub.urls.count
            await page.loadMore()
            #expect(HomeStub.urls.count == asked)
        }

        @MainActor
        @Test func aFilterStartsAgainAndSaysWhenItIsEmpty() async throws {
            let page = model()
            await page.load()
            await page.select(.law)
            #expect(page.filter == .law)
            #expect(page.bills.isEmpty)
            #expect(page.phase == .loaded)
            let filter = HomeStub.urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first { $0.name == "filter" }?.value
            #expect(filter == "law")
            #expect(TopicPageModel.emptyMessage(topic: "Health", filter: .law) == "No Health bills have become law this Congress yet.")
            #expect(TopicPageModel.label(.stalled) == "Stalled")
        }

        @MainActor
        @Test func aFailedNextPageKeepsTheList() async throws {
            let page = model(failingMore: true)
            await page.load()
            await page.loadMore()
            #expect(page.bills.count == 25)
            #expect(page.moreError != nil)
            #expect(page.hasMore)
            #expect(!page.isLoadingMore)
        }

        @MainActor
        @Test func aFailedFirstPageIsAnError() async throws {
            let page = TopicPageModel(name: "Health", api: HomeStub.api { _ in (500, Data(#"{"error":"down"}"#.utf8)) })
            await page.load()
            guard case .failed = page.phase else {
                Issue.record("expected failure, got \(page.phase)")
                return
            }
        }

        /// A filter change while a next page is out cancels it: paging works on the new list, and
        /// the old page never lands on it (review of #38: `isLoadingMore` stuck true forever).
        @MainActor
        @Test func aFilterChangeDuringANextPageLeavesPagingWorking() async throws {
            let api = GatedStub.api { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let filter = items.first { $0.name == "filter" }?.value
                if items.contains(where: { $0.name == "cursor" }) {
                    // All's next page never answers; Stalled's does.
                    return filter == "all" ? nil : (200, try Self.secondPage())
                }
                return (200, try HomeStub.fixture("topic-bills-health"))
            }
            let page = TopicPageModel(name: "Health", api: api)
            await page.load()
            let more = Task { await page.loadMore() }
            try await GatedStub.waitForHeld()
            #expect(page.isLoadingMore)
            await page.select(.stalled)
            #expect(!page.isLoadingMore)
            #expect(page.filter == .stalled)
            #expect(page.bills.count == 25)
            await more.value
            #expect(page.bills.count == 25) // the cancelled page did not land
            await page.loadMore()
            #expect(page.bills.count == 27)
            let last = try #require(GatedStub.urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
            #expect(last.first { $0.name == "filter" }?.value == "stalled")
            #expect(last.contains { $0.name == "cursor" })
            #expect(!page.isLoadingMore)
        }

        /// A refresh during a next page cancels it the same way.
        @MainActor
        @Test func aRefreshDuringANextPageLeavesPagingWorking() async throws {
            let answered = GatedStub.Flag()
            let api = GatedStub.api { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if items.contains(where: { $0.name == "cursor" }) {
                    // The first next page never answers; later ones do.
                    return answered.flip() ? (200, try Self.secondPage()) : nil
                }
                return (200, try HomeStub.fixture("topic-bills-health"))
            }
            let page = TopicPageModel(name: "Health", api: api)
            await page.load()
            let more = Task { await page.loadMore() }
            try await GatedStub.waitForHeld()
            await page.load()
            #expect(!page.isLoadingMore)
            await more.value
            await page.loadMore()
            #expect(page.bills.count == 27)
        }

        /// The list's end reached while only the saved page 1 is up asks for nothing with the saved
        /// cursor; once the fresh page 1 replaces it, the next page is asked for with the fresh one.
        @MainActor
        @Test func noNextPageFromTheSavedPassThenOneAfterTheFreshPage() async throws {
            let cache = try SwiftDataResponseCache.inMemory()
            let online = HomeStub.api(cache: cache) { _ in (200, try HomeStub.fixture("topic-bills-health")) }
            await TopicPageModel(name: "Health", api: online).load()
            let api = GatedStub.api(cache: cache) { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                // The fresh page 1 waits until released; the next page answers at once.
                return items.contains { $0.name == "cursor" } ? (200, try Self.secondPage()) : nil
            }
            let page = TopicPageModel(name: "Health", api: api)
            let loading = Task { await page.load() }
            try await GatedStub.waitForHeld()
            #expect(page.bills.count == 25) // the saved page is up
            await page.loadMore()
            #expect(!GatedStub.urls.contains { $0.query?.contains("cursor=") == true })
            GatedStub.releaseHeld(status: 200, body: try HomeStub.fixture("topic-bills-health"))
            await loading.value
            #expect(page.saved == nil)
            #expect(page.bills.count == 27)
            #expect(GatedStub.urls.filter { $0.query?.contains("cursor=") == true }.count == 1)
        }

        /// The first page is saved, so a topic opened offline shows what was seen.
        @MainActor
        @Test func theFirstPageOpensOffline() async throws {
            let cache = try SwiftDataResponseCache.inMemory()
            let online = HomeStub.api(cache: cache) { _ in (200, try HomeStub.fixture("topic-bills-health")) }
            await TopicPageModel(name: "Health", api: online).load()
            let offline = HomeStub.api(cache: cache) { _ in throw URLError(.notConnectedToInternet) }
            let page = TopicPageModel(name: "Health", api: offline)
            await page.load()
            #expect(page.phase == .loaded)
            #expect(page.bills.count == 25)
            #expect(page.saved != nil)
        }
    }
}

/// A stub that can leave a request unanswered: the handler returns nil to hold it (until
/// ``releaseHeld(status:body:)``, or until the request is cancelled), so a test can act while a
/// request is in flight.
final class GatedStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URL) throws -> (Int, Data)?)?
    nonisolated(unsafe) private static var seen: [URL] = []
    nonisolated(unsafe) private static var held: [GatedStub] = []

    /// Flips once: false the first time it is asked, true after.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = false
        func flip() -> Bool { lock.withLock { defer { asked = true }; return asked } }
    }

    static func api(cache: (any ResponseCache)? = nil, _ handler: @escaping @Sendable (URL) throws -> (Int, Data)?) -> FloorAPI {
        lock.withLock {
            self.handler = handler
            seen = []
            held = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedStub.self]
        return FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: URLSession(configuration: configuration),
                        cache: cache)
    }

    static var urls: [URL] { lock.withLock { seen } }

    /// Waits (up to two seconds) until a request is being held.
    static func waitForHeld() async throws {
        for _ in 0..<400 {
            if lock.withLock({ !held.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("no request was held")
    }

    /// Answers every held request.
    static func releaseHeld(status: Int, body: Data) {
        let requests = lock.withLock { () -> [GatedStub] in
            defer { held = [] }
            return held
        }
        for request in requests { request.respond(status: status, body: body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> (@Sendable (URL) throws -> (Int, Data)?)? in
            if let url = request.url { Self.seen.append(url) }
            return Self.handler
        }
        let answer: (Int, Data)?
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            answer = try handler(url)
        } catch {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let answer else {
            Self.lock.withLock { Self.held.append(self) }
            return
        }
        respond(status: answer.0, body: answer.1)
    }

    private func respond(status: Int, body: Data) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.held.removeAll { $0 === self } }
    }
}
