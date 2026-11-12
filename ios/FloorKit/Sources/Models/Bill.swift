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

    public init(
        id: String, congress: Int, type: String, number: Int, title: String, shortTitle: String?,
        sponsor: Member?, introducedOn: String?, originChamber: Chamber?, policyArea: String?,
        summary: String?, summaryStage: String?, latestAction: LatestAction?,
        cboEstimates: [CboEstimate], actions: [BillAction], votes: [Vote]
    ) {
        self.id = id
        self.congress = congress
        self.type = type
        self.number = number
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
    }

    /// What to show as the bill's name: its short title where it has one, its full title otherwise.
    public var displayTitle: String { shortTitle ?? title }

    /// How the chamber cites it, e.g. `H.Con.Res. 14`.
    public var citation: String {
        let label: String
        switch type {
        case "hr": label = "H.R."
        case "s": label = "S."
        case "hres": label = "H.Res."
        case "sres": label = "S.Res."
        case "hjres": label = "H.J.Res."
        case "sjres": label = "S.J.Res."
        case "hconres": label = "H.Con.Res."
        case "sconres": label = "S.Con.Res."
        default: label = type.uppercased()
        }
        return "\(label) \(number)"
    }

    public var introducedOnDay: Date? { introducedOn.flatMap(Formats.day) }
}
