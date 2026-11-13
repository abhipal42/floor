import Foundation
import Testing
@testable import Models

private func question(
    yea: Int, nay: Int, present: Int = 0, notVoting: Int = 0, threshold: VoteThreshold,
    result: String?, question: String = "On Passage"
) -> Vote {
    Vote(
        id: "x", kind: .question, chamber: .house, congress: 119, session: 2, rollNumber: 1,
        question: question, billId: nil, nominationId: nil, billRef: nil, occurredAt: nil,
        state: .final, threshold: threshold,
        totals: VoteTotals(yea: yea, nay: nay, present: present, notVoting: notVoting),
        candidates: [], result: result
    )
}

@Suite("Threshold line and outcome")
struct VoteOutcomeTests {
    /// H.R. 1013, House roll 321 of 2026: 295–128 on a majority question. 423 cast, so 212 needed —
    /// the mock's "NEEDED 212" and "83 votes over the line".
    @Test func majorityOfThoseVoting() throws {
        let vote = try fixture("vote-passage-hr1013", as: VoteDetail.self).vote
        let line = try #require(vote.line)
        #expect(line.cast == 423)
        #expect(line.needed == 212)
        #expect(line.over == 83)
        #expect(line.short == nil)
        #expect(abs(line.yeaShare - 295.0 / 423) < 1e-9)
        #expect(abs(line.lineShare - 212.0 / 423) < 1e-9)
        #expect(line.label == "MAJORITY")
        #expect(vote.outcome == .carried)
        #expect(vote.outcomeWord == "PASSED")
    }

    /// H.J.Res. 1 under suspension, 212–206: two-thirds of the 418 voting is 279, so it lost by 67
    /// while winning the room.
    @Test func twoThirdsOfThoseVoting() throws {
        let vote = try fixture("vote-two-thirds-failed", as: VoteDetail.self).vote
        let line = try #require(vote.line)
        #expect(vote.threshold == .twoThirds)
        #expect(line.needed == 279)
        #expect(line.short == 67)
        #expect(vote.outcome == .failed)
        #expect(vote.outcomeWord == "FAILED")
        // Two-thirds of an odd count rounds up: 2/3 of 100 voting is 66.67, so 67.
        #expect(question(yea: 67, nay: 33, threshold: .twoThirds, result: nil).line?.needed == 67)
        #expect(question(yea: 66, nay: 34, threshold: .twoThirds, result: nil).outcome == .failed)
    }

    /// Cloture is three-fifths of the Senate *sworn*, 60, however many vote. H.R. 7008's 53–47
    /// was seven short.
    @Test func clotureNeedsSixtyWhoeverVotes() throws {
        let vote = try fixture("vote-cloture-failed", as: VoteDetail.self).vote
        let line = try #require(vote.line)
        #expect(line.needed == 60)
        #expect(line.short == 7)
        #expect(line.label == "60 OF 100")
        #expect(vote.outcome == .failed)
        #expect(vote.outcomeWord == "REJECTED")
        // With absentees the line moves right on the bar: 60 of 94 cast.
        let thin = question(yea: 49, nay: 45, notVoting: 6, threshold: .threeFifthsSworn, result: nil)
        #expect(thin.line?.needed == 60)
        #expect(abs((thin.line?.lineShare ?? 0) - 60.0 / 94) < 1e-9)
    }

    /// Present counts toward those voting, so it raises a majority's bar.
    @Test func presentRaisesTheMajorityBar() {
        let vote = question(yea: 232, nay: 147, present: 47, threshold: .majority, result: "Passed")
        #expect(vote.line?.cast == 426)
        #expect(vote.line?.needed == 214)
        #expect(vote.line?.over == 18)
    }

    @Test func aTieFailsAMajority() {
        let tie = question(yea: 215, nay: 215, threshold: .majority, result: nil)
        #expect(tie.line?.short == 1)
        #expect(tie.outcome == .failed)
    }

    /// The chamber's recorded result wins over the arithmetic, and rejection words are read first
    /// because "Not Agreed to" contains "Agreed".
    @Test func readsTheChambersOwnResultFirst() {
        #expect(question(yea: 10, nay: 90, threshold: .majority, result: "Not Agreed to").outcome == .failed)
        #expect(question(yea: 49, nay: 50, threshold: .majority, result: "Concurrent Resolution Rejected").outcome == .failed)
        #expect(question(yea: 61, nay: 32, threshold: .majority, result: "Motion to Table Agreed to").outcomeWord == "AGREED")
        #expect(question(yea: 47, nay: 41, threshold: .majority, result: "Nomination Confirmed").outcomeWord == "CONFIRMED")
        // A Vice President's tie-break: the arithmetic says lost, the Senate says agreed.
        #expect(question(yea: 50, nay: 50, threshold: .majority, result: "Motion Agreed to").outcome == .carried)
        // No result at all: the threshold decides.
        #expect(question(yea: 220, nay: 210, threshold: .majority, result: nil).outcome == .carried)
    }

    @Test func aSpeakerElectionHasNoLineAndNoOutcome() throws {
        let vote = try fixture("vote-election", as: VoteDetail.self).vote
        #expect(vote.line == nil)
        #expect(vote.outcome == nil)
        #expect(vote.questionKind == "Speaker election")
    }

    /// Every question in three real 40-vote records maps to a short kind, most specific first.
    @Test func namesTheKindOfQuestion() throws {
        #expect(question(yea: 1, nay: 1, threshold: .twoThirds, result: nil, question: "On Motion to Suspend the Rules and Pass, as Amended").questionKind == "Suspension")
        #expect(question(yea: 1, nay: 1, threshold: .threeFifthsSworn, result: nil, question: "On Cloture on the Motion to Proceed").questionKind == "Cloture")
        #expect(question(yea: 1, nay: 1, threshold: .majority, result: nil, question: "On Ordering the Previous Question").questionKind == "Previous question")
        #expect(question(yea: 1, nay: 1, threshold: .majority, result: nil, question: "On Motion to Recommit").questionKind == "Motion to recommit")
        #expect(question(yea: 1, nay: 1, threshold: .majority, result: nil, question: "On the Nomination").questionKind == "Nomination")
        #expect(question(yea: 1, nay: 1, threshold: .majority, result: nil, question: "On Agreeing to the Resolution").questionKind == "Resolution")
        #expect(question(yea: 1, nay: 1, threshold: .majority, result: nil, question: "On Motion to Concur in the Senate Amendment").questionKind == "Concur")
        for name in ["member-votes-doggett-40", "member-votes-cornyn-40", "member-votes-cruz-40"] {
            let record = try fixture(name, as: MemberVotes.self)
            #expect(record.votes.count == 40)
            #expect(record.votes.allSatisfy { !$0.vote.questionKind.hasPrefix("On ") })
        }
    }

    @Test func namesStatesAndDistricts() {
        #expect(StateName.districtName(state: "NY", district: 8) == "New York's 8th District")
        #expect(StateName.districtName(state: "TX", district: 37) == "Texas' 37th District")
        #expect(StateName.districtName(state: "WY", district: 0) == "Wyoming's at-large district")
        #expect(StateName.districtName(state: "IL", district: 11) == "Illinois' 11th District")
        // One delegate covers the whole place, so there is no district to name.
        #expect(StateName.districtName(state: "DC", district: 0) == "District of Columbia")
        #expect(StateName.districtName(state: "PR", district: 0) == "Puerto Rico")
        #expect(StateName.ordinal(1) == "1st")
        #expect(StateName.ordinal(22) == "22nd")
        #expect(StateName.ordinal(13) == "13th")
        #expect(StateName.ordinal(112) == "112th")
    }

    /// A failed veto override is recorded "Veto Sustained": the veto stands, the override lost.
    /// A successful one is "Veto Overridden".
    @Test func aSustainedVetoIsAFailedOverride() {
        let q = "On Passage of the Bill, the Objections of the President Notwithstanding"
        let sustained = question(yea: 60, nay: 40, threshold: .twoThirds, result: "Veto Sustained", question: q)
        #expect(sustained.outcome == .failed)
        #expect(sustained.outcomeWord == "FAILED")
        #expect(sustained.questionKind == "Veto override")
        let overridden = question(yea: 70, nay: 30, threshold: .twoThirds, result: "Veto Overridden", question: q)
        #expect(overridden.outcome == .carried)
        #expect(overridden.outcomeWord == "OVERRIDDEN")
        // The plain "sustained" of a ruling still carries.
        #expect(question(yea: 220, nay: 200, threshold: .majority, result: "Decision of Chair Sustained").outcome == .carried)
    }

    /// When the count and the record disagree, the line reports neither "over" nor "short", so no
    /// screen can print "1 short" under an AGREED chip.
    @Test func theLineGoesQuietWhenTheRecordDisagrees() throws {
        let tieBreak = try #require(question(yea: 50, nay: 50, threshold: .majority, result: "Motion Agreed to").line)
        #expect(tieBreak.contradicted)
        #expect(tieBreak.over == nil && tieBreak.short == nil)
        let uc60 = try #require(question(yea: 55, nay: 45, threshold: .majority, result: "Amendment Rejected").line)
        #expect(uc60.contradicted)
        #expect(uc60.over == nil && uc60.short == nil)
        // Present votes the arithmetic counts: 205–200 with 20 present needs 213 by the count.
        let present = try #require(question(yea: 205, nay: 200, present: 20, threshold: .majority, result: "Passed").line)
        #expect(present.contradicted)
        // Agreeing cases are untouched.
        let agree = try #require(question(yea: 220, nay: 200, threshold: .majority, result: "Passed").line)
        #expect(!agree.contradicted && agree.over == 9)
    }

    @Test func namesAConferenceReport() {
        #expect(question(yea: 1, nay: 0, threshold: .majority, result: nil, question: "On Agreeing to the Conference Report").questionKind == "Conference report")
    }
}
