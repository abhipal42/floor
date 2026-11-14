import Foundation

/// Where a measure stands on the road to law, as the worker derives it from Congress.gov's summary
/// markers and the chambers' passage roll calls (`apps/worker/src/stage.ts`).
///
/// The Following tab's five-step road reads it as: introduced, passed one chamber, passed both, to
/// the President, law. ``adopted`` is a resolution agreed to by every chamber it needs (it never
/// goes to the President); ``failed`` is a chamber voting it down; ``vetoed`` is vetoed and not
/// overridden.
public enum BillStage: String, Codable, Sendable, Hashable, CaseIterable {
    case introduced
    case passedHouse = "passed_house"
    case passedSenate = "passed_senate"
    case passedBoth = "passed_both"
    case toPresident = "to_president"
    case law, vetoed, failed, adopted

    /// Nothing more will happen to the measure.
    public var isSettled: Bool {
        [.law, .vetoed, .failed, .adopted].contains(self)
    }

    /// Steps reached on the five-step road, introduced = 1 to law = 5. A vetoed bill reached the
    /// President (4). nil for a failed measure and an adopted resolution: the stage does not say how
    /// far a failed one got, and a resolution's road does not end at the President.
    public var roadSteps: Int? {
        switch self {
        case .introduced: 1
        case .passedHouse, .passedSenate: 2
        case .passedBoth: 3
        case .toPresident, .vetoed: 4
        case .law: 5
        case .failed, .adopted: nil
        }
    }
}

/// The filters on a topic page. `moving` and `stalled` split the unsettled bills at 90 days without
/// an action; "stalled" describes, it does not predict.
public enum TopicFilter: String, Codable, Sendable, Hashable, CaseIterable {
    case all, moving, law, stalled
}

/// One row of a bill list: a topic page or search results.
public struct BillListItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var congress: Int
    public var type: String
    public var number: Int
    /// As the chamber cites it, e.g. `H.R. 2493`.
    public var citation: String
    /// A plain short label: the short title, or a deterministic rewrite of a long CRS title
    /// ("Disapproving the Department of Education's rule: …"). The full title is ``title``.
    public var label: String
    public var title: String
    public var policyArea: String?
    /// nil until the worker has staged the bill (a bill known only from Congress.gov's list), and for
    /// a stage newer than this build.
    public var stage: BillStage?
    /// Not settled and no action in 90 days, computed by the API when it answered.
    public var stalled: Bool
    public var latestAction: LatestAction?
    /// At least one recorded roll call on it.
    public var hasFloorVote: Bool

    public init(
        id: String, congress: Int, type: String, number: Int, citation: String, label: String, title: String,
        policyArea: String?, stage: BillStage?, stalled: Bool, latestAction: LatestAction?, hasFloorVote: Bool
    ) {
        self.id = id
        self.congress = congress
        self.type = type
        self.number = number
        self.citation = citation
        self.label = label
        self.title = title
        self.policyArea = policyArea
        self.stage = stage
        self.stalled = stalled
        self.latestAction = latestAction
        self.hasFloorVote = hasFloorVote
    }

    private enum CodingKeys: String, CodingKey {
        case id, congress, type, number, citation, label, title, policyArea, stage, stalled, latestAction, hasFloorVote
    }

    /// Decodes a stage this build does not know (one the server adds later) as nil, "not staged",
    /// rather than failing: one new stage must not empty a whole topic page or search result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        congress = try c.decode(Int.self, forKey: .congress)
        type = try c.decode(String.self, forKey: .type)
        number = try c.decode(Int.self, forKey: .number)
        citation = try c.decode(String.self, forKey: .citation)
        label = try c.decode(String.self, forKey: .label)
        title = try c.decode(String.self, forKey: .title)
        policyArea = try c.decodeIfPresent(String.self, forKey: .policyArea)
        stage = try c.decodeIfPresent(String.self, forKey: .stage).flatMap(BillStage.init(rawValue:))
        stalled = try c.decode(Bool.self, forKey: .stalled)
        latestAction = try c.decodeIfPresent(LatestAction.self, forKey: .latestAction)
        hasFloorVote = try c.decode(Bool.self, forKey: .hasFloorVote)
    }
}

/// A topic: one of the 32 policy areas the Congressional Research Service assigns, one per bill.
public struct Topic: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Bills in this topic in the Congress asked about.
    public var bills: Int
    public var billsWithFloorVote: Int
    /// Calendar day, `YYYY-MM-DD`.
    public var latestActionOn: String?

    public var id: String { name }

    public init(name: String, bills: Int, billsWithFloorVote: Int, latestActionOn: String?) {
        self.name = name
        self.bills = bills
        self.billsWithFloorVote = billsWithFloorVote
        self.latestActionOn = latestActionOn
    }
}

/// `GET /v1/topics` — all 32, in a fixed order, including empty ones.
public struct TopicList: Codable, Sendable, Hashable {
    public var congress: Int
    public var topics: [Topic]

    public init(congress: Int, topics: [Topic]) {
        self.congress = congress
        self.topics = topics
    }
}

/// `GET /v1/topics/{name}/bills` — one page, newest action first.
public struct TopicBills: Codable, Sendable, Hashable {
    public var congress: Int
    public var topic: Topic
    public var filter: TopicFilter
    public var bills: [BillListItem]
    /// Pass back as `cursor` for the next page; nil on the last.
    public var nextCursor: String?

    public init(congress: Int, topic: Topic, filter: TopicFilter, bills: [BillListItem], nextCursor: String?) {
        self.congress = congress
        self.topic = topic
        self.filter = filter
        self.bills = bills
        self.nextCursor = nextCursor
    }
}

/// `GET /v1/search?q=` — members, bills and topics, grouped.
public struct SearchResults: Codable, Sendable, Hashable {
    public var query: String
    /// The query read as a bill number ("hr 1013"): `bills` holds exact matches and nothing else is searched.
    public var billNumber: Bool
    public var members: [Member]
    public var bills: [BillListItem]
    public var topics: [Topic]

    public init(query: String, billNumber: Bool, members: [Member], bills: [BillListItem], topics: [Topic]) {
        self.query = query
        self.billNumber = billNumber
        self.members = members
        self.bills = bills
        self.topics = topics
    }
}
