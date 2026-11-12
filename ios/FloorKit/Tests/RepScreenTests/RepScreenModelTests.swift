import Foundation
import Testing
@testable import RepScreen
import Models

private let adams = Member(
    bioguideId: "A000370", firstName: "Alma", lastName: "Adams", party: "D", state: "NC",
    district: 12, chamber: .house
)
private let cruz = Member(
    bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
    district: nil, chamber: .senate
)
private let sanders = Member(
    bioguideId: "S000033", firstName: "Bernie", lastName: "Sanders", party: "I", state: "VT",
    district: nil, chamber: .senate
)

private func vote(_ yea: Int, _ nay: Int, kind: VoteKind = .question) -> Vote {
    Vote(
        id: "house-119-1-1", kind: kind, chamber: .house, congress: 119, session: 1, rollNumber: 1,
        question: "On Passage", billId: nil, nominationId: nil, billRef: nil, occurredAt: nil,
        state: .final, threshold: .majority,
        totals: VoteTotals(yea: yea, nay: nay, present: 0, notVoting: 0), candidates: [],
        result: yea > nay ? "Passed" : "Failed"
    )
}

@Suite("Rep screen")
struct RepScreenModelTests {
    @Test func reportsPartyUnityAsAWholePercent() {
        #expect(PartyLoyalty(votes: 1871, withParty: 1847, againstParty: 24).unityPercent == 99)
        #expect(PartyLoyalty(votes: 100, withParty: 50, againstParty: 50).unityPercent == 50)
        #expect(PartyLoyalty(votes: 3, withParty: 2, againstParty: 1).unityPercent == 67)
    }

    /// An independent's party is a bloc of one, so the API leaves those votes uncounted rather than
    /// reporting a meaningless 100%. The screen must show nothing rather than a percentage of zero.
    @Test func reportsNoUnityForSomeoneOutsideTheTwoParties() {
        #expect(PartyLoyalty(votes: 0, withParty: 0, againstParty: 0).unityPercent == nil)
    }

    @Test func writesTheRoleLineForBothChambers() {
        #expect(adams.roleLine == "U.S. Representative · D-NC-12")
        #expect(cruz.roleLine == "U.S. Senator · R-TX")
        #expect(sanders.roleLine == "U.S. Senator · I-VT")
    }

    @Test func labelsARowWithTheMeasureAndFallsBackToTheQuestion() {
        let measure = MeasureSummary(
            id: "119-hr-1", kind: .bill, citation: "H.R. 1", title: "Lower Energy Costs Act"
        )
        let named = MemberVote(vote: vote(220, 210), position: .yea, choice: nil, measure: measure)
        #expect(named.rowTitle == "H.R. 1 · Lower Energy Costs Act")
        let procedural = MemberVote(vote: vote(220, 210), position: .yea, choice: nil, measure: nil)
        #expect(procedural.rowTitle == "On Passage")
    }

    @Test func saysWhetherTheySidedWithTheOutcome() {
        let passed = vote(220, 210)
        #expect(MemberVote(vote: passed, position: .yea, choice: nil, measure: nil).agreedWithOutcome == true)
        #expect(MemberVote(vote: passed, position: .nay, choice: nil, measure: nil).agreedWithOutcome == false)
        let failed = vote(200, 230)
        #expect(MemberVote(vote: failed, position: .nay, choice: nil, measure: nil).agreedWithOutcome == true)
    }

    @Test func saysNothingAboutTheOutcomeWhereThereIsNoneToSideWith() {
        // Present and absent are not a side.
        let passed = vote(220, 210)
        #expect(MemberVote(vote: passed, position: .present, choice: nil, measure: nil).agreedWithOutcome == nil)
        #expect(MemberVote(vote: passed, position: .notVoting, choice: nil, measure: nil).agreedWithOutcome == nil)
        // A tie has no leader.
        let tied = vote(215, 215)
        #expect(MemberVote(vote: tied, position: .yea, choice: nil, measure: nil).agreedWithOutcome == nil)
        // A Speaker ballot is not a yea/nay question at all.
        let ballot = vote(0, 0, kind: .election)
        #expect(MemberVote(vote: ballot, position: .candidate, choice: "Jeffries", measure: nil)
            .agreedWithOutcome == nil)
    }

    @Test func decodesARealMembersRecord() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let detail = try JSONDecoder().decode(
            MemberDetail.self,
            from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/member-detail.json"))
        )
        #expect(detail.member.roleLine == "U.S. Representative · D-NC-12")
        // 1847 of 1871 is 98.7%, which rounds to 99.
        #expect(detail.partyLoyalty.unityPercent == 99)
        #expect(detail.partyLoyalty.againstParty == 24)

        let record = try JSONDecoder().decode(
            MemberVotes.self,
            from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/member-votes.json"))
        )
        #expect(record.votes.allSatisfy { !$0.rowTitle.isEmpty })
    }
}
