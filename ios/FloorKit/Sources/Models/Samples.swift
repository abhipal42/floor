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
        positions: [.sample],
        measure: .sample
    )
}

public extension PartyLoyalty {
    static let sample = PartyLoyalty(votes: 1871, withParty: 1847, againstParty: 24)
}

public extension MemberDetail {
    static let sample = MemberDetail(member: .sample, partyLoyalty: .sample)
}

public extension PacCheck {
    /// The American Dental Association's PAC to Hakeem Jeffries, 2025–26.
    static let sample = PacCheck(
        committeeId: "C00000729", name: "AMERICAN DENTAL ASSOCIATION POLITICAL ACTION COMMITTEE",
        kind: "Membership group", orgType: "M", connectedOrg: "INDIANA DENTAL PAC", direct: 10000, earmarked: 0
    )
}

public extension Funding {
    /// Hakeem Jeffries' 2026 campaign through Oct 14, 2026.
    static let sample = Funding(
        cycle: 2026, coverageStart: "2025-01-01", coverageEnd: "2026-10-14", receipts: 17_893_352.11,
        smallDollar: 8_147_893.38, itemized: 4_542_828.45, pac: 2_765_400, party: 0, other: 2_437_230.28,
        cashOnHand: 4_234_848.33, committeesCycle: 2026, committees: [.sample]
    )
}

public extension MemberFunding {
    static let sample = MemberFunding(
        member: Member(
            bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D", state: "NY",
            district: 8, chamber: .house
        ),
        funding: .sample
    )
}

public extension MeasureSummary {
    static let sample = MeasureSummary(
        id: "119-hconres-14", kind: .bill, citation: "H.Con.Res. 14",
        title: "Establishing the congressional budget for fiscal year 2025",
        policyArea: "Economics and Public Finance"
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

public extension AnalysisCitation {
    static let sample = AnalysisCitation(
        paragraph: 1, quote: "designates the facility of the United States Postal Service", section: nil
    )
}

public extension AnalysisClaim {
    /// For tests and previews only: real analyses come from the API, never from the app.
    static let sample = AnalysisClaim(
        text: "Names the post office at 616 East Main Street in St. Charles, Illinois, for Vietnam War veterans.",
        citations: [.sample]
    )
}

public extension AnalysisSource {
    /// The real CRS summary of H.R. 2379 (118th), Public Law stage.
    static let sample = AnalysisSource(
        kind: "crs_summary", stage: "Public Law",
        paragraphs: [
            "This bill designates the facility of the United States Postal Service located at 616 East Main Street in St. Charles, Illinois, as the Veterans of the Vietnam War Memorial Post Office.",
        ],
        stale: false
    )
}

public extension BillAnalysis {
    static let sample = BillAnalysis(
        billId: "118-hr-2379", label: "AI-generated",
        disclaimer: "Written by AI from the Congressional Research Service summary, and checked against it by a second AI pass. It may contain errors. Each line links to the paragraph it came from; read that before relying on it.",
        source: .sample, model: "claude-sonnet-5-5", verifierModel: "claude-sonnet-5-5",
        promptVersion: "bill-analysis/1", generatedAt: "2026-11-13T12:00:00.000Z",
        provisions: [], affectedGroups: [], impact: [], purpose: .sample
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
        actions: [.sample], votes: [.sample],
        label: "Establishing the congressional budget for the United States Government for fiscal year 2025.",
        stage: .passedHouse
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
        source: "house_rollcalls", lastSuccessAt: "2026-11-11T20:00:00.000Z",
        lastNewDataAt: "2026-11-11T20:00:00.000Z", lastError: nil, stale: false
    )
}

public extension DataStatus {
    static let sample = DataStatus(ok: true, sources: [.sample])
}

public extension APIError {
    static let sample = APIError(error: "No vote with ID senate-119-1-9999")
}

public extension ChamberStatus {
    /// The House mid-session on 2026-11-10, as the live worker records it.
    static let sample = ChamberStatus(
        chamber: .house, inSession: true, convenesAt: nil, legislativeDay: "2026-11-10",
        checkedAt: "2026-11-10T23:33:00.000Z"
    )
}

public extension LiveVote {
    /// House roll 319 of 2026 (H. Res. 1650) between the floor summary naming it and its XML posting.
    static let sample = LiveVote(
        vote: Vote(
            id: "house-119-2-319", kind: .question, chamber: .house, congress: 119, session: 2,
            rollNumber: 319, question: "On agreeing to the resolution", billId: nil, nominationId: nil,
            billRef: "H. Res. 1650", occurredAt: "2026-11-10T23:20:53.000Z", state: .open,
            threshold: .majority, totals: VoteTotals(yea: 215, nay: 209, present: 0, notVoting: 0),
            candidates: [], result: "Agreed to"
        ),
        openedAt: "2026-11-10T23:20:53.000Z", announcedAt: "2026-11-10T23:33:00.000Z", postedAt: nil
    )
}

public extension Live {
    static let sample = Live(chambers: [.sample], votes: [.sample])
}
