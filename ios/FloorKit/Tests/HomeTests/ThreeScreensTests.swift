import Foundation
import Models
import Onboarding
import Testing
@testable import Home

/// v0.2.59's pure logic, on the shared captures: `/v1/votes` as production served it on 2026-11-17
/// (`votes-recent-40-2026-11-17.json`, each bill's stage from `/v1/bills/{id}` that day) and the
/// week of Nov 16 as `/v1/schedule` served it the same day (`schedule-2026-11-16-at-2026-11-17.json`).
@Suite("Catch up, Week and Bills (v0.2.59)")
struct ThreeScreensTests {
    private static func fixture<T: Decodable>(_ name: String) throws -> T {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private static func feed() throws -> [FeedItem] {
        let rows: RecentVotes = try fixture("votes-recent-40-2026-11-17")
        return rows.votes.map { FeedItem(vote: $0.vote, measure: $0.measure, positions: [], partyTotals: $0.partyTotals) }
    }

    private static func week() throws -> Schedule { try fixture("schedule-2026-11-16-at-2026-11-17") }

    private static var eastern: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func card(_ id: String, in cards: [LedgerCard]) throws -> LedgerCard {
        try #require(cards.first { $0.id == id })
    }

    // MARK: - Bills: the rule fold

    @Test func aRuleFoldsIntoItsBillWithEachDaysScores() throws {
        let cards = BillsLedger.cards(try Self.feed())
        // H.Res. 1247 and H.Res. 1650 bring up H.R. 2102 and H.R. 1013, both in the list: no cards of their own.
        #expect(!cards.contains { $0.id == "119-hres-1247" || $0.id == "119-hres-1650" })
        let star = try card("119-hr-2102", in: cards)
        #expect(star.title == "Major Richard Star Act")
        #expect(star.latest.vote.id == "house-119-2-323")
        #expect(star.rules.map(\.vote.id) == ["house-119-2-322", "house-119-2-320"])
        #expect(BillsLedger.ruleLine(star.rules, calendar: Self.eastern) == "+ Rule adopted 271–135, Nov 12 · 245–175, Nov 11")
        let charities = try card("119-hr-1013", in: cards)
        #expect(BillsLedger.ruleLine(charities.rules, calendar: Self.eastern) == "+ Rule adopted 215–209 · 213–207, Nov 10")
        // A House resolution that is not a rule keeps its own card.
        #expect(try card("119-hres-1655", in: cards).ruleFor == nil)
        #expect(cards.count == 13)
    }

    @Test func aRuleWhoseBillIsNotListedKeepsACardNamedForTheBill() throws {
        let feed = try Self.feed().filter { $0.measure?.id != "119-hr-2102" }
        let rule = try card("119-hres-1247", in: BillsLedger.cards(feed))
        #expect(rule.ruleFor == "H.R. 2102")
        #expect(rule.title == "Rule for H.R. 2102")
        #expect(rule.summary == nil)
        #expect(rule.track == nil)
        #expect(rule.rules.isEmpty)
    }

    @Test func theFooterSaysTheKindAndTheSplit() throws {
        let cards = BillsLedger.cards(try Self.feed())
        let star = try card("119-hr-2102", in: cards)
        #expect(BillsLedger.kindLine(star.latest.vote) == "Passed House")
        #expect(BillsLedger.partyLine(star.latest.partyTotals) == "R 182–18 · D 210–0")
        let ratepayer = try card("119-hr-9340", in: cards)
        #expect(BillsLedger.kindLine(ratepayer.latest.vote) == "Cloture")
        #expect(BillsLedger.partyLine(ratepayer.latest.partyTotals) == "R 53–0 · D 4–41 · I 0–2")
        // H.Res. 1655's motion to refer is recorded "Passed": still a motion, not a passage.
        #expect(BillsLedger.kindLine(try card("119-hres-1655", in: cards).latest.vote) == "Motion to refer")
        #expect(BillsLedger.citation(billId: "119-sjres-197") == "S.J.Res. 197")
        #expect(BillsLedger.citation(billId: "119-pn-999-2") == nil)
    }

    // MARK: - Bills: the filter and the sections

    @Test func passedAndBlockedFilterOnTheLatestVote() throws {
        let feed = try Self.feed()
        let blocked = BillsLedger.sections(feed, filter: .blocked).flatMap(\.cards).map(\.id)
        #expect(Set(blocked) == ["119-hr-9340", "119-hr-7008", "119-sres-852", "119-sjres-197", "119-hconres-89"])
        let passed = BillsLedger.sections(feed, filter: .passed).flatMap(\.cards).map(\.id)
        #expect(passed.count == 8)
        #expect(Set(passed).isDisjoint(with: blocked))
        #expect(passed.contains("119-s-4668"))
        #expect(BillsLedger.sections(feed, filter: .all).flatMap(\.cards).count == 13)
        #expect(!BillsFilter.passed.admits(nil))
        #expect(BillsFilter.all.admits(nil))
    }

    @Test func sectionsGoInTheOrderOfTheirMostRecentVote() throws {
        let sections = BillsLedger.sections(try Self.feed(), filter: .all)
        #expect(sections.prefix(4).map(\.group) == [.defense, .money, .other, .land])
        #expect(sections[1].cards.map(\.id) == ["119-hr-1013", "119-hr-2347", "119-s-2403"])
        #expect(TopicGroup.defense.name == "Defense")
    }

    // MARK: - Bills: the track

    private func labels(_ track: BillTrack?) -> [String] { track?.steps.map(\.label) ?? [] }
    private func states(_ track: BillTrack?) -> [BillTrack.State] { track?.steps.map(\.state) ?? [] }

    @Test func aHouseBillThatPassedTheHouse() throws {
        let track = try card("119-hr-2102", in: BillsLedger.cards(try Self.feed())).track
        #expect(labels(track) == ["Introduced", "House ✓", "Senate", "Law"])
        #expect(states(track) == [.done, .current, .upcoming, .upcoming])
        #expect(track?.spoken == "Passed the House; next, the Senate")
    }

    @Test func senateBillsGoThroughTheSenateFirst() throws {
        let cards = BillsLedger.cards(try Self.feed())
        let law = try card("119-s-2403", in: cards).track
        #expect(labels(law) == ["Introduced", "Senate ✓", "House ✓", "Law ✓"])
        #expect(states(law) == [.done, .done, .done, .current])
        #expect(law?.spoken == "Passed the Senate and the House; became law")
        let passed = try card("119-s-4668", in: cards).track
        #expect(states(passed) == [.done, .current, .upcoming, .upcoming])
        #expect(passed?.spoken == "Passed the Senate; next, the House")
    }

    @Test func resolutionsAndAFailedConcurrentOne() throws {
        let cards = BillsLedger.cards(try Self.feed())
        let simple = try card("119-sres-852", in: cards).track
        #expect(labels(simple) == ["Introduced", "Adopted"])
        #expect(states(simple) == [.current, .upcoming])
        #expect(simple?.spoken == "Introduced; next, adoption")
        // H.Con.Res. 89 failed in the Senate: the House step before it is done.
        let failed = try card("119-hconres-89", in: cards).track
        #expect(labels(failed) == ["Introduced", "House ✓", "Failed", "Adopted"])
        #expect(states(failed) == [.done, .done, .stopped, .upcoming])
        #expect(failed?.spoken == "Passed the House; failed in the Senate")
        let adopted = BillTrack(billId: "119-hres-1247", stage: .adopted, lastChamber: .house)
        #expect(states(adopted) == [.done, .current])
        #expect(adopted?.spoken == "Adopted")
    }

    @Test func vetoedToThePresidentAndUnstaged() throws {
        let vetoed = BillTrack(billId: "119-hr-1", stage: .vetoed, lastChamber: .senate)
        #expect(labels(vetoed) == ["Introduced", "House ✓", "Senate ✓", "Vetoed"])
        #expect(states(vetoed) == [.done, .done, .done, .stopped])
        #expect(vetoed?.spoken == "Passed the House and the Senate; vetoed")
        let sent = BillTrack(billId: "119-hjres-5", stage: .toPresident, lastChamber: .senate)
        #expect(states(sent) == [.done, .done, .current, .upcoming])
        #expect(sent?.spoken == "Passed the House and the Senate; next, the President")
        #expect(BillTrack(billId: "119-pn-999-2", stage: .introduced, lastChamber: nil) == nil)
        // No stage, no track.
        var feed = try Self.feed()
        for i in feed.indices { feed[i].measure?.stage = nil }
        #expect(BillsLedger.cards(feed).allSatisfy { $0.track == nil })
    }

    // MARK: - Week: headliners

    @Test func aLegislativeVehicleHeadlinesWhatItCarries() throws {
        let heads = WeekPlan.headliners(try Self.week(), state: FollowState(), votes: try Self.feed(), calendar: Self.eastern)
        #expect(heads.map(\.item.label) == ["H.R. 2347", "H.R. 3495", "H.R. 5267"])
        let senate = heads[0]
        #expect(senate.chamber == .senate)
        #expect(senate.headline == "Bipartisan American Affordability and Jobs Act")
        #expect(senate.context == "Riding on Survivor Justice Tax Prevention Act.")
        // The two latest votes on H.R. 2347 the feed has, both before this week, so dated.
        #expect(senate.chips == ["Nov 10 ✓ motion to take it up 62–21", "Nov 9 ✓ cloture to take it up 73–25"])
        #expect(!senate.followed)
    }

    @Test func houseRuleBillsSayWhichRuleAndWhatElseItBringsUp() throws {
        let heads = WeekPlan.headliners(try Self.week(), state: FollowState(), votes: [], calendar: Self.eastern)
        #expect(heads[1].chamber == .house)
        #expect(heads[1].headline == "Direct Seller and Real Estate Agent Harmonization Act")
        #expect(heads[1].context == "Up under a rule (H.Res. 1665) with American Franchise Act.")
        #expect(heads[2].context == "Up under a rule (H.Res. 1665) with Direct Seller and Real Estate Agent Harmonization Act.")
        #expect(heads.allSatisfy { $0.chips.isEmpty })
        var state = FollowState()
        state.follow(topic: "Labor and Employment")
        let followed = WeekPlan.headliners(try Self.week(), state: state, votes: [], calendar: Self.eastern)
        #expect(followed.map(\.followed) == [false, true, true])
    }

    @Test func noVehicleMeansTheProgramsOwnSentence() throws {
        let program = try #require(try Self.week().senate?.meetings.first?.program)
        #expect(WeekPlan.vehicleName(of: "H.R. 2347", in: program) == "Bipartisan American Affordability and Jobs Act")
        #expect(WeekPlan.vehicleName(of: "H.R. 9999", in: program) == nil)
        #expect(WeekPlan.vehicleName(of: "H.R. 1", in: "Senate will consider H.R. 1, the Act (a bill).") == nil)
        let sentences = WeekPlan.sentences(program)
        #expect(sentences.count == 2)
        #expect(sentences[0].hasSuffix("vote on confirmation thereon at 5:30 p.m."))
        #expect(sentences[1].hasPrefix("Following disposition of the nomination of Daniel Desmond Domenico"))
        #expect(WeekPlan.sentences("Vote on Anna St. John. Then H.R. 2347 (Amendment No. 6883). Done.").count == 3)
        var week = try Self.week()
        week.senate?.meetings = [SenateMeeting(
            date: "2026-11-18", convenesAt: nil, proForma: false, heading: nil,
            program: "Senate will begin consideration of H.R. 2347, Survivor Justice Tax Prevention Act. At noon, it will vote.",
            recordIssue: nil
        )]
        let head = try #require(WeekPlan.headliners(week, state: FollowState(), votes: [], calendar: Self.eastern).first)
        #expect(head.headline == "Survivor Justice Tax Prevention Act")
        #expect(head.context == "Senate will begin consideration of H.R. 2347, Survivor Justice Tax Prevention Act.")
    }

    // MARK: - Week: fast track, summary, Senate next

    @Test func fastTrackTilesByTopicFamilyMostFirst() throws {
        let rows = WeekPlan.fastTrack(try Self.week(), state: FollowState())
        #expect(rows.count == 13)
        let tiles = WeekPlan.tiles(rows)
        #expect(tiles.map(\.group) == [.land, .rights, .defense, .money, .gov])
        #expect(tiles.map(\.count) == [6, 4, 1, 1, 1])
        #expect(WeekPlan.rows(rows, in: .rights).map(\.item.label) == ["H.R. 7954", "H.R. 8483", "H.R. 9269", "H.R. 2400"])
        #expect(WeekPlan.rows(rows, in: nil).count == 13)
        // A pulled bill stays in its family's rows but leaves the count.
        var week = try Self.week()
        let i = try #require(week.house.items.firstIndex { $0.label == "H.R. 7934" })
        week.house.items[i].removedAt = "2026-11-17T12:00:00.000Z"
        let pulled = WeekPlan.fastTrack(week, state: FollowState())
        #expect(WeekPlan.tiles(pulled).map(\.group) == [.land, .rights, .defense, .money])
        #expect(WeekPlan.rows(pulled, in: .gov).map(\.pulled) == [true])
    }

    @Test func theSummarySaysOnlyWhatTheScheduleSupports() throws {
        let week = try Self.week()
        #expect(WeekPlan.summary(week) == "Both chambers in · 17 measures listed")
        let later: Schedule = try Self.fixture("schedule-2026-11-23")
        #expect(WeekPlan.summary(later) == nil)
        var proForma = week
        proForma.house = .init(inSession: nil, items: [])
        proForma.senate?.items = []
        for i in proForma.senate!.meetings.indices { proForma.senate!.meetings[i].proForma = true }
        #expect(WeekPlan.summary(proForma) == "Senate pro forma")
    }

    @Test func alsoListedIsWhatIsLeft() throws {
        let also = WeekPlan.alsoListed(try Self.week(), state: FollowState())
        #expect(also.map(\.item.label) == ["H. Res. 1665"])
    }

    @Test func senateNextIsTodaysMeetingOrTheNext() throws {
        let senate = try Self.week().senate
        let today = try #require(WeekPlan.senateNext(senate, today: "2026-11-17"))
        #expect(today.date == "2026-11-17")
        let clock = WeekPlan.meetingClock(today, today: "2026-11-17")
        #expect(clock.day == "TODAY")
        #expect(clock.time == "10:00")
        #expect(clock.half == "AM")
        #expect(WeekPlan.senateNext(senate, today: "2026-11-16")?.date == "2026-11-16")
        #expect(WeekPlan.meetingClock(try #require(WeekPlan.senateNext(senate, today: "2026-11-16")), today: "2026-11-16").time == "3:00")
        let after = try #require(WeekPlan.senateNext(senate, today: "2026-11-19"))
        #expect(after.date == "2026-11-17")
        #expect(WeekPlan.meetingClock(after, today: "2026-11-19").day == "TUE")
        #expect(WeekPlan.senateNext(nil, today: "2026-11-17") == nil)
    }

    // MARK: - Catch up

    @MainActor @Test func theDeckLeadsWithRatepayerAndSaysSince() throws {
        let deck = CatchUp.select(try Self.feed())
        #expect(deck.first?.measure?.title == "Ratepayer Protection Act")
        #expect(deck.first?.vote.totals.yea == 57)
        #expect(CatchUpDeckView.subtitle(deck, front: 0, calendar: Self.eastern)?.hasPrefix("1 of 5 · since ") == true)
        let oldest = try #require(deck.compactMap(\.vote.occurredAtDate).min())
        #expect(CatchUpDeckView.subtitle(deck, front: 4, calendar: Self.eastern)
            == "5 of 5 · since \(Stories.shortDate(oldest, calendar: Self.eastern))")
    }

    // MARK: - The feed keeps the stage

    @Test func aMembersRecordBorrowsTheStageFromTheLatestFinals() throws {
        let rows: RecentVotes = try Self.fixture("votes-recent-40-2026-11-17")
        let row = try #require(rows.votes.first { $0.vote.id == "house-119-2-323" })
        var bare = try #require(row.measure)
        bare.stage = nil
        bare.policyArea = nil
        let mine = FeedItem(vote: row.vote, measure: bare, positions: [])
        let combined = HomeModel.combine([mine], with: [row])
        #expect(combined.first?.measure?.stage == .passedHouse)
        #expect(combined.first?.measure?.policyArea == "Armed Forces and National Security")
        let annotated = HomeModel.annotate([row], with: [mine])
        #expect(annotated.first?.measure?.stage == .passedHouse)
    }
}
