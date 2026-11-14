import Foundation

/// The most recent thing that happened to a bill or nomination.
public struct LatestAction: Codable, Sendable, Hashable {
    /// Calendar day, `YYYY-MM-DD`. See ``onDay``.
    public var on: String
    public var text: String

    public init(on: String, text: String) {
        self.on = on
        self.text = text
    }

    public var onDay: Date? { Formats.day(on) }
}

/// A Congressional Budget Office cost estimate.
public struct CboEstimate: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    public var url: String
    public var pubDate: String

    public var id: String { url }

    public init(title: String, url: String, pubDate: String) {
        self.title = title
        self.url = url
        self.pubDate = pubDate
    }
}

/// One step in a bill's history, newest first as the API returns them.
public struct BillAction: Codable, Sendable, Hashable, Identifiable {
    /// Calendar day, `YYYY-MM-DD`. See ``actedOnDay``.
    public var actedOn: String
    /// nil for actions the API could not attribute to a chamber.
    public var chamber: Chamber?
    public var text: String

    public var id: String { "\(actedOn)|\(text)" }

    public init(actedOn: String, chamber: Chamber?, text: String) {
        self.actedOn = actedOn
        self.chamber = chamber
        self.text = text
    }

    public var actedOnDay: Date? { Formats.day(actedOn) }
}

/// `GET /v1/bills/{id}`
public struct Bill: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var congress: Int
    /// `hr`, `s`, `hconres` and so on.
    public var type: String
    public var number: Int
    /// As the chamber cites it, e.g. `H.Con.Res. 14`. Sent by the API rather than derived here, so
    /// a bill cannot be cited one way in a feed and another on its own screen.
    public var citation: String
    public var title: String
    /// nil when the bill has no short title of its own. Some appropriations bills carry short
    /// titles only for their divisions, which the API deliberately does not use, so clients must
    /// fall back to ``title``.
    public var shortTitle: String?
    public var sponsor: Member?
    /// Calendar day, `YYYY-MM-DD`.
    public var introducedOn: String?
    public var originChamber: Chamber?
    public var policyArea: String?
    /// Latest Congressional Research Service summary, plain text.
    public var summary: String?
    /// The legislative stage that summary describes, e.g. `Passed Senate` or `Public Law`.
    public var summaryStage: String?
    public var latestAction: LatestAction?
    public var cboEstimates: [CboEstimate]
    public var actions: [BillAction]
    public var votes: [Vote]
    /// The plain short label a bill list gives it (``BillListItem/label``). nil in a response saved
    /// by a build before v0.2.29; use ``listLabel``.
    public var label: String?
    /// Where it stands on the road to law (``BillListItem/stage``): nil until the worker has staged
    /// it, for a stage newer than this build, and in a response saved before v0.2.29.
    public var stage: BillStage?

    public init(
        id: String, congress: Int, type: String, number: Int, citation: String, title: String, shortTitle: String?,
        sponsor: Member?, introducedOn: String?, originChamber: Chamber?, policyArea: String?,
        summary: String?, summaryStage: String?, latestAction: LatestAction?,
        cboEstimates: [CboEstimate], actions: [BillAction], votes: [Vote],
        label: String? = nil, stage: BillStage? = nil
    ) {
        self.id = id
        self.congress = congress
        self.type = type
        self.number = number
        self.citation = citation
        self.title = title
        self.shortTitle = shortTitle
        self.sponsor = sponsor
        self.introducedOn = introducedOn
        self.originChamber = originChamber
        self.policyArea = policyArea
        self.summary = summary
        self.summaryStage = summaryStage
        self.latestAction = latestAction
        self.cboEstimates = cboEstimates
        self.actions = actions
        self.votes = votes
        self.label = label
        self.stage = stage
    }

    private enum CodingKeys: String, CodingKey {
        case id, congress, type, number, citation, title, shortTitle, sponsor, introducedOn, originChamber
        case policyArea, summary, summaryStage, latestAction, cboEstimates, actions, votes, label, stage
    }

    /// As synthesized, except that a stage this build does not know reads as nil (as on
    /// ``BillListItem``), so a stage added on the server cannot fail a whole bill.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        congress = try c.decode(Int.self, forKey: .congress)
        type = try c.decode(String.self, forKey: .type)
        number = try c.decode(Int.self, forKey: .number)
        citation = try c.decode(String.self, forKey: .citation)
        title = try c.decode(String.self, forKey: .title)
        shortTitle = try c.decodeIfPresent(String.self, forKey: .shortTitle)
        sponsor = try c.decodeIfPresent(Member.self, forKey: .sponsor)
        introducedOn = try c.decodeIfPresent(String.self, forKey: .introducedOn)
        originChamber = try c.decodeIfPresent(Chamber.self, forKey: .originChamber)
        policyArea = try c.decodeIfPresent(String.self, forKey: .policyArea)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryStage = try c.decodeIfPresent(String.self, forKey: .summaryStage)
        latestAction = try c.decodeIfPresent(LatestAction.self, forKey: .latestAction)
        cboEstimates = try c.decode([CboEstimate].self, forKey: .cboEstimates)
        actions = try c.decode([BillAction].self, forKey: .actions)
        votes = try c.decode([Vote].self, forKey: .votes)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        stage = try c.decodeIfPresent(String.self, forKey: .stage).flatMap(BillStage.init(rawValue:))
    }

    /// What a list calls it: the API's label, else (a response saved before v0.2.29) its display title.
    public var listLabel: String { label ?? displayTitle }

    /// What a vote on this bill was about, as a feed card names it.
    public var measure: MeasureSummary {
        MeasureSummary(id: id, kind: .bill, citation: citation, title: displayTitle, policyArea: policyArea)
    }

    /// What to show as the bill's name: its short title where it has one, its full title otherwise.
    public var displayTitle: String { shortTitle ?? title }

    public var introducedOnDay: Date? { introducedOn.flatMap(Formats.day) }
}
