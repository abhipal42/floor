import Foundation
import Models
import Onboarding

// The widget gallery's placeholder and snapshot: TX-37 as staging returned it on 2026-11-12.
// Copied from `Tests/ModelsTests/Fixtures/reps-location-austin.json` and the three
// `member-votes-*-40.json` files, and `WidgetFeedTests` checks they still match, so the gallery
// never shows an invented vote.

public extension WidgetSnapshot {
    static let sample: WidgetSnapshot = .make(
        delegation: .sampleTX37,
        records: [
            Member.doggett.bioguideId: [.doggettHR1013],
            Member.cornyn.bioguideId: [.hr2347Proceed(.notVoting)],
            Member.cruz.bioguideId: [.hr2347Proceed(.yea)],
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_794_528_000) // 2026-11-13 00:00 UTC
    )
}

public extension Delegation {
    /// Austin, TX-37: Doggett, Cornyn, Cruz.
    static let sampleTX37 = Delegation(
        district: District(congress: 119, state: "TX", district: 37, countyFips: "48453"),
        members: [.doggett, .cornyn, .cruz],
        resolvedAt: Date(timeIntervalSince1970: 1_794_528_000)
    )
}

extension Member {
    static let doggett = Member(
        bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
        district: 37, chamber: .house
    )
    static let cornyn = Member(
        bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX",
        district: nil, chamber: .senate
    )
    static let cruz = Member(
        bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
        district: nil, chamber: .senate
    )
}

extension MemberVote {
    /// House roll 321 of 2026: H.R. 1013 passed 295–128. Doggett voted nay.
    static let doggettHR1013 = MemberVote(
        vote: Vote(
            id: "house-119-2-321", kind: .question, chamber: .house, congress: 119, session: 2,
            rollNumber: 321, question: "On Passage", billId: "119-hr-1013", nominationId: nil,
            billRef: "H R 1013", occurredAt: "2026-11-11T19:43:00.000Z", state: .final,
            threshold: .majority, totals: VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10),
            candidates: [], result: "Passed"
        ),
        position: .nay, choice: nil,
        measure: MeasureSummary(
            id: "119-hr-1013", kind: .bill, citation: "H.R. 1013",
            title: "Retirement Fairness for Charities and Educational Institutions Act of 2025"
        )
    )

    /// Senate roll 258 of 2026: the motion to proceed to H.R. 2347, agreed 62–21. Cornyn did not
    /// vote; Cruz voted yea.
    static func hr2347Proceed(_ position: Position) -> MemberVote {
        MemberVote(
            vote: Vote(
                id: "senate-119-2-258", kind: .question, chamber: .senate, congress: 119, session: 2,
                rollNumber: 258, question: "On the Motion to Proceed", billId: "119-hr-2347",
                nominationId: nil, billRef: "H.R. 2347", occurredAt: "2026-11-11T00:37:00.000Z",
                state: .final, threshold: .majority,
                totals: VoteTotals(yea: 62, nay: 21, present: 0, notVoting: 17),
                candidates: [], result: "Motion to Proceed Agreed to"
            ),
            position: position, choice: nil,
            measure: MeasureSummary(
                id: "119-hr-2347", kind: .bill, citation: "H.R. 2347", title: "Survivor Justice Tax Prevention Act"
            )
        )
    }
}
