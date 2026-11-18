import Foundation
import Testing
@testable import Models

/// v0.2.60: member news and polls, and the Local tab's registry, hubs and legislators, from the
/// fixtures built for it (real headlines, polls and items; tones and stories hand-labelled — each
/// fixture's `_fixture` key says what is real and what is not).
@Suite("News, polls and Local")
struct NewsLocalTests {
    // MARK: News

    @Test func schumersWeekIsTwoStoriesAndThreeOthers() throws {
        let news = try fixture("news-schumer-2026-11-17", as: MemberNews.self)
        #expect(news.memberId == "S000148")
        #expect(news.headlines.count == 25)
        #expect(news.tone == ToneCounts(favorable: 2, neutral: 16, critical: 7, office: 0))
        #expect(news.tone?.counted == 25)
        #expect(news.stories.map(\.title) == [
            "Van Hollen challenges Schumer for majority leader", "Polls on Schumer as Senate Democratic leader",
        ])
        #expect(news.stories.map { news.headlines(in: $0).count } == [20, 2])
        #expect(news.otherHeadlines.count == 3)
        // Newest first, everywhere.
        let dates = news.headlines.compactMap(\.publishedDate)
        #expect(dates == dates.sorted(by: >))
        #expect(news.headlines.first?.displayTitle == "Schumer declares he has votes to beat Van Hollen and become majority leader")
        #expect(news.polls.map(\.pollster) == ["Economist/YouGov", "Data for Progress", "NBC News"])
    }

    @Test func gillibrandsWeekIsAPlainListWithHerOfficesRelease() throws {
        let news = try fixture("news-gillibrand-2026-11-17", as: MemberNews.self)
        #expect(!news.isAIRead)
        #expect(news.stories.isEmpty)
        #expect(news.polls.isEmpty)
        #expect(news.headlines.count == 14)
        #expect(news.headlines.filter { $0.tone == .office }.map(\.source) == ["Merkley (.gov)"])
        #expect(news.otherHeadlines.count == 14)
        #expect(!news.isEmpty)
    }

    /// One bad headline is dropped; an unknown tone is no tone; a story keeps only headlines that are
    /// here and goes when fewer than two are left.
    @Test func readsLeniently() throws {
        let json = #"""
        {"memberId":"X","tone":{"favorable":1,"neutral":"lots","critical":1},
         "stories":[{"id":"s1","title":"Kept","tone":{"favorable":1,"neutral":0,"critical":1,"office":0},"headlineIds":["a","b","gone"]},
                    {"id":"s2","title":"Dropped","headlineIds":["a","gone"]}],
         "headlines":[{"id":"a","title":"A - Pub","source":"Pub","url":"https://a.test","publishedAt":"2026-11-16T10:00:00Z","tone":"glowing","storyId":"s1"},
                      {"id":"b","title":"B","source":"Pub","url":"https://b.test","publishedAt":"2026-11-17T10:00:00.000Z","tone":"critical"},
                      {"id":"c","title":"C","url":"https://c.test","publishedAt":"not a date"}],
         "polls":[{"id":"p","pollster":"P","fieldedFrom":"2026-11-01","fieldedTo":"2026-11-02","positive":{"label":"yes","pct":70},
                   "negative":{"label":"no","pct":40},"url":"https://p.test"}],
         "somethingNew":true}
        """#
        let news = try JSONDecoder().decode(MemberNews.self, from: Data(json.utf8))
        #expect(news.headlines.map(\.id) == ["b", "a"])
        #expect(news.headlines.last?.tone == nil)
        #expect(news.headlines.last?.displayTitle == "A")
        #expect(news.tone == ToneCounts(favorable: 1, neutral: 0, critical: 1))
        #expect(news.stories.map(\.headlineIds) == [["a", "b"]])
        #expect(news.polls.isEmpty) // 70 + 40 is over 100
        #expect(news.checkedAt == nil)
    }

    @Test func theEmptyBodyIsNothingToShow() throws {
        let news = try JSONDecoder().decode(MemberNews.self, from: Data(#"{"memberId":"","checkedAt":null,"tone":null,"stories":[],"headlines":[],"polls":[]}"#.utf8))
        #expect(news.isEmpty)
        #expect(!news.isAIRead)
    }

    @Test func pollsReadAsTheirPollstersWordedThem() throws {
        let polls = try fixture("news-schumer-2026-11-17", as: MemberNews.self).polls
        #expect(polls.map(\.heading) == [
            "Economist/YouGov · Nov 13–16 · U.S. adults",
            "Data for Progress · Nov 13–15 · Democratic-leaning likely voters",
            "NBC News · Oct 28–30 · registered voters",
        ])
        #expect(polls[0].positive.line == "22% favorable")
        #expect(polls[0].other?.line == "28% don't know")
        #expect(polls[0].unlabelled == 0)
        // Data for Progress reported no third share: the rest is drawn, unlabelled.
        #expect(polls[1].other == nil)
        #expect(polls[1].unlabelled == 12)
        #expect(polls[2].spoken == "NBC News · Oct 28–30 · registered voters. 1,000 asked. 13% positive. 34% neutral or unsure. 53% negative.")
        #expect(PollShare(label: "x", pct: 22.5).percent == "22.5%")
    }

    @Test func pollDatesAcrossAMonth() {
        var poll = Poll.sample
        poll.fieldedFrom = "2026-10-30"
        poll.fieldedTo = "2026-11-02"
        #expect(poll.dates == "Oct 30–Nov 2")
        poll.fieldedFrom = "2026-11-02"
        #expect(poll.dates == "Nov 2")
    }

    // MARK: Local

    @Test func theRegistryIsFiftyStatesAndNineCities() throws {
        let registry = try fixture("local-jurisdictions", as: LocalJurisdictions.self)
        #expect(registry.jurisdictions.filter { $0.kind == .state }.count == 50)
        #expect(registry.cities.map(\.name) == [
            "New York City", "Seattle", "San Francisco", "Boston", "Denver", "Los Angeles", "Chicago", "Houston", "Philadelphia",
        ])
        #expect(registry.state("ny")?.name == "New York State")
        #expect(registry.city(placeGeoid: "3651000")?.id == "nyc")
        #expect(registry.cities.filter { $0.coverage == .newsOnly }.count == 4)
    }

    @Test func newYorkStatesHub() throws {
        let hub = try fixture("local-ny-2026-11-17", as: LocalHub.self)
        #expect(hub.enacted.map(\.identifier) == ["S 1788-A"])
        #expect(hub.enacted.first?.status == .signed)
        #expect(hub.enacted.first?.shortDate == "Nov 11")
        #expect(hub.waiting.map(\.title) == ["One Fair Price Act"])
        #expect(hub.waiting.first?.status == .awaitingGovernor)
        #expect(hub.news.count == 20)
        #expect(hub.news.allSatisfy { $0.tone == nil })
    }

    @Test func newYorkCitysHubHasTheTally() throws {
        let hub = try fixture("local-nyc-2026-11-17", as: LocalHub.self)
        let item = try #require(hub.enacted.first)
        #expect(item.identifier == "Int. 891-A")
        #expect(item.tally?.yes == 44)
        #expect(item.tally?.no == 5)
        #expect(hub.waiting.isEmpty)
        let seattle = try fixture("local-seattle-2026-11-17", as: LocalHub.self)
        #expect(seattle.enacted.first?.tally == nil)
        #expect(try fixture("local-houston-empty", as: LocalHub.self).isEmpty)
    }

    /// A city never has a "waiting" list, whatever is sent; an unknown coverage reads as pending.
    @Test func hubsReadLeniently() throws {
        let json = #"""
        {"jurisdiction":{"id":"x","kind":"city","name":"X","state":"WA","coverage":"someday"},
         "enacted":[{"id":"1","identifier":"CB 1","title":"Old","body":"City Council","date":"2026-11-01","status":"passed"},
                    {"id":"2","identifier":"CB 2","title":"New","body":"City Council","date":"2026-11-13","status":"passed","yes":"nine"},
                    {"id":"3","title":"Bad","date":"2026-11-13","status":"vetoed"}],
         "waiting":[{"id":"4","identifier":"CB 4","title":"W","body":"City Council","date":"2026-11-13","status":"awaiting_governor"}],
         "news":[]}
        """#
        let hub = try JSONDecoder().decode(LocalHub.self, from: Data(json.utf8))
        #expect(hub.jurisdiction.coverage == .pending)
        #expect(hub.enacted.map(\.title) == ["New", "Old"])
        #expect(hub.enacted.first?.yes == nil)
        #expect(hub.waiting.isEmpty)
    }

    @Test func legislatorsAndTheirSeats() throws {
        let list = try fixture("local-ny-legislators-sd59", as: StateLegislators.self)
        let senator = try #require(list.legislators.first)
        #expect(senator.partyLetter == "D")
        #expect(senator.initials == "KG")
        #expect(StateChambers.seat(senator, state: "NY") == "State Senate · District 59")
        #expect(StateChambers.name(.lower, state: "NY") == "Assembly")
        #expect(StateChambers.name(.lower, state: "TX") == "State House")
        #expect(StateChambers.lowerMember(state: "ny") == "Assembly member")
        #expect(StateChambers.lowerMember(state: "TX") == "state representative")
        #expect(StateChambers.name(.upper, state: "TX") == "State Senate")
    }

    /// A district stored before v0.2.60 has no state districts or place; a new one carries them, and
    /// both round-trip.
    @Test func districtsGainStateDistrictsAndPlace() throws {
        let old = try JSONDecoder().decode(District.self, from: Data(#"{"congress":119,"state":"TX","district":37,"countyFips":"48453"}"#.utf8))
        #expect(old.stateUpper == nil && old.stateLower == nil && old.place == nil)
        let json = #"{"congress":119,"state":"NY","district":10,"countyFips":"36061","stateUpper":"59","stateLower":" ","place":{"geoid":"3651000","name":"New York city"}}"#
        let new = try JSONDecoder().decode(District.self, from: Data(json.utf8))
        #expect(new.stateUpper == "59")
        #expect(new.stateLower == nil)
        #expect(new.place?.geoid == "3651000")
        #expect(try JSONDecoder().decode(District.self, from: JSONEncoder().encode(new)) == new)
        let wrong = try JSONDecoder().decode(District.self, from: Data(#"{"congress":119,"state":"NY","district":10,"stateUpper":59,"place":"NYC"}"#.utf8))
        #expect(wrong.stateUpper == nil && wrong.place == nil)
    }
}
