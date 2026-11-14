import APIClient
import Foundation
@testable import Home
import Models
import Onboarding
import Testing

private let doggett = Member(bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
                             district: 37, chamber: .house)
private let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
                          district: nil, chamber: .senate)
private let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D",
                              state: "NY", district: 8, chamber: .house)
private let hageman = Member(bioguideId: "H001096", firstName: "Harriet", lastName: "Hageman", party: "R",
                             state: "WY", district: 0, chamber: .house)
private let norton = Member(bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D",
                            state: "DC", district: 0, chamber: .house)

private func vote(_ id: String, chamber: Chamber = .house, at: String?) -> Vote {
    Vote(
        id: id, kind: .question, chamber: chamber, congress: 119, session: 2, rollNumber: 1,
        question: "On Passage", billId: "119-hr-1013", nominationId: nil, billRef: "H R 1013",
        occurredAt: at, state: .final, threshold: .majority,
        totals: VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10), candidates: [], result: "Passed"
    )
}

private let hr1013 = MeasureSummary(id: "119-hr-1013", kind: .bill, citation: "H.R. 1013", title: "Retirement Fairness Act")

private func row(_ v: Vote, _ position: Position) -> MemberVote {
    MemberVote(vote: v, position: position, choice: nil, measure: hr1013)
}

private let texas = Delegation(district: District(congress: 119, state: "TX", district: 37, countyFips: nil),
                               members: [doggett, cruz])

@MainActor
private func follows(_ members: [Member] = [], hide: [String] = []) -> Follows {
    var state = FollowState()
    for member in members.reversed() { state.follow(member: member) } // so `members` is the display order
    for id in hide { state.setHidden(rep: id, true) }
    return Follows(store: InMemoryFollowStore(state))
}

@Suite("Finals with followed members")
struct FinalsGroupingTests {
    /// The mock's H.R. 1013 card: your rep and two followed members on one card, reps first, then
    /// who you follow in your order — not by surname.
    @Test func oneCardListsEveryMemberWhoVotedInYourOrder() {
        let passage = vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z")
        let items = HomeModel.merge([
            (hageman, [row(passage, .yea)]),
            (doggett, [row(passage, .nay)]),
            (jeffries, [row(passage, .nay)]),
        ], order: [doggett.bioguideId, jeffries.bioguideId, hageman.bioguideId])
        #expect(items.count == 1)
        #expect(items[0].positions.map(\.member.lastName) == ["Doggett", "Jeffries", "Hageman"])
        #expect(items[0].summary == "Doggett Nay · Jeffries Nay · Hageman Yea")
    }

    @Test func aMemberListedTwiceIsOneChip() {
        let passage = vote("house-119-2-321", at: nil)
        let items = HomeModel.merge([(doggett, [row(passage, .nay)]), (doggett, [row(passage, .nay)])],
                                    order: [doggett.bioguideId])
        #expect(items[0].positions.count == 1)
    }

    /// "All" is the latest finals, each carrying whichever of your members voted on it.
    @Test func allCarriesYourMembersOnTheVotesTheyTookPartIn() {
        let ours = vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z")
        let theirs = vote("senate-119-2-262", chamber: .senate, at: "2026-11-12T20:21:00.000Z")
        let yours = HomeModel.merge([(doggett, [row(ours, .nay)])], order: [doggett.bioguideId])
        let all = HomeModel.annotate([
            RecentVote(vote: theirs, measure: nil),
            RecentVote(vote: ours, measure: hr1013),
        ], with: yours)
        #expect(all.map(\.vote.id) == ["senate-119-2-262", "house-119-2-321"])
        #expect(all[0].positions.isEmpty)
        #expect(all[1].positions.map(\.member.lastName) == ["Doggett"])
    }

    @MainActor
    @Test func yourMembersAreRepsNotHiddenThenFollowed() {
        let model = HomeModel(delegation: texas, follows: follows([jeffries, hageman], hide: [cruz.bioguideId]),
                              api: FloorAPI(baseURL: URL(string: "https://x.test")!))
        #expect(model.yourMembers.map(\.lastName) == ["Doggett", "Jeffries", "Hageman"])
        #expect(model.scope == .yours)
        // The vote route names at most ten; the bill screen takes all of them.
        #expect(model.voteMembers(for: "house-119-2-1").count == 3)
    }

    @MainActor
    @Test func scopeAndChamberFiltersCombine() {
        let model = HomeModel(delegation: texas, follows: follows([jeffries]), api: FloorAPI(baseURL: URL(string: "https://x.test")!))
        let ours = vote("house-119-2-321", at: "2026-11-11T19:43:00.000Z")
        let theirs = vote("senate-119-2-262", chamber: .senate, at: "2026-11-12T20:21:00.000Z")
        model.items = HomeModel.merge([(doggett, [row(ours, .nay)])], order: [doggett.bioguideId])
        model.allItems = HomeModel.annotate([RecentVote(vote: theirs, measure: nil), RecentVote(vote: ours, measure: nil)],
                                            with: model.items)
        #expect(model.visibleItems.map(\.vote.id) == ["house-119-2-321"])
        model.scope = .all
        #expect(model.visibleItems.map(\.vote.id) == ["senate-119-2-262", "house-119-2-321"])
        model.filter = .senate
        #expect(model.visibleItems.map(\.vote.id) == ["senate-119-2-262"])
        #expect(model.latestFinal?.vote.id == "senate-119-2-262")
    }

    /// D.C. has no senators, so its Senate filter says why — unless you follow a senator.
    @MainActor
    @Test func aFollowedSenatorFillsDCsSenateFilter() {
        let dc = Delegation(district: District(congress: 119, state: "DC", district: 0, countyFips: nil), members: [norton])
        let api = FloorAPI(baseURL: URL(string: "https://x.test")!)
        let alone = HomeModel(delegation: dc, api: api)
        alone.filter = .senate
        #expect(alone.emptyFeedMessage == "District of Columbia has no senators, so there are no Senate votes to show.")
        let withCruz = HomeModel(delegation: dc, follows: follows([cruz]), api: api)
        withCruz.filter = .senate
        #expect(withCruz.emptyFeedMessage == "No recent votes in this chamber.")
    }
}

/// One suite, serialized, because every test in it shares `HomeStub`'s responder.
@Suite("Stubbed network", .serialized)
struct HomeNetworkTests {
    @Suite("No district")
    struct NoDistrictTests {
        /// Skipped onboarding, followed nobody: Finals is every recent final, from `/v1/votes`, with no
        /// member requests at all.
        @MainActor
        @Test func withNobodyFinalsIsEveryRecentFinal() async throws {
            let api = HomeStub.api { path in
                path == "/v1/votes" ? (200, try HomeStub.fixture("votes-recent")) : (404, Data(#"{"error":"no"}"#.utf8))
            }
            let model = HomeModel(delegation: nil, follows: follows(), api: api)
            #expect(model.yourMembers.isEmpty)
            #expect(model.shownScope == .all)
            await model.load()
            #expect(model.phase == .loaded)
            #expect(!model.allItems.isEmpty)
            #expect(model.visibleItems.count == model.allItems.count)
            #expect(model.visibleItems.allSatisfy { $0.positions.isEmpty })
            #expect(model.items.isEmpty)
            #expect(model.latestFinal != nil)
            #expect(!model.needsRefresh)
            #expect(HomeStub.paths == ["/v1/votes"])
        }

        /// No district, one followed member: their record loads beside the latest finals, and
        /// "Your members" is just them.
        @MainActor
        @Test func withOnlyFollowedMembersTheirVotesAreYourFinals() async throws {
            let api = HomeStub.api { path in
                switch path {
                case "/v1/votes": (200, try HomeStub.fixture("votes-recent"))
                case "/v1/members/D000399/votes": (200, try HomeStub.fixture("member-votes-doggett-40"))
                case "/v1/members/D000399": (200, try HomeStub.fixture("member-detail"))
                default: (404, Data(#"{"error":"no"}"#.utf8))
                }
            }
            let following = follows([doggett])
            let model = HomeModel(delegation: nil, follows: following, api: api)
            #expect(model.scope == .yours)
            await model.load()
            #expect(model.phase == .loaded)
            #expect(!model.items.isEmpty)
            #expect(model.items.allSatisfy { $0.positions.map(\.member.lastName) == ["Doggett"] })
            #expect(model.latestVote(of: doggett) != nil)
            #expect(model.loyalty[doggett.bioguideId] != nil)

            // Following someone new changes the key the feed syncs on (a fetch of just them).
            #expect(!model.needsRefresh)
            let key = model.syncKey
            following.toggle(jeffries)
            #expect(model.syncKey != key)
        }

        /// With nobody followed, the latest finals are the whole feed, so their failure is the feed's.
        @MainActor
        @Test func aFailedListIsAFailedFeedWhenItIsTheWholeFeed() async throws {
            let api = HomeStub.api { _ in (500, Data(#"{"error":"down"}"#.utf8)) }
            let model = HomeModel(delegation: nil, follows: follows(), api: api)
            await model.load()
            guard case .failed = model.phase else {
                Issue.record("expected failure, got \(model.phase)")
                return
            }
        }
    }

    @Suite("Member search")
    struct MemberSearchTests {
        @Test func searchesOnlyFromTwoCharacters() {
            #expect(MemberSearchModel.normalized("") == nil)
            #expect(MemberSearchModel.normalized(" n ") == nil)
            #expect(MemberSearchModel.normalized("  NY ") == "NY")
            #expect(MemberSearchModel.normalized("New York\n") == "New York")
        }

        @Test func groupsSenateBeforeHouseAndDropsEmptyGroups() {
            let groups = MemberSearchModel.groups([jeffries, cruz, hageman])
            #expect(groups.map(\.chamber) == [.senate, .house])
            #expect(groups[1].members.map(\.lastName) == ["Jeffries", "Hageman"])
            #expect(MemberSearchModel.groups([jeffries]).map(\.chamber) == [.house])
            #expect(MemberSearchModel.groups([]).isEmpty)
        }

        @MainActor
        @Test func searchesWhatWasTypedInTheChamberPicked() async throws {
            let api = HomeStub.api { _ in (200, try HomeStub.fixture("members-search-new-york")) }
            let model = MemberSearchModel(api: api, debounce: .zero)
            model.query = " New York "
            model.chamber = .senate
            await model.search()
            #expect(model.searched == "New York")
            #expect(!model.results.isEmpty)
            #expect(model.error == nil)
            #expect(!model.isLoading)
            let url = try #require(HomeStub.urls.last)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first { $0.name == "q" }?.value == "New York")
            #expect(items.first { $0.name == "chamber" }?.value == "senate")
        }

        @MainActor
        @Test func noResultsIsAnAnswerAndAFailureIsAnError() async throws {
            let empty = MemberSearchModel(api: HomeStub.api { _ in (200, Data(#"{"members":[]}"#.utf8)) }, debounce: .zero)
            empty.query = "Qx"
            await empty.search()
            #expect(empty.searched == "Qx")
            #expect(empty.results.isEmpty)
            #expect(empty.error == nil)

            let limited = MemberSearchModel(
                api: HomeStub.api { _ in (429, Data(#"{"error":"Too many searches. Please wait a moment and try again."}"#.utf8)) },
                debounce: .zero
            )
            limited.query = "Schumer"
            await limited.search()
            #expect(limited.error != nil)
            #expect(!limited.isLoading)
        }

        @MainActor
        @Test func clearingTheFieldClearsTheList() async throws {
            let model = MemberSearchModel(api: HomeStub.api { _ in (200, try HomeStub.fixture("members-search-new-york")) },
                                          debounce: .zero)
            model.query = "NY"
            await model.search()
            #expect(!model.results.isEmpty)
            model.query = "N"
            await model.search()
            #expect(model.results.isEmpty)
            #expect(model.searched == nil)
        }

        /// A search is never saved: what someone looked up is not worth keeping on the phone.
        @Test func searchIsNotCached() async throws {
            let cache = try SwiftDataResponseCache.inMemory()
            let api = HomeStub.api(cache: cache) { _ in (200, try HomeStub.fixture("members-search-new-york")) }
            _ = try await api.searchMembers(query: "New York")
            #expect(await cache.entries().isEmpty)
        }
    }

    /// Following, hiding, reordering and the chamber filter, after the first load: each fetches only
    /// what is missing.
    @Suite("Sync")
    struct SyncTests {
        @MainActor
        private func loaded() async throws -> (HomeModel, Follows) {
            let api = HomeStub.api { path in
                switch path {
                case "/v1/votes": (200, try HomeStub.fixture("votes-recent"))
                case "/v1/members/D000399/votes": (200, try HomeStub.fixture("member-votes-doggett-40"))
                case "/v1/members/C001098/votes": (200, try HomeStub.fixture("member-votes-cruz-40"))
                case "/v1/members/J000294/votes": (200, Data(#"{"votes":[]}"#.utf8))
                case "/v1/members/H001096/votes": (500, Data(#"{"error":"boom"}"#.utf8))
                default: (200, try HomeStub.fixture("member-detail"))
                }
            }
            let following = follows()
            let model = HomeModel(delegation: texas, follows: following, api: api)
            await model.load()
            #expect(model.phase == .loaded)
            return (model, following)
        }

        private func memberVotePaths() -> [String] {
            HomeStub.paths.filter { $0.hasSuffix("/votes") && $0.hasPrefix("/v1/members/") }
        }

        @MainActor
        @Test func followingSomeoneFetchesOnlyThem() async throws {
            let (model, following) = try await loaded()
            let before = memberVotePaths().count
            following.toggle(jeffries)
            await model.sync()
            #expect(Array(memberVotePaths().dropFirst(before)) == ["/v1/members/J000294/votes"])
            #expect(model.yourMembers.map(\.lastName) == ["Doggett", "Cruz", "Jeffries"])
            #expect(model.records[jeffries.bioguideId] != nil)
        }

        @MainActor
        @Test func hidingAndReorderingFetchNothing() async throws {
            let (model, following) = try await loaded()
            following.toggle(jeffries)
            await model.sync()
            let before = HomeStub.paths.count
            following.update { $0.setHidden(rep: cruz.bioguideId, true) }
            await model.sync()
            following.toggle(jeffries)
            await model.sync()
            #expect(HomeStub.paths.count == before)
            #expect(model.items.allSatisfy { !$0.positions.contains { $0.member == cruz } })
        }

        /// "All" with Senate picked asks for the Senate's latest finals.
        @MainActor
        @Test func aChamberAsksForThatChambersFinals() async throws {
            let (model, _) = try await loaded()
            model.filter = .senate
            await model.sync()
            let asked = HomeStub.urls.last { $0.path == "/v1/votes" }
            let chamber = asked.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first { $0.name == "chamber" }?.value
            #expect(chamber == "senate")
        }

        /// One member failing leaves everyone else's votes on screen and says who is missing.
        @MainActor
        @Test func oneFailingMemberDoesNotBlankTheFeed() async throws {
            let (model, following) = try await loaded()
            following.toggle(hageman)
            await model.sync()
            #expect(model.phase == .loaded)
            #expect(!model.items.isEmpty)
            #expect(model.unavailable.map(\.lastName) == ["Hageman"])
            #expect(model.unavailableNote == "Couldn't load Hageman's votes.")
            // And from scratch, too.
            await model.load()
            #expect(model.phase == .loaded)
            #expect(model.unavailable.map(\.lastName) == ["Hageman"])
        }

        /// A vote's screen names the members on its card first, then fills to ten.
        @MainActor
        @Test func theVoteScreenAsksForTheCardsMembersFirst() async throws {
            let (model, _) = try await loaded()
            let senateVote = try #require(model.items.first { $0.vote.chamber == .senate })
            #expect(model.voteMembers(for: senateVote.vote.id).first == cruz)
            #expect(model.voteMembers(for: "nothing").map(\.lastName) == ["Doggett", "Cruz"])
        }
    }
}

@Suite("Following row text")
struct FollowingTextTests {
    @Test func captionIsPartyThenSeat() {
        #expect(FollowingText.caption(doggett) == "D · House · TX-37")
        #expect(FollowingText.caption(cruz) == "R · Senate · TX")
        #expect(FollowingText.caption(hageman) == "R · House · WY-AL")
        #expect(FollowingText.caption(norton) == "D · Delegate · DC")
        #expect(FollowingText.percent(0.969) == "96.9%")
    }
}

/// Answers by path from a closure, and records what was asked.
final class HomeStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (String) throws -> (Int, Data))?
    nonisolated(unsafe) private static var seen: [URL] = []

    static func api(
        cache: (any ResponseCache)? = nil, _ handler: @escaping @Sendable (String) throws -> (Int, Data)
    ) -> FloorAPI {
        lock.lock()
        self.handler = handler
        seen = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeStub.self]
        return FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: URLSession(configuration: configuration),
                        cache: cache)
    }

    static var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static var paths: [String] { urls.map(\.path) }

    static func fixture(_ name: String) throws -> Data {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent() // HomeTests
        dir.deleteLastPathComponent() // Tests
        return try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if let url = request.url { Self.seen.append(url) }
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url,
              let (status, body) = try? handler(url.path)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
