import Foundation

/// `GET /v1/schedule`: the week ahead. The House's list of what may come up, and when the Senate
/// meets with the Daily Digest's program for that day. Listed is not scheduled: items move.

/// How the House plans to take an item up.
public enum ScheduleCategory: String, Codable, Sendable, Hashable, CaseIterable {
    /// Under a special rule.
    case rule
    /// Under suspension of the rules: short debate, no amendments, two-thirds.
    case suspension
    /// Anything else, including every Senate item.
    case other
}

public struct ScheduleItem: Codable, Sendable, Hashable {
    public var category: ScheduleCategory
    public var categoryText: String
    /// nil for a resolution not yet numbered, or a bill not in Floor's catalog yet.
    public var billId: String?
    /// The citation, e.g. `H.R. 5267`.
    public var label: String
    public var title: String
    /// What the source printed for the item.
    public var sourceText: String
    public var policyArea: String?
    /// nil until staged, and for a stage newer than this build.
    public var stage: BillStage?
    public var latestAction: LatestAction?
    public var addedAt: String?
    /// Set once the item was taken off the week's list.
    public var removedAt: String?

    public init(
        category: ScheduleCategory, categoryText: String, billId: String?, label: String, title: String,
        sourceText: String, policyArea: String?, stage: BillStage?, latestAction: LatestAction?,
        addedAt: String?, removedAt: String?
    ) {
        self.category = category
        self.categoryText = categoryText
        self.billId = billId
        self.label = label
        self.title = title
        self.sourceText = sourceText
        self.policyArea = policyArea
        self.stage = stage
        self.latestAction = latestAction
        self.addedAt = addedAt
        self.removedAt = removedAt
    }

    private enum CodingKeys: String, CodingKey {
        case category, categoryText, billId, label, title, sourceText, policyArea, stage, latestAction, addedAt, removedAt
    }

    /// A stage or category this build does not know decodes as nil or `.other` rather than failing the week.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = ScheduleCategory(rawValue: try c.decode(String.self, forKey: .category)) ?? .other
        categoryText = try c.decode(String.self, forKey: .categoryText)
        billId = try c.decodeIfPresent(String.self, forKey: .billId)
        label = try c.decode(String.self, forKey: .label)
        title = try c.decode(String.self, forKey: .title)
        sourceText = try c.decode(String.self, forKey: .sourceText)
        policyArea = try c.decodeIfPresent(String.self, forKey: .policyArea)
        stage = try c.decodeIfPresent(String.self, forKey: .stage).flatMap(BillStage.init(rawValue:))
        latestAction = try c.decodeIfPresent(LatestAction.self, forKey: .latestAction)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        removedAt = try c.decodeIfPresent(String.self, forKey: .removedAt)
    }
}

public struct SenateMeeting: Codable, Sendable, Hashable {
    /// `YYYY-MM-DD`.
    public var date: String
    public var convenesAt: String?
    /// The Senate meets for seconds and does no business.
    public var proForma: Bool
    /// The Daily Digest's heading, e.g. `3 p.m., Monday, November 16`.
    public var heading: String?
    /// The Daily Digest's program, in its own words; nil until the Record is out.
    public var program: String?
    public var recordIssue: String?

    public init(date: String, convenesAt: String?, proForma: Bool, heading: String?, program: String?, recordIssue: String?) {
        self.date = date
        self.convenesAt = convenesAt
        self.proForma = proForma
        self.heading = heading
        self.program = program
        self.recordIssue = recordIssue
    }
}

public struct Schedule: Codable, Sendable, Hashable {
    public struct House: Codable, Sendable, Hashable {
        /// true when the House has published a list for the week; nil when it has not.
        public var inSession: Bool?
        public var items: [ScheduleItem]

        public init(inSession: Bool?, items: [ScheduleItem]) {
            self.inSession = inSession
            self.items = items
        }
    }

    public struct Senate: Codable, Sendable, Hashable {
        public var meetings: [SenateMeeting]
        public var items: [ScheduleItem]

        public init(meetings: [SenateMeeting], items: [ScheduleItem]) {
            self.meetings = meetings
            self.items = items
        }
    }

    /// The Monday, `YYYY-MM-DD`.
    public var week: String
    public var house: House
    public var senate: Senate?
    /// Why ``senate`` is nil.
    public var senateReason: String?
    public var sourceUpdatedAt: String?

    public init(week: String, house: House, senate: Senate?, senateReason: String?, sourceUpdatedAt: String?) {
        self.week = week
        self.house = house
        self.senate = senate
        self.senateReason = senateReason
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

// Samples: the real week of 2026-11-16 as the ingest stored it on 2026-11-14.

public extension ScheduleItem {
    static let sample = ScheduleItem(
        category: .suspension, categoryText: "Items that may be considered under suspension of the rules",
        billId: nil, label: "H.R. 7954", title: "Don Young Doug LaMalfa Indian Buffalo Management Act",
        sourceText: "Don Young Doug LaMalfa Indian Buffalo Management Act", policyArea: nil, stage: nil,
        latestAction: nil, addedAt: "2026-11-11T15:29:34.797Z", removedAt: nil
    )
}

public extension SenateMeeting {
    static let sample = SenateMeeting(
        date: "2026-11-16", convenesAt: "2026-11-16T20:00:00.000Z", proForma: false,
        heading: "3 p.m., Monday, November 16",
        program: "Senate will resume consideration of the nomination of Daniel Desmond Domenico, of Colorado, to be United States Circuit Judge for the Tenth Circuit, and vote on confirmation thereon at 5:30 p.m.",
        recordIssue: "172/171"
    )
}

public extension Schedule {
    static let sample = Schedule(
        week: "2026-11-16",
        house: House(inSession: true, items: [.sample]),
        senate: Senate(meetings: [.sample], items: []),
        senateReason: nil,
        sourceUpdatedAt: "2026-11-13T22:02:23.730Z"
    )
}

public extension VoteExplainer {
    static let sample = VoteExplainer(
        kind: "cloture",
        text: "A vote to end debate so the Senate can move to a final vote. On a bill it needs three-fifths of senators sworn in, 60 when the Senate is full. Passing cloture doesn't pass the bill.",
        source: "Senate Rule XXII, paragraph 2"
    )
}

public extension VoteKindInfo {
    static let sample = VoteKindInfo(
        kind: "suspension",
        text: "House fast track for bills with broad support. Short debate, no amendments, needs two-thirds.",
        source: "House Rule XV, clause 1", chamber: .house, when: nil,
        questions: ["On Motion to Suspend the Rules and Pass"]
    )
}

public extension MemberContact {
    static let sample = MemberContact(
        phone: "202-225-1510", contactForm: nil, website: "https://adams.house.gov",
        office: "2436 Rayburn House Office Building",
        address: "2436 Rayburn House Office Building Washington DC 20515-3312"
    )
}
