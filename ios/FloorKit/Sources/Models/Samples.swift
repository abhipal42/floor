import Foundation

/// Real values from staging, for previews and tests.
///
/// Every model has one, and `ContractTests` encodes each to check its fields against the committed
/// `apps/api/openapi.json`, so a model that drifts from the API is caught here rather than on a
/// phone. Keep one sample per model.

public extension Member {
    /// Alma Adams, D-NC-12.
    static let sample = Member(
        bioguideId: "A000370", firstName: "Alma", lastName: "Adams", party: "D", state: "NC",
        district: 12, chamber: .house
    )

    /// A senator, so `district` is nil.
    static let sampleSenator = Member(
        bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
        district: nil, chamber: .senate
    )
}

public extension VoteTotals {
    static let sample = VoteTotals(yea: 216, nay: 214, present: 0, notVoting: 3)
}

public extension Candidate {
    static let sample = Candidate(name: "Jeffries", total: 212)
}

public extension Vote {
    /// House roll call 100 of 2025: H.Con.Res. 14 concurred, 216-214.
    static let sample = Vote(
        id: "house-119-1-100", kind: .question, chamber: .house, congress: 119, session: 1,
        rollNumber: 100, question: "On Motion to Concur in the Senate Amendment",
        billId: "119-hconres-14", nominationId: nil, billRef: "H CON RES 14",
        occurredAt: "2025-04-10T15:08:00.000Z", state: .final, threshold: .majority,
        totals: .sample, candidates: [], result: "Passed"
    )

    /// The tenth ballot of the January 2023 Speaker election, which elected nobody: Jeffries led
    /// with 212 of the 433 cast for a person, short of the 217 needed.
    static let sampleElection = Vote(
        id: "house-118-1-10", kind: .election, chamber: .house, congress: 118, session: 1,
        rollNumber: 10, question: "Election of the Speaker", billId: nil, nominationId: nil,
        billRef: nil, occurredAt: "2023-01-05T20:01:00.000Z", state: .final, threshold: .majority,
        totals: VoteTotals(yea: 0, nay: 0, present: 1, notVoting: 0),
        candidates: [
            Candidate(name: "Jeffries", total: 212),
            Candidate(name: "McCarthy", total: 201),
            Candidate(name: "Donalds", total: 17),
        ],
        result: "Jeffries"
    )
}

public extension PartyTotals {
    static let sample = PartyTotals(party: "R", yea: 216, nay: 2, present: 0, notVoting: 2)
}

public extension CandidateTotal {
    static let sample = CandidateTotal(party: "D", candidate: "Jeffries", total: 212)
}

public extension MemberPosition {
    static let sample = MemberPosition(member: .sample, position: .nay, choice: nil)
}

public extension VoteDetail {
    static let sample = VoteDetail(
        vote: .sample,
        partyTotals: [
            PartyTotals(party: "R", yea: 216, nay: 2, present: 0, notVoting: 2),
            PartyTotals(party: "D", yea: 0, nay: 212, present: 0, notVoting: 1),
        ],
        candidateTotals: [],
        positions: [.sample]
    )
}

public extension PartyLoyalty {
    static let sample = PartyLoyalty(votes: 1871, withParty: 1847, againstParty: 24)
}

public extension MemberDetail {
    static let sample = MemberDetail(member: .sample, partyLoyalty: .sample)
}

public extension MeasureSummary {
    static let sample = MeasureSummary(
        id: "119-hconres-14", kind: .bill, citation: "H.Con.Res. 14",
        title: "Establishing the congressional budget for fiscal year 2025"
    )
}

public extension MemberVote {
    static let sample = MemberVote(vote: .sample, position: .nay, choice: nil, measure: .sample)

    /// A procedural vote refers to no measure.
    static let sampleProcedural = MemberVote(
        vote: Vote(
            id: "house-119-1-5", kind: .question, chamber: .house, congress: 119, session: 1,
            rollNumber: 5, question: "On Motion to Adjourn", billId: nil, nominationId: nil,
            billRef: "ADJOURN", occurredAt: nil, state: .final, threshold: .majority,
            totals: VoteTotals(yea: 201, nay: 210, present: 0, notVoting: 24), candidates: [],
            result: "Failed"
        ),
        position: .nay, choice: nil, measure: nil
    )
}

public extension MemberVotes {
    static let sample = MemberVotes(votes: [.sample])
}

public extension District {
    static let sample = District(congress: 119, state: "TX", district: 37, countyFips: "48453")
}

public extension Reps {
    static let sample = Reps(district: .sample, members: [.sample, .sampleSenator])
}

public extension LatestAction {
    static let sample = LatestAction(on: "2025-05-20", text: "Star Print ordered.")
}

public extension CboEstimate {
    static let sample = CboEstimate(
        title: "CBO estimate", url: "https://www.cbo.gov/publication/61420",
        pubDate: "2025-02-24T00:00:00Z"
    )
}

public extension BillAction {
    static let sample = BillAction(
        actedOn: "2025-04-10", chamber: .house, text: "On motion to concur Agreed to by the Yeas and Nays: 216 - 214."
    )
}

public extension Bill {
    static let sample = Bill(
        id: "119-hconres-14", congress: 119, type: "hconres", number: 14, citation: "H.Con.Res. 14",
        title: "Establishing the congressional budget for the United States Government for fiscal year 2025.",
        shortTitle: nil, sponsor: nil, introducedOn: "2025-02-18", originChamber: .house,
        policyArea: "Economics and Public Finance",
        summary: "This concurrent resolution establishes the congressional budget.",
        summaryStage: "Introduced in House", latestAction: .sample, cboEstimates: [.sample],
        actions: [.sample], votes: [.sample]
    )
}

public extension Nomination {
    /// A split nomination: the Senate cites it as PN1093-3.
    static let sample = Nomination(
        id: "119-pn-1093-3", congress: 119, number: 1093, part: 3, citation: "PN1093-3",
        nomineeName: "Matthew R. Byrne",
        positionTitle: "United States District Judge for the Southern District of Ohio",
        organization: "The Judiciary",
        description: "Matthew R. Byrne, of Ohio, to be United States District Judge.",
        nomineeCount: 1, isMilitary: false, receivedOn: "2026-06-15",
        latestAction: LatestAction(on: "2026-09-15", text: "Confirmed by the Senate by Yea-Nay Vote. 52 - 45."),
        votes: []
    )

    /// A military nomination, which names no nominee at all.
    static let sampleMilitary = Nomination(
        id: "118-pn-537", congress: 118, number: 537, part: 0, citation: "PN537",
        nomineeName: nil, positionTitle: "General", organization: "Army", description: nil,
        nomineeCount: 1, isMilitary: true, receivedOn: "2023-03-28",
        latestAction: LatestAction(on: "2023-09-21", text: "Confirmed by the Senate by Voice Vote."),
        votes: []
    )
}

public extension SourceStatus {
    static let sample = SourceStatus(
        source: "house_rollcalls", lastSuccessAt: "2026-11-11T20:00:00.000Z", lastError: nil, stale: false
    )
}

public extension DataStatus {
    static let sample = DataStatus(ok: true, sources: [.sample])
}

public extension APIError {
    static let sample = APIError(error: "No vote with ID senate-119-1-9999")
}
