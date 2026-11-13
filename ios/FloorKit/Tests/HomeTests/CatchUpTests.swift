import Foundation
import Testing
@testable import Home
import Models
import Onboarding

/// Real 40-vote records for Texas 37 — Doggett, Cornyn and Cruz — captured from the live API on
/// 2026-11-12 into `ModelsTests/Fixtures`.
private func record(_ name: String) throws -> [MemberVote] {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // HomeTests
    dir.deleteLastPathComponent() // Tests
    let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
    return try JSONDecoder().decode(MemberVotes.self, from: Data(contentsOf: url)).votes
}

private let doggett = Member(
    bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
    district: 37, chamber: .house
)
private let cornyn = Member(
    bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX",
    district: nil, chamber: .senate
)
private let cruz = Member(
    bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
    district: nil, chamber: .senate
)

private func texasFeed() throws -> [FeedItem] {
    HomeModel.merge([
        (doggett, try record("member-votes-doggett-40")),
        (cornyn, try record("member-votes-cornyn-40")),
        (cruz, try record("member-votes-cruz-40")),
    ])
}

private func item(
    yea: Int, nay: Int, present: Int = 0, threshold: VoteThreshold, result: String?,
    chamber: Chamber = .house, positions: [(Member, Position)] = []
) -> FeedItem {
    FeedItem(
        vote: Vote(
            id: "\(chamber.rawValue)-119-2-1", kind: .question, chamber: chamber, congress: 119, session: 2,
            rollNumber: 1, question: "On Passage", billId: nil, nominationId: nil, billRef: nil,
            occurredAt: "2026-11-11T19:00:00.000Z", state: .final, threshold: threshold,
            totals: VoteTotals(yea: yea, nay: nay, present: present, notVoting: 0), candidates: [], result: result
        ),
        measure: nil,
        positions: positions.map { FeedItem.Position(member: $0.0, position: $0.1, choice: nil) }
    )
}

@Suite("Catch-up deck")
struct CatchUpTests {
    /// The four Texas finals that lost with more yeas than nays come first, closest to their line
    /// first; then the closest of the rest, ties going to the most recent. Expected values were
    /// computed from the fixtures by a separate script, not by this code.
    @Test func dealsFailedMajoritiesThenTheClosestThenTheNewest() throws {
        let deck = CatchUp.select(try texasFeed())
        #expect(deck.map(\.vote.id) == [
            "senate-119-2-254", // H.R. 9340 cloture, 57–43: 3 short of 60
            "senate-119-2-253", // H.R. 7008 cloture, 53–47: 7 short
            "senate-119-2-231", // S. 5271 cloture, 52–46: 8 short
            "house-119-2-293", // H.J.Res. 1 suspension, 212–206: 67 short of two-thirds
            "senate-119-2-237", // PN999-4 cloture, 49–47: exactly the 49 needed, Sep 17
        ])
    }

    @Test func dealsTheSameDeckWhateverOrderTheFeedArrivesIn() throws {
        let feed = try texasFeed()
        #expect(CatchUp.select(feed.reversed()).map(\.id) == CatchUp.select(feed).map(\.id))
    }

    @Test func dealsFewerWhenThereAreFewerFinals() {
        let one = item(yea: 220, nay: 210, threshold: .majority, result: "Passed")
        #expect(CatchUp.select([one]).count == 1)
        #expect(CatchUp.select([]).isEmpty)
    }

    @Test func skipsSpeakerBallots() {
        let ballot = FeedItem(vote: .sampleElection, measure: nil, positions: [])
        #expect(CatchUp.select([ballot]).isEmpty)
    }

    @Test func twistForAMajorityThatLostTheSixty() throws {
        let card = try #require(try texasFeed().first { $0.vote.id == "senate-119-2-253" })
        #expect(CatchUp.twist(card) == "A majority voted yes and it still lost: 7 short of 60.")
    }

    @Test func twistForAWinThatFellShortOfTwoThirds() throws {
        let card = try #require(try texasFeed().first { $0.vote.id == "house-119-2-293" })
        #expect(CatchUp.twist(card) == "Won the room by 6 and fell 67 short of two-thirds.")
    }

    @Test func twistForALopsidedWin() throws {
        // H.R. 9340 in the House, 417–3 under suspension.
        let card = try #require(try texasFeed().first { $0.vote.id == "house-119-2-312" })
        #expect(CatchUp.twist(card) == "Three votes against in the entire House.")
        let unanimous = item(yea: 424, nay: 0, threshold: .twoThirds, result: "Passed")
        #expect(CatchUp.twist(unanimous) == "Not one vote against in the entire House.")
        let one = item(yea: 96, nay: 1, threshold: .majority, result: "Amendment Agreed to", chamber: .senate)
        #expect(CatchUp.twist(one) == "One vote against in the entire Senate.")
    }

    @Test func twistWhenYourSenatorsSplit() {
        let split = item(
            yea: 61, nay: 32, threshold: .majority, result: "Motion to Table Agreed to", chamber: .senate,
            positions: [(cornyn, .nay), (cruz, .yea)]
        )
        #expect(CatchUp.twist(split) == "Your senators split: Cornyn nay, Cruz yea.")
    }

    @Test func twistForAClosePassAndANearMiss() {
        // 430 cast, 216 needed.
        #expect(CatchUp.twist(item(yea: 218, nay: 212, threshold: .majority, result: "Passed"))
            == "Cleared the line by 2: 218 yea against the 216 it needed.")
        #expect(CatchUp.twist(item(yea: 216, nay: 214, threshold: .majority, result: "Passed"))
            == "Not a vote to spare: exactly the 216 it needed.")
        #expect(CatchUp.twist(item(yea: 57, nay: 40, threshold: .threeFifthsSworn, result: "Cloture Motion Rejected", chamber: .senate))
            == "A majority voted yes and it still lost: 3 short of 60.")
        #expect(CatchUp.twist(item(yea: 212, nay: 218, threshold: .majority, result: "Failed"))
            == "Four votes from carrying: 212 yea against the 216 it needed.")
    }

    @Test func twistForAComfortableResult() {
        #expect(CatchUp.twist(item(yea: 262, nay: 159, threshold: .majority, result: "Passed"))
            == "Won by 103, 51 past the line.")
        #expect(CatchUp.twist(item(yea: 345, nay: 60, threshold: .twoThirds, result: "Passed"))
            == "Cleared two-thirds with 75 to spare.")
        #expect(CatchUp.twist(item(yea: 150, nay: 270, threshold: .majority, result: "Failed"))
            == "Fell 61 short of the 211 it needed.")
    }

    /// The board's rows for House roll 321, as the mock lays them out.
    @Test func lettersTheSplitFlapBoard() throws {
        let vote = Vote(
            id: "house-119-2-321", kind: .question, chamber: .house, congress: 119, session: 2, rollNumber: 321,
            question: "On Passage", billId: "119-hr-1013", nominationId: nil, billRef: "H R 1013",
            occurredAt: "2026-11-11T19:43:00.000Z", state: .final, threshold: .majority,
            totals: VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10), candidates: [], result: "Passed"
        )
        let measure = MeasureSummary(id: "119-hr-1013", kind: .bill, citation: "H.R. 1013", title: "Retirement Fairness")
        let rows = FlapBoard.rows(FeedItem(vote: vote, measure: measure, positions: []))
        #expect(rows == ["HOUSE  ROLL 321 ", "H.R. 1013 PASSED", "YEA 295 NAY 128 "])
        #expect(rows.allSatisfy { $0.count == 16 })
    }

    @Test func letteringFallsBackWhenTheCitationDoesNotFit() {
        let long = item(yea: 62, nay: 21, threshold: .majority, result: "Motion to Proceed Agreed to", chamber: .senate)
        let rows = FlapBoard.rows(FeedItem(
            vote: long.vote,
            measure: MeasureSummary(id: "x", kind: .bill, citation: "H.Con.Res. 1000", title: "x"),
            positions: []
        ))
        #expect(rows[1] == "     AGREED     ")
        let ballot = FlapBoard.rows(FeedItem(vote: .sampleElection, measure: nil, positions: []))
        #expect(ballot[1].trimmingCharacters(in: .whitespaces) == "NO SPEAKER YET")
        #expect(ballot[2].trimmingCharacters(in: .whitespaces) == "JEFFRIES 212")
    }

    @MainActor @Test func listsEachBillOnceNewestFirst() throws {
        let model = HomeModel(delegation: .init(district: .sample, members: [doggett, cornyn, cruz]),
                              api: .init(baseURL: URL(string: "https://x.test")!))
        model.items = try texasFeed()
        let bills = model.bills.compactMap(\.measure?.citation)
        #expect(Set(bills).count == bills.count)
        #expect(bills.first == "H.R. 1013")
        #expect(bills.contains("H.R. 9340"))
        #expect(model.bills.allSatisfy { $0.measure?.kind == .bill })
    }
}
