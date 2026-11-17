import Foundation
import Models
import Testing
@testable import Home

/// The Finals feed as stories, on the week of Nov 9–17, 2026 as the API served it (this branch's
/// API, read from production on 2026-11-17): the latest 17 finals and the New York members' records.
@Suite("Stories")
struct StoriesTests {
    static let now = Date(timeIntervalSince1970: 1_794_949_200) // 2026-11-17T21:00:00Z, a Tuesday

    static func calendar(_ zone: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static let nadler = Member(bioguideId: "N000002", firstName: "Jerrold", lastName: "Nadler", party: "D", state: "NY", district: 12, chamber: .house)
    static let schumer = Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D", state: "NY", district: nil, chamber: .senate)
    static let gillibrand = Member(bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: nil, chamber: .senate)

    /// The feed as "All" builds it: the latest finals, with your members' positions on them.
    static func feed() throws -> [FeedItem] {
        let decoder = JSONDecoder()
        let recent = try decoder.decode(RecentVotes.self, from: HomeStub.fixture("votes-recent-2026-11-17")).votes
        let records = try [(nadler, "nadler"), (schumer, "schumer"), (gillibrand, "gillibrand")].map { member, name in
            (member, try decoder.decode(MemberVotes.self, from: HomeStub.fixture("member-votes-\(name)-2026-11-17")).votes)
        }
        return HomeModel.annotate(recent, with: HomeModel.merge(records, order: [nadler, schumer, gillibrand].map(\.bioguideId)))
    }

    @Test func groupsByMeasureAndWeekNewestFirst() throws {
        let weeks = Stories.group(try Self.feed(), now: Self.now, calendar: Self.calendar())
        #expect(weeks.map(\.title) == ["This week", "Last week"])
        #expect(weeks.map(\.alsoTitle) == ["Also this week", "Also last week"])
        // This week: two confirmations, each with its cloture; the unnamed cloture is a mini row.
        #expect(weeks[0].stories.map(\.id) == ["119-pn-1181-7", "119-pn-999-2"])
        #expect(weeks[0].minis.map(\.id) == ["vote:senate-119-2-264"])
        // Last week: the stories by their latest vote, then the measures that only moved along.
        #expect(weeks[1].stories.map(\.id) == ["119-pn-1181-1", "119-hr-2102", "119-hr-1013", "119-hr-9612", "119-hr-3978"])
        #expect(weeks[1].minis.map(\.id) == ["119-hr-2347", "119-hres-1655"])
        #expect(Stories.range(weeks[0], calendar: Self.calendar()) == "Nov 12 – 17")
    }

    @Test func aSpecialRulesVotesJoinTheBillItBringsUp() throws {
        let weeks = Stories.group(try Self.feed(), now: Self.now, calendar: Self.calendar())
        let star = try #require(weeks[1].stories.first { $0.id == "119-hr-2102" })
        // The discharge and the rule are on H.Res. 1247; they read as steps of H.R. 2102, oldest first.
        #expect(star.steps.map(\.vote.id) == ["house-119-2-320", "house-119-2-322", "house-119-2-323"])
        #expect(star.measure?.id == "119-hr-2102")
        #expect(star.title == "Major Richard Star Act")
        #expect(star.main.vote.id == "house-119-2-323")
        #expect(star.main.vote.verdict == "PASSED HOUSE")
        #expect(star.steps.map { Stories.stepLabel($0, calendar: Self.calendar()) }
            == ["Discharge petition · Nov 11", "Rule for debate · Nov 12", "Passage · Nov 12"])
        #expect(Stories.citationLine(try #require(star.measure)) == "H.R. 2102 · Sponsor Bilirakis (R-FL)")
        #expect(Stories.topicLine(star) == "Armed Forces and National Security")
        #expect(star.group == .defense)
    }

    @Test func aRuleWhoseBillIsNotInTheFeedIsItsOwnStory() throws {
        let feed = try Self.feed().filter { $0.vote.id != "house-119-2-323" }
        let weeks = Stories.group(feed, now: Self.now, calendar: Self.calendar())
        let rule = try #require(weeks[1].minis.first { $0.id == "119-hres-1247" })
        #expect(rule.steps.map(\.vote.id) == ["house-119-2-320", "house-119-2-322"])
        #expect(!rule.isFull)
    }

    @Test func saysHowEachOfYourMembersVoted() throws {
        let weeks = Stories.group(try Self.feed(), now: Self.now, calendar: Self.calendar())
        let star = try #require(weeks[1].stories.first { $0.id == "119-hr-2102" })
        let nadler = try #require(Stories.members(star).first)
        #expect(nadler.member.lastName == "Nadler" && nadler.position == .yea && nadler.everyStep == "on all three")
        let domenico = try #require(weeks[0].stories.first { $0.id == "119-pn-999-2" })
        let senators = Stories.members(domenico)
        #expect(senators.map(\.member.lastName) == ["Schumer", "Gillibrand"])
        #expect(senators.map(\.position) == [.nay, .nay])
        // Schumer voted nay on cloture and confirmation; Gillibrand missed cloture.
        #expect(senators.map(\.everyStep) == ["on both", nil])
        // "All" shows your three only.
        #expect(Stories.members(domenico, allowed: [Self.nadler.bioguideId]).isEmpty)
        #expect(Stories.spoken(star, members: Stories.members(star))
            == "Major Richard Star Act. Passed House. Passage, 392 to 18. Nadler voted yea on all three.")
    }

    @Test func wordsANominationAndAMiniRow() throws {
        let weeks = Stories.group(try Self.feed(), now: Self.now, calendar: Self.calendar())
        let domenico = try #require(weeks[0].stories.first { $0.id == "119-pn-999-2" })
        #expect(domenico.title == "Daniel Desmond Domenico")
        #expect(Stories.topicLine(domenico) == "Nomination · Tenth Circuit")
        #expect(Stories.citationLine(try #require(domenico.measure)) == "U.S. Circuit Judge · PN999-2")
        #expect(domenico.main.vote.verdict == "CONFIRMED")
        #expect(domenico.group == .courts)
        let unnamed = try #require(weeks[0].minis.first)
        #expect(unnamed.title == "Cloture")
        #expect(Stories.miniLine(unnamed, calendar: Self.calendar()) == "Measure not named in the record · Nov 16")
        let proceed = try #require(weeks[1].minis.first)
        #expect(Stories.miniLine(proceed, calendar: Self.calendar()) == "H.R. 2347 · Motion to take it up agreed Nov 10")
    }

    /// The reader's zone decides the week: 10 p.m. Saturday in New York is Sunday in UTC (lesson 69).
    @Test func theWeekIsTheReadersWeek() {
        var vote = Vote.sample
        vote.id = "house-119-2-9999"
        vote.occurredAt = "2026-11-15T03:00:00.000Z"
        let item = FeedItem(vote: vote, measure: nil, positions: [])
        #expect(Stories.group([item], now: Self.now, calendar: Self.calendar()).map(\.title) == ["Last week"])
        #expect(Stories.group([item], now: Self.now, calendar: Self.calendar("UTC")).map(\.title) == ["This week"])
        let later = Date(timeIntervalSince1970: 1_797_000_000) // 2026-12-11
        #expect(Stories.group([item], now: later, calendar: Self.calendar()).map(\.title) == ["Week of Nov 8"])
    }
}
