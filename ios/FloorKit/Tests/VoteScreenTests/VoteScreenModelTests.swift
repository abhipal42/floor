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

private func loadDetail(_ name: String) throws -> VoteDetail {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent()
    dir.deleteLastPathComponent()
    return try JSONDecoder().decode(
        VoteDetail.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
    )
}

@Suite("Vote screen: box score and your three")
struct VoteBoxScoreTests {
    /// H.R. 1013: Republicans 212–0, Democrats 83–128. The mock's own sentence.
    @Test func saysWhoCrossedOnARealVote() throws {
        let detail = try loadDetail("vote-passage-hr1013")
        #expect(detail.crossoverSentence == "83 Democrats crossed to join a unanimous Republican side.")
        #expect(detail.boxScore.map(\.party) == ["R", "D"])
        #expect(detail.rollParties.map(\.party) == ["D", "R"])
        #expect(detail.rollCount == 433)
        #expect(!detail.anyPresent)
    }

    @Test func callsAStraightPartyLineVoteOne() throws {
        // H.R. 7008 cloture: R 53–0, D 0–45, I 0–2. Independents are left out of the reading.
        #expect(try loadDetail("vote-cloture-failed").crossoverSentence == "A party-line vote: no Democrat or Republican crossed.")
    }

    @Test func handlesBothPartiesOnOneSide() {
        let d = detail(yea: 300, nay: 100, parties: [
            PartyTotals(party: "D", yea: 150, nay: 60, present: 0, notVoting: 0),
            PartyTotals(party: "R", yea: 150, nay: 40, present: 0, notVoting: 0),
        ])
        #expect(d.crossoverSentence == "Most of both parties voted yea: Democrats 150–60, Republicans 150–40.")
        let both = detail(yea: 10, nay: 5, parties: [
            PartyTotals(party: "D", yea: 6, nay: 1, present: 0, notVoting: 0),
            PartyTotals(party: "R", yea: 1, nay: 4, present: 0, notVoting: 0),
        ])
        #expect(both.crossoverSentence == "1 Democrat and 1 Republican crossed party lines.")
        #expect(detail(yea: 0, nay: 0, kind: .election).crossoverSentence == nil)
    }

    @Test func placesYourMemberInTheirParty() throws {
        let detail = try loadDetail("vote-passage-hr1013")
        let jeffries = try #require(detail.positions.first)
        #expect(detail.withParty(jeffries) == "with 128 of 211 Democrats")
        let away = MemberPosition(member: jeffries.member, position: .notVoting, choice: nil)
        #expect(detail.withParty(away) == nil)
    }

    @Test func notesYourMembersInTheOtherChamber() throws {
        let detail = try loadDetail("vote-passage-hr1013")
        let schumer = Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D", state: "NY", district: nil, chamber: .senate)
        let gillibrand = Member(bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: nil, chamber: .senate)
        let note = try #require(detail.otherChamberNote(delegation: [detail.positions[0].member, schumer, gillibrand]))
        #expect(note.text == "Schumer and Gillibrand vote in the Senate — this was a House vote.")
        #expect(detail.otherChamberNote(delegation: [detail.positions[0].member]) == nil)
        // Following more senators than fit in a sentence: a count.
        let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: nil, chamber: .senate)
        let three = try #require(detail.otherChamberNote(delegation: [schumer, gillibrand, cruz]))
        #expect(three.text == "3 of your members vote in the Senate — this was a House vote.")
        #expect(three.members.count == 3)
    }

    @Test func drawsOneSquarePerMember() throws {
        let dems = try #require(try loadDetail("vote-passage-hr1013").partyTotals.first { $0.party == "D" })
        #expect(dems.squares.count == 214)
        #expect(dems.squares.prefix(83).allSatisfy { $0 == .yea })
        #expect(dems.squares.suffix(3).allSatisfy { $0 == .notVoting })
    }
}
