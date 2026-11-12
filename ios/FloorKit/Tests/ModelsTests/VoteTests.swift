import Foundation
import Testing
@testable import Models

/// Loads one of the real staging responses in `Fixtures/`.
func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

@Suite("Vote")
struct VoteTests {
    @Test func decodesARealVoteWithItsBreakdown() throws {
        let detail = try fixture("vote-question", as: VoteDetail.self)
        #expect(detail.vote == .sample)
        // The vote's own fields decode from the same flat object as the breakdown beside them.
        #expect(detail.vote.totals.yea == 216)
        #expect(detail.partyTotals.map(\.party) == ["R", "D"])
        #expect(detail.partyTotals.first?.yea == 216)
        #expect(detail.candidateTotals.isEmpty)
        // ?members=A000370,K000401 asked for two members' own positions.
        #expect(detail.positions.map { [$0.member.lastName, $0.position.rawValue] }
            == [["Adams", "nay"], ["Kiley", "yea"]])
    }

    @Test func partyTotalsReconcileToTheHeadlineTotals() throws {
        let detail = try fixture("vote-question", as: VoteDetail.self)
        #expect(detail.partyTotals.reduce(0) { $0 + $1.yea } == detail.vote.totals.yea)
        #expect(detail.partyTotals.reduce(0) { $0 + $1.nay } == detail.vote.totals.nay)
        #expect(detail.partyTotals.reduce(0) { $0 + $1.notVoting } == detail.vote.totals.notVoting)
    }

    @Test func decodesASpeakerElection() throws {
        let detail = try fixture("vote-election", as: VoteDetail.self)
        #expect(detail.vote.kind == .election)
        #expect(detail.vote.candidates.map(\.name).prefix(3) == ["Jeffries", "McCarthy", "Donalds"])
        #expect(detail.vote.leadingCandidate?.name == "Jeffries")
        // An election has no yea/nay sides to lead.
        #expect(detail.vote.leader == nil)
        #expect(detail.candidateTotals.contains { $0.party == "D" && $0.candidate == "Jeffries" })
        // One member voted present rather than for a candidate, so there is a party row after all.
        #expect(detail.partyTotals.first?.present == 1)
    }

    @Test func decodesAVoteThatRefersToNoMeasure() throws {
        let election = try fixture("vote-election", as: VoteDetail.self).vote
        #expect(election.billId == nil)
        #expect(election.nominationId == nil)
        #expect(election.billRef == nil)
    }

    /// A Speaker election's `result` names whoever led that ballot, which is not the same as being
    /// elected: 17 of the 20 ballots since 2023 settled nothing.
    @Test func doesNotTreatLeadingABallotAsWinningIt() throws {
        let tenth = try fixture("vote-election", as: VoteDetail.self).vote
        #expect(tenth.result == "Jeffries")
        #expect(tenth.leadingCandidate?.name == "Jeffries")
        #expect(tenth.electedSpeaker == nil) // 212 of 430 cast for a person
    }

    @Test func electsASpeakerOnAMajorityOfVotesCastForAPerson() {
        // The fifteenth ballot of January 2023: McCarthy took 216 of 428, so a flat 218 threshold
        // would have missed it.
        let elected = Vote(
            id: "house-118-1-20", kind: .election, chamber: .house, congress: 118, session: 1,
            rollNumber: 20, question: "Election of the Speaker", billId: nil, nominationId: nil,
            billRef: nil, occurredAt: nil, state: .final, threshold: .majority,
            totals: VoteTotals(yea: 0, nay: 0, present: 6, notVoting: 0),
            candidates: [Candidate(name: "McCarthy", total: 216), Candidate(name: "Jeffries", total: 212)],
            result: "McCarthy"
        )
        #expect(elected.electedSpeaker?.name == "McCarthy")
        #expect(Vote.sampleElection.electedSpeaker == nil)
        // A question vote never elects anyone.
        #expect(Vote.sample.electedSpeaker == nil)
        #expect(Vote.sample.leadingCandidate == nil)
    }

    @Test func computesVotesNeededFromWhoVoted() {
        #expect(Vote.sample.votesNeeded == 216) // 430 voting -> 216
        #expect(Vote.sample.leader == .yea)
    }

    @Test func parsesTheRollCallTimestamp() throws {
        let date = try #require(Vote.sample.occurredAtDate)
        #expect(abs(date.timeIntervalSince1970 - 1_744_297_680) < 1) // 2025-04-10T15:08:00Z
    }

    @Test(arguments: [
        (VoteThreshold.majority, 435, 100, 218),
        (.majority, 408, 100, 205),
        (.twoThirds, 420, 100, 280),
        (.twoThirds, 421, 100, 281),
        (.threeFifthsSworn, 97, 100, 60),
        (.threeFifthsSworn, 99, 99, 60),
    ])
    func thresholdsMatchTheBackend(threshold: VoteThreshold, voting: Int, sworn: Int, needed: Int) {
        #expect(threshold.votesNeeded(voting: voting, sworn: sworn) == needed)
    }
}

@Suite("Bill")
struct BillTests {
    @Test func decodesARealBill() throws {
        let bill = try fixture("bill", as: Bill.self)
        #expect(bill.id == "119-hconres-14")
        #expect(bill.citation == "H.Con.Res. 14")
        #expect(bill.policyArea == "Economics and Public Finance")
        #expect(bill.latestAction != nil)
        #expect(!bill.actions.isEmpty)
        #expect(bill.actions.count <= 30)
        #expect(!bill.votes.isEmpty)
    }

    @Test func fallsBackToTheFullTitleWhenThereIsNoShortTitle() throws {
        let bill = try fixture("bill-no-short-title", as: Bill.self)
        #expect(bill.shortTitle == nil)
        #expect(bill.displayTitle == bill.title)
        #expect(!bill.displayTitle.isEmpty)
        // A bill can still have a sponsor and a chamber of origin.
        #expect(bill.sponsor?.lastName == "Gaetz")
        #expect(bill.originChamber == .house)
    }

    /// The citation is sent by the API rather than derived here, so a bill cannot be cited one way
    /// in a feed and another on its own screen. The formatting itself is covered server-side, in
    /// `apps/api/src/pg.test.ts`.
    @Test func takesItsCitationFromTheAPI() throws {
        #expect(try fixture("bill", as: Bill.self).citation == "H.Con.Res. 14")
        #expect(try fixture("bill-no-short-title", as: Bill.self).citation == "H.Con.Res. 21")
    }

    /// A legislative day is a date, not an instant. Parsed to midnight UTC and then formatted in
    /// a zone west of Greenwich, it renders as the day before.
    @Test func rendersACalendarDayWithoutDriftingAZoneWest() {
        #expect(Formats.dayText("2026-11-11") == "Nov 11, 2026")
        #expect(Formats.dayText("2025-01-01") == "Jan 1, 2025")
        #expect(Formats.dayText("not a day") == nil)
    }

    @Test func parsesCalendarDaysWithoutATimeZoneShift() throws {
        let bill = try fixture("bill", as: Bill.self)
        let day = try #require(bill.introducedOnDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(utc.component(.day, from: day) == 18) // introduced 2025-02-18
    }
}

@Suite("Nomination")
struct NominationTests {
    @Test func decodesASplitNomination() throws {
        let nomination = try fixture("nomination-split", as: Nomination.self)
        #expect(nomination.citation == "PN1093-3")
        #expect(nomination.part == 3)
        #expect(nomination.isMilitary == false)
        #expect(nomination.displayName == nomination.nomineeName)
    }

    @Test func namesThePostWhenAMilitaryNominationNamesNobody() throws {
        let nomination = try fixture("nomination-military", as: Nomination.self)
        #expect(nomination.isMilitary)
        #expect(nomination.nomineeName == nil)
        // Clients must fall back to the position and organization.
        #expect(nomination.displayName == "General, Army")
    }
}

@Suite("Member")
struct MemberTests {
    @Test func decodesAMemberWithTheirPartyRecord() throws {
        let detail = try fixture("member-detail", as: MemberDetail.self)
        #expect(detail.member.fullName == "Alma Adams")
        #expect(detail.member.partyAndSeat == "D-NC-12")
        #expect(detail.partyLoyalty.votes == 1871)
        let share = try #require(detail.partyLoyalty.withPartyShare)
        #expect(abs(share - 1847.0 / 1871.0) < 0.000_001)
    }

    @Test func reportsNoShareWhenThereIsNothingToCount() {
        // An independent has no party majority to be compared with, so the UI must show nothing.
        #expect(PartyLoyalty(votes: 0, withParty: 0, againstParty: 0).withPartyShare == nil)
    }

    @Test func decodesAMembersVotingRecord() throws {
        let record = try fixture("member-votes", as: MemberVotes.self)
        #expect(!record.votes.isEmpty)
        #expect(record.votes.allSatisfy { !$0.vote.id.isEmpty })
    }

    /// Each row names its measure, so a feed can label every card without a request per row.
    @Test func namesTheMeasureOnEachRow() throws {
        let record = try fixture("member-votes", as: MemberVotes.self)
        let first = try #require(record.votes.first)
        let measure = try #require(first.measure)
        #expect(measure.kind == .bill)
        #expect(measure.id == first.vote.billId)
        #expect(!measure.title.isEmpty)
        #expect(measure.headline == "\(measure.citation) · \(measure.title)")
        // A procedural vote refers to no measure at all.
        #expect(MemberVote.sampleProcedural.measure == nil)
        #expect(MemberVote.sampleProcedural.vote.billId == nil)
    }

    @Test func senatorsHaveNoDistrict() {
        #expect(Member.sampleSenator.district == nil)
        #expect(Member.sampleSenator.partyAndSeat == "R-TX")
    }

    @Test func namesAnAtLargeDistrict() {
        #expect(District(congress: 119, state: "WY", district: 0, countyFips: nil).name == "WY-AL")
        #expect(District.sample.name == "TX-37")
    }

    @Test func splitsADelegationIntoRepresentativeAndSenators() {
        #expect(Reps.sample.representative?.bioguideId == "A000370")
        #expect(Reps.sample.senators.map(\.bioguideId) == ["C001098"])
    }
}

@Suite("Status")
struct StatusTests {
    @Test func decodesTheFreshnessReport() throws {
        let status = try fixture("status", as: DataStatus.self)
        #expect(status.sources.map(\.source)
            == ["members", "house_rollcalls", "senate_rollcalls", "bills", "nominations"])
        #expect(status.ok == status.staleSources.isEmpty)
    }
}
