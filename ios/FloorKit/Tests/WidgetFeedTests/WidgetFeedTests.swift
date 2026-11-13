import APIClient
import Foundation
import Models
import Onboarding
import Testing
@testable import WidgetFeed

/// A real staging response, read from ModelsTests' fixtures in the source tree.
func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // WidgetFeedTests
    dir.deleteLastPathComponent() // Tests
    let data = try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
    return try JSONDecoder().decode(type, from: data)
}

private func records() throws -> [String: [MemberVote]] {
    [
        "D000399": try fixture("member-votes-doggett-40", as: MemberVotes.self).votes,
        "C001056": try fixture("member-votes-cornyn-40", as: MemberVotes.self).votes,
        "C001098": try fixture("member-votes-cruz-40", as: MemberVotes.self).votes,
    ]
}

private let fetched = Date(timeIntervalSince1970: 1_794_528_000)

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    /// The gallery's placeholder is real data: the same values staging returned for TX-37.
    @Test func theSampleIsTheCapturedTX37Data() throws {
        let reps = try fixture("reps-location-austin", as: Reps.self)
        #expect(Delegation.sampleTX37.district == reps.district)
        #expect(Set(Delegation.sampleTX37.members) == Set(reps.members))

        let built = WidgetSnapshot.make(delegation: Delegation(reps: reps), records: try records(), fetchedAt: fetched)
        #expect(built.latestFinal == WidgetSnapshot.sample.latestFinal)
        #expect(built.rows == WidgetSnapshot.sample.rows)
    }

    @Test func smallShowsTheNewestFinalWithYourRepresentativesChip() throws {
        let snapshot = WidgetSnapshot.make(delegation: .sampleTX37, records: try records(), fetchedAt: fetched)
        let final = try #require(snapshot.latestFinal)
        // House roll 321 closed at 19:43 UTC on Nov 11, after the Senate's 00:37 that morning.
        #expect(final.vote.id == "house-119-2-321")
        #expect(final.measure?.citation == "H.R. 1013")
        #expect(final.call.member.lastName == "Doggett")
        #expect(WidgetText.chip(final.call.position, choice: final.call.choice) == "NAY")
        #expect(WidgetText.resultWord(final.vote) == "PASSED")
        #expect(WidgetText.score(final.vote).left.value == 295)
        #expect(WidgetText.score(final.vote).right?.value == 128)
        #expect(WidgetText.smallHeader(final.vote) == "Final · House")
    }

    @Test func aSharedSenateVoteGoesToTheFirstSenatorBySurname() throws {
        var only = try records()
        only["D000399"] = []
        let final = try #require(WidgetSnapshot.make(delegation: .sampleTX37, records: only, fetchedAt: fetched).latestFinal)
        #expect(final.vote.id == "senate-119-2-258")
        #expect(final.call.member.lastName == "Cornyn")
        #expect(WidgetText.chip(final.call.position, choice: nil) == "DNV")
    }

    @Test func mediumHasOneRowPerMemberRepresentativeFirst() throws {
        let snapshot = WidgetSnapshot.make(delegation: .sampleTX37, records: try records(), fetchedAt: fetched)
        #expect(snapshot.rows.map(\.member.lastName) == ["Doggett", "Cornyn", "Cruz"])
        #expect(WidgetText.header(snapshot) == "Your three · TX-37")

        let lines = snapshot.rows.map { row -> String in
            let latest = row.latest!
            return "\(WidgetText.chip(latest.position, choice: latest.choice)) \(row.member.lastName) "
                + "\(WidgetText.citation(latest.vote, measure: latest.measure)) · \(WidgetText.resultLine(latest.vote))"
        }
        // The mock's three rows, word for word.
        #expect(lines == [
            "NAY Doggett H.R. 1013 · Passed 295–128",
            "DNV Cornyn H.R. 2347 · Agreed 62–21",
            "YEA Cruz H.R. 2347 · Agreed 62–21",
        ])
    }

    @Test func anOpenVoteIsAMembersLatestButNotTheLatestFinal() throws {
        var rows = try records()
        var open = rows["D000399"]![0]
        open.vote.id = "house-119-2-322"
        open.vote.state = .open
        open.vote.result = nil
        open.vote.occurredAt = "2026-11-12T15:00:00.000Z"
        rows["D000399"]!.insert(open, at: 0)

        let snapshot = WidgetSnapshot.make(delegation: .sampleTX37, records: rows, fetchedAt: fetched)
        #expect(snapshot.latestFinal?.vote.id == "house-119-2-321")
        #expect(snapshot.rows[0].latest?.vote.id == "house-119-2-322")
        #expect(WidgetText.resultLine(snapshot.rows[0].latest!.vote) == "Voting now")
    }

    @Test func aMemberWithNoVotesHasAnEmptyRow() throws {
        var rows = try records()
        rows["C001098"] = []
        let snapshot = WidgetSnapshot.make(delegation: .sampleTX37, records: rows, fetchedAt: fetched)
        let cruz = try #require(snapshot.rows.first { $0.member.lastName == "Cruz" })
        #expect(cruz.latest == nil)
        #expect(WidgetText.rowLabel(cruz) == "Cruz has no recorded votes yet.")
    }

    @Test func nothingFinalMeansNoSmallVote() {
        let snapshot = WidgetSnapshot.make(delegation: .sampleTX37, records: [:], fetchedAt: fetched)
        #expect(snapshot.latestFinal == nil)
        #expect(snapshot.rows.allSatisfy { $0.latest == nil })
    }

    @Test func belongsOnlyToTheDelegationItWasBuiltFor() {
        let snapshot = WidgetSnapshot.sample
        #expect(snapshot.belongs(to: .sampleTX37))
        #expect(!snapshot.belongs(to: .sample))
        var moved = Delegation.sampleTX37
        moved.district.district = 35
        #expect(!snapshot.belongs(to: moved))
    }

    /// The widget sees the district and the members, never where you are.
    @Test func theSavedSnapshotHoldsNoAddressOrCoordinate() throws {
        let json = String(decoding: try JSONEncoder().encode(WidgetSnapshot.sample), as: UTF8.self).lowercased()
        for word in ["address", "latitude", "longitude", "\"lat\"", "\"lng\"", "coordinate", "countyfips"] {
            #expect(!json.contains(word), "\(word)")
        }
    }
}

@Suite("Widget text")
struct WidgetTextTests {
    @Test func chipsForEveryPosition() {
        #expect(WidgetText.chip(.yea, choice: nil) == "YEA")
        #expect(WidgetText.chip(.nay, choice: nil) == "NAY")
        #expect(WidgetText.chip(.present, choice: nil) == "PRESENT")
        #expect(WidgetText.chip(.notVoting, choice: nil) == "DNV")
        #expect(WidgetText.chip(.candidate, choice: "Jeffries") == "JEFFRIES")
        #expect(WidgetText.chip(.candidate, choice: "Donald J. Trump") == "DONALD J. TRUMP")
        #expect(WidgetText.chip(.candidate, choice: nil) == "BALLOT")
        #expect(WidgetText.chip(.candidate, choice: "  ") == "BALLOT")
    }

    /// The result is what the chamber recorded, not which side had more votes: H.J.Res. 1 lost
    /// 212–206 under a two-thirds bar.
    @Test func theResultIsTheRecordNotTheCount() throws {
        let detail = try fixture("vote-two-thirds-failed", as: VoteDetail.self)
        let vote = detail.vote
        #expect(vote.totals.yea > vote.totals.nay)
        #expect(WidgetText.resultWord(vote) == "FAILED")
        #expect(WidgetText.resultLine(vote).hasPrefix("Failed "))
    }

    @Test func aRecordThatContradictsTheCountWins() {
        var vote = Vote.sample
        vote.totals = VoteTotals(yea: 50, nay: 50, present: 0, notVoting: 0)
        vote.result = "Passed" // a Vice President's tie-break
        #expect(WidgetText.resultWord(vote) == "PASSED")
        #expect(WidgetText.resultLine(vote) == "Passed 50–50")
    }

    /// 53–47 is a majority but not 60 sworn, and the Senate recorded "Rejected".
    @Test func clotureShortOfSixtyReadsRejected() throws {
        let vote = try fixture("vote-cloture-failed", as: VoteDetail.self).vote
        #expect(vote.totals.yea > vote.totals.nay)
        #expect(WidgetText.resultWord(vote) == "REJECTED")
        #expect(WidgetText.resultLine(vote) == "Rejected 53–47")
    }

    /// A Speaker ballot's `result` is its leader, not a winner (lesson 16).
    @Test func aSpeakerBallotThatElectedNobody() throws {
        let vote = try fixture("vote-election", as: VoteDetail.self).vote
        #expect(WidgetText.resultWord(vote) == "NO ONE ELECTED")
        #expect(WidgetText.resultLine(vote) == "Jeffries led 212")
        #expect(WidgetText.citation(vote, measure: nil) == "Speaker ballot")
        let score = WidgetText.score(vote)
        #expect(score.left == .init(value: 212, label: "Jeffries", side: nil))
        #expect(score.right == .init(value: 201, label: "McCarthy", side: nil))
    }

    @Test func aOneCandidateBallotHasNoRightHandScore() {
        var vote = Vote.sampleElection
        vote.candidates = [Candidate(name: "Johnson", total: 220)]
        #expect(WidgetText.score(vote).left == .init(value: 220, label: "Johnson", side: nil))
        #expect(WidgetText.score(vote).right == nil)
    }

    @Test func aSnapshotSaysHowOldItIsOnlyPastTwoHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let fetchedAt = Date(timeIntervalSince1970: 1_794_528_000) // Nov 12, 7 PM in New York
        #expect(WidgetText.asOf(fetchedAt, now: fetchedAt.addingTimeInterval(60 * 60), calendar: calendar) == nil)
        #expect(WidgetText.asOf(fetchedAt, now: fetchedAt.addingTimeInterval(2 * 60 * 60), calendar: calendar) == nil)
        let sameDay = try #require(WidgetText.asOf(fetchedAt, now: fetchedAt.addingTimeInterval(3 * 60 * 60 + 60), calendar: calendar))
        #expect(sameDay.hasPrefix("As of ") && !sameDay.contains("Nov"))
        let nextDay = WidgetText.asOf(fetchedAt, now: fetchedAt.addingTimeInterval(30 * 60 * 60), calendar: calendar)
        #expect(nextDay?.hasPrefix("As of Nov") == true)
    }

    @Test func aSpeakerBallotThatElectedSomeone() {
        var vote = Vote.sampleElection
        vote.candidates = [Candidate(name: "McCarthy", total: 216), Candidate(name: "Jeffries", total: 212)]
        #expect(WidgetText.resultWord(vote) == "ELECTED")
        #expect(WidgetText.resultLine(vote) == "McCarthy elected 216")
    }

    @Test func aProceduralVoteIsNamedByItsQuestion() {
        var vote = Vote.sample
        vote.question = "On Motion to Adjourn"
        #expect(WidgetText.citation(vote, measure: nil) == "Adjourn")
    }

    @Test func headersForEveryShapeOfDelegation() throws {
        #expect(WidgetText.header(members: Delegation.sampleTX37.members, district: Delegation.sampleTX37.district)
            == "Your three · TX-37")

        let dc = try fixture("reps-location-dc", as: Reps.self)
        #expect(WidgetText.header(members: dc.members, district: dc.district) == "Your delegate · DC")

        let pr = Member(bioguideId: "H001103", firstName: "Pablo José", lastName: "Hernández", party: "D",
                        state: "PR", district: 0, chamber: .house)
        #expect(WidgetText.header(members: [pr], district: District(congress: 119, state: "PR", district: 0, countyFips: nil))
            == "Your resident commissioner · PR")

        let wy = try fixture("reps-location-cheyenne", as: Reps.self)
        #expect(WidgetText.header(members: wy.members, district: wy.district) == "Your three · WY-AL")

        // A vacant Senate seat.
        #expect(WidgetText.header(members: Array(Delegation.sampleTX37.members.prefix(2)), district: Delegation.sampleTX37.district)
            == "Your two · TX-37")
    }

    @Test func aLoneDelegateSaysWhy() throws {
        let dc = try fixture("reps-location-dc", as: Reps.self)
        let snapshot = WidgetSnapshot.make(delegation: Delegation(reps: dc), records: [:], fetchedAt: fetched)
        #expect(WidgetText.loneMemberNote(snapshot)
            == "District of Columbia has no senators. Delegates vote on amendments, not on passage.")
        #expect(WidgetText.loneMemberNote(.sample) == nil)
    }

    @Test func voiceOverReadsTheWholeCard() throws {
        let final = try #require(WidgetSnapshot.sample.latestFinal)
        #expect(WidgetText.smallLabel(final)
            == "Latest final, House. H.R. 1013. Passed, 295 to 128. Doggett voted nay.")
        let cornyn = WidgetSnapshot.sample.rows[1]
        #expect(WidgetText.rowLabel(cornyn).hasPrefix("Cornyn did not vote on H.R. 2347, Agreed 62 to 21, "))
    }
}

@Suite("Widget store")
struct WidgetSnapshotStoreTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "floor.tests.\(UUID().uuidString)"))
    }

    @Test func roundTripsForTheSameDelegation() throws {
        let store = WidgetSnapshotStore(defaults: try defaults())
        #expect(store.load(for: .sampleTX37) == nil)
        store.save(.sample)
        #expect(store.load(for: .sampleTX37) == WidgetSnapshot.sample)
        store.clear()
        #expect(store.load(for: .sampleTX37) == nil)
    }

    /// After "Change address", the old district's votes must not be shown for the new one.
    @Test func ignoresASnapshotForAnotherDelegation() throws {
        let store = WidgetSnapshotStore(defaults: try defaults())
        store.save(.sample)
        #expect(store.load(for: .sample) == nil)
    }
}

/// Serialized because the stub keeps its responder in shared state.
@Suite("Widget feed", .serialized)
struct WidgetFeedLoadTests {
    @Test func asksEachMemberForTenVotesThroughTheAppsRoute() async throws {
        let session = WidgetStub.session { request in
            let path = request.url!.path
            let name = path.contains("D000399") ? "doggett" : path.contains("C001056") ? "cornyn" : "cruz"
            return (200, try! WidgetStub.fixtureData("member-votes-\(name)-40"))
        }
        let api = FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: session)

        let snapshot = try await WidgetFeed.load(delegation: .sampleTX37, api: api, now: fetched)
        #expect(snapshot.latestFinal == WidgetSnapshot.sample.latestFinal)
        #expect(snapshot.rows == WidgetSnapshot.sample.rows)

        let urls = WidgetStub.requests.compactMap(\.url).map(\.absoluteString).sorted()
        #expect(urls == [
            "https://api.example.test/v1/members/C001056/votes?limit=10",
            "https://api.example.test/v1/members/C001098/votes?limit=10",
            "https://api.example.test/v1/members/D000399/votes?limit=10",
        ])
    }

    /// "Change address" while a refresh is in flight: the old district's votes must not be saved
    /// back into the group the app just cleared, nor shown.
    @Test func aRefreshOvertakenByChangeAddressSavesNothing() async throws {
        let session = WidgetStub.session { request in
            let path = request.url!.path
            let name = path.contains("D000399") ? "doggett" : path.contains("C001056") ? "cornyn" : "cruz"
            return (200, try! WidgetStub.fixtureData("member-votes-\(name)-40"))
        }
        let api = FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: session)
        let store = WidgetSnapshotStore(defaults: try #require(UserDefaults(suiteName: "floor.tests.\(UUID())")))
        let source = DelegationSource([.sampleTX37, nil]) // there when asked, gone when the votes land

        let result = await WidgetFeed.refresh(delegation: { source.next() }, api: api, store: store, now: fetched)
        #expect(result == .noDistrict)
        #expect(store.load(for: .sampleTX37) == nil)

        // A different district by the time the votes land is dropped too.
        var elsewhere = Delegation.sampleTX37
        elsewhere.district.district = 35
        let moved = DelegationSource([.sampleTX37, elsewhere])
        #expect(await WidgetFeed.refresh(delegation: { moved.next() }, api: api, store: store, now: fetched) == .noDistrict)
        #expect(store.load(for: .sampleTX37) == nil)
    }

    @Test func aRefreshSavesAndAFailedOneFallsBackToIt() async throws {
        let store = WidgetSnapshotStore(defaults: try #require(UserDefaults(suiteName: "floor.tests.\(UUID())")))
        let good = WidgetStub.session { request in
            let path = request.url!.path
            let name = path.contains("D000399") ? "doggett" : path.contains("C001056") ? "cornyn" : "cruz"
            return (200, try! WidgetStub.fixtureData("member-votes-\(name)-40"))
        }
        let base = URL(string: "https://api.example.test")!
        let fresh = await WidgetFeed.refresh(delegation: { .sampleTX37 }, api: FloorAPI(baseURL: base, session: good),
                                             store: store, now: fetched)
        guard case let .fresh(snapshot) = fresh else { Issue.record("expected fresh, got \(fresh)"); return }
        #expect(fresh.retryAfter == 30 * 60)

        let down = WidgetStub.session { _ in (503, Data(#"{"error":"down"}"#.utf8)) }
        let fallback = await WidgetFeed.refresh(delegation: { .sampleTX37 }, api: FloorAPI(baseURL: base, session: down),
                                                store: store)
        #expect(fallback == .saved(snapshot))
        #expect(fallback.retryAfter == 15 * 60)

        store.clear()
        #expect(await WidgetFeed.refresh(delegation: { .sampleTX37 }, api: FloorAPI(baseURL: base, session: down),
                                         store: store) == .failed)
        #expect(await WidgetFeed.refresh(delegation: { nil }, api: FloorAPI(baseURL: base, session: down),
                                         store: store) == .noDistrict)
    }

    @Test func theWidgetSessionGivesUpQuicklyAndCachesNothing() {
        let configuration = WidgetFeed.makeSession().configuration
        #expect(configuration.timeoutIntervalForRequest == 12)
        #expect(configuration.urlCache == nil)
    }

    @Test func oneMemberFailingFailsTheLoad() async throws {
        let session = WidgetStub.session { request in
            request.url!.path.contains("C001098")
                ? (500, Data(#"{"error":"boom"}"#.utf8))
                : (200, Data(#"{"votes":[]}"#.utf8))
        }
        let api = FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: session)
        await #expect(throws: FloorAPIError.self) {
            _ = try await WidgetFeed.load(delegation: .sampleTX37, api: api)
        }
    }
}

/// Hands out a fixed sequence of delegations, one per read, then repeats the last.
final class DelegationSource: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Delegation?]

    init(_ queue: [Delegation?]) { self.queue = queue }

    func next() -> Delegation? {
        lock.lock()
        defer { lock.unlock() }
        return queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
    }
}

/// A minimal `URLProtocol` stub, like APIClientTests' `StubURLProtocol`.
final class WidgetStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func session(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        lock.lock()
        self.handler = handler
        seen = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetStub.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func fixtureData(_ name: String) throws -> Data {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        return try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
