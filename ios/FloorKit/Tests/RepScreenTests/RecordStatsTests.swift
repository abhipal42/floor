import Foundation
import Testing
@testable import RepScreen
import Models

private func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent()
    dir.deleteLastPathComponent()
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")))
}

private func votes(_ name: String) throws -> [MemberVote] { try load(name, as: MemberVotes.self).votes }

private let doggett = Member(
    bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
    district: 37, chamber: .house
)
private let cornyn = Member(
    bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX",
    district: nil, chamber: .senate
)

/// Expected values below were counted from the captured fixtures by a separate script.
@Suite("Your three: rings, tier, last 40, facts")
struct RecordStatsTests {
    @Test func tiersByCrossovers() {
        #expect(Tier(crossovers: 0) == .starter)
        #expect(Tier(crossovers: 299) == .starter)
        #expect(Tier(crossovers: 300) == .swing)
        #expect(Tier(crossovers: 399) == .swing)
        #expect(Tier(crossovers: 400) == .maverick)
    }

    /// Doggett's last 40: two missed (H.R. 9612 and H.R. 3978), none present, and of the 38 yea-or-nay
    /// votes, 19 on the winning side.
    @Test func countsARepresentativesLastForty() throws {
        let stats = RecordStats(votes: try votes("member-votes-doggett-40"))
        #expect(stats.calls.count == 40)
        #expect(stats.missed == 2)
        #expect(stats.present == 0)
        #expect(stats.showedUp == 38)
        #expect(stats.decided == 38)
        #expect(stats.sidedWithOutcome == 19)
        #expect(stats.showedUpShare == 38.0 / 40)
        // Oldest first: the grid reads left to right, ending on the latest call.
        #expect(stats.calls.last?.measure?.citation == "H.R. 1013")
        #expect(stats.calls.first?.measure?.citation == "H.Con.Res. 89")
    }

    @Test func countsASenatorsLastForty() throws {
        let stats = RecordStats(votes: try votes("member-votes-cruz-40"))
        #expect(stats.missed == 0)
        #expect(stats.decided == 40)
        #expect(stats.sidedWithOutcome == 36)
    }

    /// The winning side reads the outcome, not who had more votes: H.J.Res. 1 lost 212–206, so a
    /// nay was on the winning side.
    @Test func theWinningSideIsTheOutcome() throws {
        let row = try #require(try votes("member-votes-doggett-40").first { $0.measure?.citation == "H.J.Res. 1" })
        #expect(row.position == .nay)
        #expect(row.sidedWithOutcome == true)
        #expect(row.agreedWithOutcome == false) // the older, leader-based reading gets this one wrong
    }

    @Test func readsThePartyRingFromTheRealRecord() throws {
        let cruz = try load("member-detail-cruz", as: MemberDetail.self)
        #expect(cruz.partyLoyalty.withPartyShare == 1433.0 / 1501)
        #expect(Tier(crossovers: cruz.partyLoyalty.againstParty) == .starter)
        // A party of one has no ring at all (lesson 15).
        #expect(PartyLoyalty(votes: 0, withParty: 0, againstParty: 0).withPartyShare == nil)
    }

    /// 16 of Doggett's last 40 came up under suspension: yea on 13, nay on H.J.Res. 1, and he missed two.
    @Test func factAboutSuspensionVotes() throws {
        #expect(RecordFacts.didYouKnow(member: doggett, votes: try votes("member-votes-doggett-40")) ==
            "16 of Doggett's last 40 calls came up under suspension, the two-thirds fast lane. "
            + "Doggett voted yea on 13, nay on 1, and missed 2.")
    }

    @Test func factAboutAttendance() throws {
        #expect(RecordFacts.didYouKnow(member: cornyn, votes: try votes("member-votes-cornyn-40"))
            == "Cornyn missed 4 of their last 40 calls.")
        let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: nil, chamber: .senate)
        #expect(RecordFacts.didYouKnow(member: cruz, votes: try votes("member-votes-cruz-40"))
            == "Cruz cast a vote on every one of their last 40 calls.")
    }

    /// Cornyn and Cruz both cast yea or nay on 36 of the same calls and split on one, a motion to
    /// table with no measure attached.
    @Test func factAboutTwoSenatorsAgreeing() throws {
        let a = try votes("member-votes-cornyn-40")
        let b = try votes("member-votes-cruz-40")
        let counts = RecordFacts.agreementCounts(a, b)
        #expect(counts.same == 35)
        #expect(counts.both == 36)
        #expect(RecordFacts.agreement(a, b) ==
            "Your two senators voted the same way on 35 of the 36 calls they both cast — they split on a motion to table.")
    }

    @Test func speaksEachGridSquare() throws {
        let row = try #require(try votes("member-votes-doggett-40").first)
        #expect(row.spokenSummary == "Nov 11, H.R. 1013, Nay")
    }

    @Test func writesTheSeatLines() {
        #expect(doggett.seatLine == "House · Texas 37th · D")
        #expect(doggett.badge == "TX-37")
        #expect(cornyn.seatLine == "Senate · Texas · R")
        #expect(cornyn.badge == "TX")
        // At large and delegate seats, as /v1/reps sends them (district 0).
        let hageman = Member(bioguideId: "H001096", firstName: "Harriet", lastName: "Hageman", party: "R",
                             state: "WY", district: 0, chamber: .house)
        #expect(hageman.seatLine == "House · Wyoming at-large · R")
        #expect(hageman.badge == "WY-AL")
        #expect(hageman.roleLine == "U.S. Representative · R-WY-AL")
        let norton = Member(bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D",
                            state: "DC", district: 0, chamber: .house)
        #expect(norton.seatLine == "Delegate · District of Columbia · D")
        #expect(norton.badge == "DC")
        #expect(norton.roleLine == "Delegate · D-DC")
    }
}
