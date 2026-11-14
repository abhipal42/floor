import Foundation
import Testing
@testable import Models

/// `members-search-new-york.json` (`GET /v1/members?q=New York`) and `votes-recent.json`
/// (`GET /v1/votes?limit=10`) are the new routes answering from staging on 2026-11-13.
@Suite("Search and recent votes")
struct ListsTests {
    @Test func decodesASearchSenateFirstThenTheHouseByDistrict() throws {
        let members = try fixture("members-search-new-york", as: MemberSearch.self).members
        #expect(members.count == 28) // 2 senators and New York's 26 House seats
        #expect(members.prefix(2).map(\.lastName) == ["Gillibrand", "Schumer"])
        let house = members.dropFirst(2)
        #expect(house.allSatisfy { $0.chamber == .house && $0.state == "NY" })
        #expect(house.compactMap(\.district) == Array(1...26))
        #expect(members.first { $0.district == 8 }?.lastName == "Jeffries")
    }

    @Test func decodesRecentFinalsNewestFirstWithWhatEachWasOn() throws {
        let votes = try fixture("votes-recent", as: RecentVotes.self).votes
        #expect(votes.count == 10)
        #expect(votes.allSatisfy { $0.vote.state == .final })
        let dates = votes.compactMap(\.vote.occurredAtDate)
        #expect(dates == dates.sorted(by: >))
        #expect(votes.first?.measure?.kind == .nomination)
        #expect(votes.contains { $0.measure?.citation == "H.R. 2102" })
    }
}
