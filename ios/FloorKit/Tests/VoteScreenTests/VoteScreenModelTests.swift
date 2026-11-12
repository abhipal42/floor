import Foundation
import Testing
@testable import VoteScreen
import Models

private func detail(
    yea: Int, nay: Int, present: Int = 0, notVoting: Int = 0,
    threshold: VoteThreshold = .majority,
    parties: [PartyTotals] = [],
    measure: MeasureSummary? = nil,
    kind: VoteKind = .question,
    candidates: [Candidate] = [],
    candidateTotals: [CandidateTotal] = []
) -> VoteDetail {
    VoteDetail(
        vote: Vote(
            id: "house-119-1-1", kind: kind, chamber: .house, congress: 119, session: 1,
            rollNumber: 1, question: "On Passage", billId: measure.map(\.id), nominationId: nil,
            billRef: nil, occurredAt: nil, state: .final, threshold: threshold,
            totals: VoteTotals(yea: yea, nay: nay, present: present, notVoting: notVoting),
            candidates: candidates, result: nil
        ),
        partyTotals: parties, candidateTotals: candidateTotals, positions: [], measure: measure
    )
}

@Suite("Vote screen")
struct VoteScreenModelTests {
    @Test func writesEachSidesPartySplitTheWayTheCanvasDoes() {
        let d = detail(
            yea: 212, nay: 196,
            parties: [
                PartyTotals(party: "D", yea: 201, nay: 8, present: 0, notVoting: 2),
                PartyTotals(party: "R", yea: 11, nay: 188, present: 0, notVoting: 1),
            ]
        )
        #expect(d.partySplit(.yea) == "D 201 · R 11")
        #expect(d.partySplit(.nay) == "D 8 · R 188")
    }

    @Test func leavesOutAPartyThatCastNoVoteAtAll() {
        let d = detail(
            yea: 10, nay: 5,
            parties: [
                PartyTotals(party: "D", yea: 10, nay: 0, present: 0, notVoting: 0),
                PartyTotals(party: "R", yea: 0, nay: 5, present: 0, notVoting: 0),
                PartyTotals(party: "I", yea: 0, nay: 0, present: 0, notVoting: 0),
            ]
        )
        #expect(d.significantParties.map(\.party) == ["D", "R"])
        // A party that was absent rather than silent still counts as present on the roll.
        let withAbsentee = detail(
            yea: 10, nay: 5,
            parties: [PartyTotals(party: "I", yea: 0, nay: 0, present: 0, notVoting: 1)]
        )
        #expect(withAbsentee.significantParties.map(\.party) == ["I"])
    }

    @Test func saysHowManyVotesTheWinningSideWasShort() {
        // 430 cast, majority is 216; the leading side has 212.
        let failed = detail(yea: 212, nay: 218)
        #expect(failed.vote.votesNeeded == 216)
        #expect(failed.votesShortOfThreshold == nil) // the nays cleared it
        let short = detail(yea: 100, nay: 90, present: 20)
        #expect(short.vote.votesNeeded == 106)
        #expect(short.votesShortOfThreshold == 6)
    }

    @Test func reportsNothingShortOnceTheThresholdIsMet() {
        #expect(detail(yea: 216, nay: 214).votesShortOfThreshold == nil)
    }

    @Test func appliesTheRightThresholdToAClotureVote() {
        let cloture = detail(yea: 57, nay: 40, threshold: .threeFifthsSworn)
        #expect(cloture.vote.votesNeeded == 60)
        #expect(cloture.votesShortOfThreshold == 3)
    }

    @Test func titlesTheScreenWithTheMeasureAndFallsBackToTheQuestion() {
        let named = detail(
            yea: 1, nay: 0,
            measure: MeasureSummary(id: "119-hr-1", kind: .bill, citation: "H.R. 1", title: "Lower Energy Costs Act")
        )
        #expect(named.title == "H.R. 1 · Lower Energy Costs Act")
        #expect(detail(yea: 1, nay: 0).title == "On Passage")
    }

    @Test func ranksSpeakerCandidatesByStrengthAcrossParties() {
        let d = detail(
            yea: 0, nay: 0, present: 1, kind: .election,
            candidates: [Candidate(name: "Jeffries", total: 212), Candidate(name: "McCarthy", total: 203)],
            candidateTotals: [
                CandidateTotal(party: "R", candidate: "McCarthy", total: 200),
                CandidateTotal(party: "D", candidate: "Jeffries", total: 212),
                CandidateTotal(party: "I", candidate: "McCarthy", total: 3),
            ]
        )
        let ranked = d.candidatesByStrength
        #expect(ranked.map(\.candidate) == ["Jeffries", "McCarthy"])
        // McCarthy's total is summed across the parties that backed him.
        #expect(ranked[1].total == 203)
    }

    @Test func decodesARealVoteWithItsMeasure() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let data = try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/vote-question.json"))
        let real = try JSONDecoder().decode(VoteDetail.self, from: data)
        #expect(real.measure?.citation == "H.Con.Res. 14")
        #expect(real.title.hasPrefix("H.Con.Res. 14 · "))
        #expect(real.partySplit(.yea) == "R 216 · D 0")
        #expect(real.votesShortOfThreshold == nil)
    }

    @Test func aSpeakerElectionNamesNoMeasureSoTheQuestionStands() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let data = try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/vote-election.json"))
        let election = try JSONDecoder().decode(VoteDetail.self, from: data)
        #expect(election.measure == nil)
        #expect(election.title == election.vote.question)
        #expect(election.candidatesByStrength.first?.candidate == "Jeffries")
    }
}
