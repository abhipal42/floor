import Foundation
import Testing
@testable import LiveActivity
import Models

func fixtureData(_ name: String) throws -> Data {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // LiveActivityTests
    dir.deleteLastPathComponent() // Tests
    return try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
}

/// The system's time formats put a narrow no-break space before "PM"; the expectations type a space.
func plain(_ text: String?) -> String? {
    text?.replacingOccurrences(of: "\u{202F}", with: " ")
}

func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: try fixtureData(name))
}

/// H.R. 1013 on Nov 11, 2026: House roll call 321, opened 2:43 PM Eastern, passed 295–128 with 10
/// not voting; Doggett (TX-37) voted nay. The fixtures are what the worker sends (its own tests
/// check it builds exactly these), so decoding them here is the contract.
enum HR1013 {
    static let eastern = TimeZone(identifier: "America/New_York")!
    static var attributes: VoteActivityAttributes { get throws { try fixture("live-activity-attributes-hr1013", as: VoteActivityAttributes.self) } }
    static var open: VoteActivityAttributes.ContentState { get throws { try fixture("live-activity-open-hr1013", as: VoteActivityAttributes.ContentState.self) } }
    static var final: VoteActivityAttributes.ContentState { get throws { try fixture("live-activity-final-hr1013", as: VoteActivityAttributes.ContentState.self) } }

    static let doggett = Member(bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX", district: 37, chamber: .house)
    static let cornyn = Member(bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX", district: nil, chamber: .senate)
    static let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: nil, chamber: .senate)

    static func live(state: VoteState) -> LiveVote {
        LiveVote(
            vote: Vote(
                id: "house-119-2-321", kind: .question, chamber: .house, congress: 119, session: 2, rollNumber: 321,
                question: "On Passage", billId: nil, nominationId: nil, billRef: "H R 1013",
                occurredAt: "2026-11-11T19:43:00.000Z", state: state, threshold: .majority,
                totals: state == .final ? VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10) : VoteTotals(yea: 0, nay: 0, present: 0, notVoting: 0),
                candidates: [], result: state == .final ? "Passed" : nil
            ),
            openedAt: "2026-11-11T19:43:00.000Z", announcedAt: "2026-11-11T19:43:30.000Z",
            postedAt: state == .final ? "2026-11-11T19:52:00.000Z" : nil,
            measure: MeasureSummary(
                id: "119-hr-1013", kind: .bill, citation: "H.R. 1013",
                title: "Retirement Fairness for Charities and Educational Institutions Act of 2025"
            )
        )
    }
}

@Suite("Live Activity attributes and state")
struct VoteActivityTests {
    @Test func decodesWhatTheWorkerSends() throws {
        let a = try HR1013.attributes
        #expect(a.voteId == "house-119-2-321")
        #expect(a.citation == "H.R. 1013")
        #expect(a.threshold == .majority)
        let open = try HR1013.open
        #expect(open.state == .open)
        #expect(open.totals == nil)
        #expect(open.members == [VoteActivityAttributes.Call(id: "D000399", name: "Doggett", position: nil, choice: nil)])
        let final = try HR1013.final
        #expect(final.totals == VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10))
        #expect(final.members.first?.position == .nay)
    }

    @Test func buildsTheSameHalvesLocallyAsTheWorkerDoes() throws {
        #expect(VoteActivityAttributes(live: HR1013.live(state: .open)) == (try HR1013.attributes))
        #expect(VoteActivityAttributes.ContentState(live: HR1013.live(state: .open), members: [HR1013.doggett]) == (try HR1013.open))
        let positions = [MemberPosition(member: HR1013.doggett, position: .nay, choice: nil)]
        #expect(
            VoteActivityAttributes.ContentState(live: HR1013.live(state: .final), members: [HR1013.doggett], positions: positions)
                == (try HR1013.final)
        )
    }

    @Test func roundTripsThroughJSONWithExplicitNulls() throws {
        let state = try HR1013.open
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(VoteActivityAttributes.ContentState.self, from: data) == state)
    }

    @Test func listsThreeMembersAndCountsTheRest() {
        let five = (1...5).map { (i: Int) in Member(bioguideId: "X00000\(i)", firstName: "A", lastName: "M\(i)", party: "D", state: "TX", district: i, chamber: .house) }
        let content = VoteActivityAttributes.ContentState(live: HR1013.live(state: .open), members: five)
        #expect(content.members.map(\.name) == ["M1", "M2", "M3"])
        #expect(content.moreMembers == 2)
        #expect(VoteActivityText.more(content) == "+2 more of your members")
    }

    @Test func neverShowsAPositionWhileTheVoteIsOpen() {
        let positions = [MemberPosition(member: HR1013.doggett, position: .yea, choice: nil)]
        let content = VoteActivityAttributes.ContentState(live: HR1013.live(state: .open), members: [HR1013.doggett], positions: positions)
        #expect(content.members.first?.position == nil)
    }

    @Test func readsAPre030LiveVoteWithNoMeasure() throws {
        let live = try fixture("live", as: Live.self)
        #expect(live.votes.allSatisfy { $0.measure == nil })
        #expect(VoteActivityAttributes(live: live.votes[0]).citation == nil)
    }
}

@Suite("Live Activity words")
struct VoteActivityTextTests {
    @Test func openStateReadsAsTheMock() throws {
        let (a, c) = (try HR1013.attributes, try HR1013.open)
        #expect(VoteActivityText.header(a) == "House · Roll call 321")
        #expect(VoteActivityText.status(c) == "Vote open")
        #expect(VoteActivityText.headline(a, c) == "H.R. 1013 · On Passage")
        #expect(VoteActivityText.detail(a, c) == "Retirement Fairness for Charities and Educational Institutions Act of 2025")
        #expect(VoteActivityText.needs(a) == "Needs a majority")
        #expect(plain(VoteActivityText.opened(c, timeZone: HR1013.eastern)) == "Opened 2:43 PM")
        #expect(VoteActivityText.line(c.members[0], a, c, alone: true) == "Doggett hasn't been recorded yet")
        #expect(VoteActivityText.chip(c.members[0]) == "…")
        #expect(VoteActivityText.compactTrailing(c) == "OPEN")
    }

    @Test func finalStateReadsAsTheMock() throws {
        let (a, c) = (try HR1013.attributes, try HR1013.final)
        #expect(VoteActivityText.status(c) == "Final")
        #expect(VoteActivityText.headline(a, c) == "H.R. 1013 · Passed")
        #expect(VoteActivityText.detail(a, c) == nil)
        #expect(VoteActivityText.absentees(c) == "10 not voting")
        #expect(VoteActivityText.chip(c.members[0]) == "NAY")
        #expect(VoteActivityText.line(c.members[0], a, c, alone: true) == "Doggett voted nay · on the losing side")
        #expect(VoteActivityText.line(c.members[0], a, c, alone: true, long: false) == "Doggett voted nay")
        #expect(VoteActivityText.compactTrailing(c) == "295–128")
    }

    @Test func aSenateVoteListsBothSenatorsAndUsesWhenItWasCalled() {
        var live = HR1013.live(state: .open)
        live.vote.chamber = .senate
        live.vote.rollNumber = nil
        live.openedAt = nil
        live.vote.question = "Motion to Proceed"
        live.measure = MeasureSummary(id: "119-hr-2347", kind: .bill, citation: "H.R. 2347", title: "A bill")
        let a = VoteActivityAttributes(live: live)
        let c = VoteActivityAttributes.ContentState(live: live, members: [HR1013.cornyn, HR1013.cruz])
        #expect(VoteActivityText.header(a) == "Senate · Floor")
        #expect(VoteActivityText.headline(a, c) == "H.R. 2347 · Motion to Proceed")
        #expect(plain(VoteActivityText.opened(c, timeZone: HR1013.eastern)) == "Called 2:43 PM")
        #expect(c.members.map { VoteActivityText.line($0, a, c, alone: false) } == ["Cornyn not recorded yet", "Cruz not recorded yet"])
    }

    @Test func namesTheWinningSideAndTheThreshold() throws {
        var a = try HR1013.attributes
        let c = try HR1013.final
        let yea = VoteActivityAttributes.Call(id: "H001096", name: "Hageman", position: .yea, choice: nil)
        let absent = VoteActivityAttributes.Call(id: "X", name: "Absent", position: .notVoting, choice: nil)
        #expect(VoteActivityText.line(yea, a, c, alone: false) == "Hageman voted yea · on the winning side")
        #expect(VoteActivityText.line(absent, a, c, alone: false) == "Absent did not vote")
        a.threshold = .threeFifthsSworn
        #expect(VoteActivityText.needs(a) == "Needs 60 of 100")
        a.threshold = .twoThirds
        #expect(VoteActivityText.needs(a) == "Needs two-thirds")
    }

    @Test func speaksOutcomeFirst() throws {
        let (a, open, final) = (try HR1013.attributes, try HR1013.open, try HR1013.final)
        #expect(VoteActivityText.spoken(a, final, timeZone: HR1013.eastern)
            == "House roll call 321, H.R. 1013 passed, 295 yea to 128 nay. 10 not voting. Doggett voted nay, on the losing side.")
        #expect(plain(VoteActivityText.spoken(a, open, timeZone: HR1013.eastern))
            == "House roll call 321, H.R. 1013, On Passage, vote open. Needs a majority. Opened 2:43 PM. Doggett hasn't been recorded yet.")
    }
}

// MARK: - The foreground poller

final class StubSource: LiveSource, @unchecked Sendable {
    var live: Live
    var positions: [MemberPosition] = []
    var positionCalls: [[String]] = []
    var liveCalls = 0
    /// What `voteDetail` answers; nil throws, as offline would.
    var detail: VoteDetail?
    var detailFails = false
    init(_ live: Live) { self.live = live }
    func liveNow() async throws -> Live {
        liveCalls += 1
        return live
    }
    func voteDetail(id: String, members: [String]) async throws -> VoteDetail {
        positionCalls.append(members)
        if detailFails { throw URLError(.notConnectedToInternet) }
        if let detail { return detail }
        let vote = live.votes.first { $0.id == id }!.vote
        return VoteDetail(vote: vote, partyTotals: [], candidateTotals: [], positions: positions, measure: nil)
    }
}

@MainActor
final class FakeHost: ActivityHost {
    var enabled = true
    var shown: [String: VoteActivityAttributes.ContentState] = [:]
    var log: [String] = []
    var ended: [String: (VoteActivityAttributes.ContentState, Date)] = [:]

    func running() -> [String: VoteActivityAttributes.ContentState] { shown }
    func start(_ attributes: VoteActivityAttributes, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async throws {
        log.append("start \(attributes.voteId)")
        shown[attributes.voteId] = content
    }
    func update(voteId: String, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async {
        log.append("update \(voteId)")
        shown[voteId] = content
    }
    func end(voteId: String, _ content: VoteActivityAttributes.ContentState, dismissAt: Date) async {
        log.append("end \(voteId)")
        shown[voteId] = nil
        ended[voteId] = (content, dismissAt)
    }
}

@MainActor
@Suite("LiveActivityCoordinator")
struct LiveActivityCoordinatorTests {
    let now = Formats.instant("2026-11-11T19:45:00.000Z")!

    func coordinator(_ source: StubSource, _ host: FakeHost, interest: LiveActivityCoordinator.Interest) -> LiveActivityCoordinator {
        LiveActivityCoordinator(source: source, host: host, now: { [now] in now }) { interest }
    }

    @Test func startsAnOpenVoteInvolvingYourMembersOnlyWithAVoteOpenedOn() async {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .open)]))
        let host = FakeHost()
        await coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: false)).poll()
        #expect(host.log.isEmpty)
        await coordinator(source, host, interest: .init(members: [HR1013.cornyn], bills: [], liveActivities: true)).poll()
        #expect(host.log.isEmpty, "a senator is not on a House vote")
        await coordinator(source, host, interest: .init(members: [HR1013.doggett, HR1013.cornyn], bills: [], liveActivities: true)).poll()
        #expect(host.log == ["start house-119-2-321"])
        #expect(host.shown["house-119-2-321"]?.members.map(\.name) == ["Doggett"])
    }

    @Test func startsForAFollowedBillAndNotWhenActivitiesAreOff() async {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .open)]))
        let host = FakeHost()
        host.enabled = false
        let c = coordinator(source, host, interest: .init(members: [], bills: ["119-hr-1013"], liveActivities: true))
        await c.poll()
        #expect(host.log.isEmpty)
        host.enabled = true
        await c.poll()
        #expect(host.log == ["start house-119-2-321"])
        #expect(host.shown["house-119-2-321"]?.members.isEmpty == true)
    }

    @Test func doesNotRestartOneTheUserDismissed() async {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .open)]))
        let host = FakeHost()
        let c = coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: true))
        await c.poll()
        host.shown = [:] // swiped away
        await c.poll()
        #expect(host.log == ["start house-119-2-321"])
    }

    @Test func doesNotRestartOneThePushStartedAndTheUserDismissed() async throws {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .open)]))
        let host = FakeHost()
        host.shown["house-119-2-321"] = try HR1013.open // started by push while the app was closed
        let c = coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: true))
        await c.poll()
        host.shown = [:]
        await c.poll()
        #expect(host.log.isEmpty)
    }

    @Test func endsWithTheFinalAndYourMembersPositions15MinutesAfterItPosted() async throws {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .open)]))
        let host = FakeHost()
        // "A vote opened" off: an activity already running (started by push) is still finished.
        let c = coordinator(source, host, interest: .init(members: [HR1013.doggett, HR1013.cruz], bills: [], liveActivities: false))
        host.shown["house-119-2-321"] = try HR1013.open
        await c.poll()
        #expect(host.log.isEmpty, "nothing changed while open")
        source.live = Live(chambers: [], votes: [HR1013.live(state: .final)])
        source.positions = [MemberPosition(member: HR1013.doggett, position: .nay, choice: nil)]
        await c.poll()
        #expect(host.log == ["end house-119-2-321"])
        #expect(source.positionCalls == [["D000399"]])
        let (content, dismiss) = try #require(host.ended["house-119-2-321"])
        #expect(content == (try HR1013.final))
        #expect(dismiss == Formats.instant("2026-11-11T20:07:00.000Z"))
    }

    @Test func keepsTheActivityWhenPositionsCannotBeFetchedAndEndsItNextPoll() async throws {
        let source = StubSource(Live(chambers: [], votes: [HR1013.live(state: .final)]))
        let host = FakeHost()
        host.shown["house-119-2-321"] = try HR1013.open
        let c = coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: true))
        source.detailFails = true
        await c.poll()
        #expect(host.log.isEmpty, "not ended on 'not recorded yet'")
        source.detailFails = false
        source.positions = [MemberPosition(member: HR1013.doggett, position: .nay, choice: nil)]
        await c.poll()
        #expect(host.log == ["end house-119-2-321"])
        #expect(host.ended["house-119-2-321"]?.0.members.first?.position == .nay)
    }

    @Test func endsAnActivityWhoseVoteHasLeftTheLiveView() async throws {
        let source = StubSource(Live(chambers: [], votes: []))
        let host = FakeHost()
        host.shown["house-119-2-321"] = try HR1013.open
        source.detail = VoteDetail(
            vote: HR1013.live(state: .final).vote, partyTotals: [], candidateTotals: [],
            positions: [MemberPosition(member: HR1013.doggett, position: .nay, choice: nil)], measure: nil
        )
        await coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: true)).poll()
        #expect(host.log == ["end house-119-2-321"])
        let (content, dismiss) = try #require(host.ended["house-119-2-321"])
        #expect(content.totals?.yea == 295)
        #expect(content.members.first?.position == .nay)
        #expect(dismiss == now)
    }

    @Test func asksForNothingWhenNothingCouldStartOrIsRunningAndBacksOffWhenNeitherChamberSits() async {
        let source = StubSource(Live(chambers: [], votes: []))
        let host = FakeHost()
        let off = coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: false))
        #expect(await off.poll() == LiveActivityCoordinator.interval)
        #expect(source.liveCalls == 0)
        let on = coordinator(source, host, interest: .init(members: [HR1013.doggett], bills: [], liveActivities: true))
        #expect(await on.poll() == LiveActivityCoordinator.idleInterval)
        source.live = Live(chambers: [ChamberStatus(chamber: .house, inSession: true, convenesAt: nil, legislativeDay: nil, checkedAt: "x")], votes: [])
        #expect(await on.poll() == LiveActivityCoordinator.interval)
        #expect(source.liveCalls == 2)
    }

    @Test func listsMembersBySurnameAsTheWorkerDoes() {
        let content = VoteActivityAttributes.ContentState(live: HR1013.live(state: .open), members: [HR1013.doggett, HR1013.cruz, HR1013.cornyn])
        #expect(content.members.map(\.name) == ["Cornyn", "Cruz", "Doggett"])
    }

    @Test func dismissesAtOnceWhenTheFinalWasLongAgo() {
        let late = Formats.instant("2026-11-11T22:00:00.000Z")!
        #expect(LiveActivityCoordinator.dismissal(HR1013.live(state: .final), now: late) == late)
    }
}
