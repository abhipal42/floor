import Foundation

// Preview and test samples for Topics.swift: real bills from Floor's database on 2026-11-13.

public extension BillListItem {
    /// H.R. 2493: passed the House, on the Senate calendar since April, so stalled by now.
    static let sample = BillListItem(
        id: "119-hr-2493", congress: 119, type: "hr", number: 2493, citation: "H.R. 2493",
        label: "Improving Care in Rural America Reauthorization Act of 2025",
        title: "Improving Care in Rural America Reauthorization Act of 2025",
        policyArea: "Health", stage: .passedHouse, stalled: true,
        latestAction: LatestAction(on: "2026-04-22", text: "Received in the Senate and Read twice and referred to the Committee on Health, Education, Labor, and Pensions."),
        hasFloorVote: true
    )

    /// S.J.Res. 197: a disapproval resolution whose motion to proceed failed 48–51.
    static let sampleDisapproval = BillListItem(
        id: "119-sjres-197", congress: 119, type: "sjres", number: 197, citation: "S.J.Res. 197",
        label: "Disapproving the Centers for Medicare & Medicaid Services' rule: Medicare and Medicaid Programs; Contract Year 2027 Policy and Technical Changes",
        title: "A joint resolution providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Centers for Medicare & Medicaid Services relating to \"Medicare and Medicaid Programs; Contract Year 2027 Policy and Technical Changes\".",
        policyArea: "Health", stage: .introduced, stalled: false,
        latestAction: LatestAction(on: "2026-09-29", text: "Motion to proceed to consideration of measure not agreed to in Senate by Yea-Nay Vote. 48 - 51."),
        hasFloorVote: true
    )
}

public extension Topic {
    static let sample = Topic(name: "Health", bills: 29, billsWithFloorVote: 29, latestActionOn: "2026-09-29")
}

public extension TopicList {
    static let sample = TopicList(congress: 119, topics: [.sample])
}

public extension TopicBills {
    static let sample = TopicBills(
        congress: 119, topic: .sample, filter: .all, bills: [.sampleDisapproval, .sample], nextCursor: nil
    )
}

public extension SearchResults {
    static let sample = SearchResults(
        query: "rural health", billNumber: false, members: [], bills: [.sample], topics: [.sample]
    )
}
