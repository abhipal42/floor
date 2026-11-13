import Foundation

/// Whether a question vote carried, and where its threshold sat.
///
/// Every screen that draws a scoreboard draws the same yellow line, so the arithmetic lives here
/// once: the feed card, the catch-up deck, the vote screen and the bill's key plays all read it.
public struct ThresholdLine: Sendable, Hashable {
    /// Yea, nay and present — what the bar is drawn across. Present counts because the API's
    /// ``VoteThreshold/votesNeeded(voting:sworn:)`` counts it.
    public var cast: Int
    public var yea: Int
    public var nay: Int
    /// Yea votes the question needed.
    public var needed: Int
    public var threshold: VoteThreshold
    /// What the chamber recorded, when its result wording says; nil while open or unfamiliar.
    public var recorded: Vote.Outcome?

    public init(vote: Vote) {
        cast = vote.totals.voting
        yea = vote.totals.yea
        nay = vote.totals.nay
        needed = vote.votesNeeded
        threshold = vote.threshold
        recorded = vote.state == .final ? vote.recordedOutcome : nil
    }

    /// How far yea finished from the line: positive is over it, negative short of it.
    public var margin: Int { yea - needed }

    /// True when the count and the chamber's record disagree: a Vice President's tie-break, a
    /// unanimous-consent 60-vote bar on a vote reported as majority, "present" votes the
    /// arithmetic counts and the House does not. The record wins, so the line has nothing to say.
    public var contradicted: Bool {
        guard let recorded else { return false }
        return (recorded == .carried) != (margin >= 0)
    }

    /// Yea votes past the line, or nil when it fell short or the record says otherwise.
    public var over: Int? { !contradicted && margin >= 0 ? margin : nil }

    /// Yea votes it still needed, or nil once the line was met or the record says otherwise.
    public var short: Int? { !contradicted && margin < 0 ? -margin : nil }

    /// Share of the bar the yea fill takes, 0…1.
    public var yeaShare: Double { cast > 0 ? Double(yea) / Double(cast) : 0 }

    /// Where the yellow line sits on the bar, 0…1. Cloture needs 60 of 100 sworn whoever votes, so
    /// with absentees its line sits further right than 60% of the bar — which is the point.
    public var lineShare: Double { cast > 0 ? min(1, Double(needed) / Double(cast)) : 0.5 }

    /// The short name for what was needed, as the cards print it in the threshold yellow.
    public var label: String {
        switch threshold {
        case .majority: "MAJORITY"
        case .twoThirds: "TWO-THIRDS"
        case .threeFifthsSworn: "60 OF 100"
        }
    }
}

public extension Vote {
    enum Outcome: String, Sendable, Hashable {
        case carried, failed
    }

    /// The threshold arithmetic, or nil for a Speaker election, which has no yea/nay sides.
    var line: ThresholdLine? { kind == .question ? ThresholdLine(vote: self) : nil }

    /// Whether the question carried, or nil for a Speaker election or a vote not yet final.
    ///
    /// The chamber's own result is the authority: the arithmetic can disagree with it (a Vice
    /// President breaking a Senate tie, a unanimous-consent agreement setting a 60-vote bar on a
    /// passage vote). Rejection words are checked first because "Not Agreed to" contains "Agreed".
    /// Only when the result is missing or unfamiliar does the threshold decide.
    var outcome: Outcome? {
        guard kind == .question, state == .final else { return nil }
        if let recordedOutcome { return recordedOutcome }
        guard let line else { return nil }
        return line.margin >= 0 ? .carried : .failed
    }

    /// The outcome the result wording states, or nil when it is missing or unfamiliar.
    /// "Veto Sustained" is a failed override — the veto stands — so it is checked with the
    /// failures, ahead of the plain "sustained" of "Decision of Chair Sustained".
    var recordedOutcome: Outcome? {
        guard let result = result?.lowercased() else { return nil }
        if ["rejected", "failed", "not agreed", "not sustained", "not invoked", "defeated", "veto sustained"]
            .contains(where: result.contains) {
            return .failed
        }
        if ["passed", "agreed", "confirmed", "sustained", "adopted", "invoked", "concurred", "overridden"]
            .contains(where: result.contains) {
            return .carried
        }
        return nil
    }

    /// One word for the result chip: PASSED, AGREED, CONFIRMED, FAILED, REJECTED.
    var outcomeWord: String? {
        guard let outcome else { return nil }
        let result = (result ?? "").lowercased()
        switch outcome {
        case .carried:
            if result.contains("overridden") { return "OVERRIDDEN" }
            if result.contains("confirmed") { return "CONFIRMED" }
            if result.contains("passed") { return "PASSED" }
            return result.contains("agreed") ? "AGREED" : "PASSED"
        case .failed:
            return result.contains("rejected") || result.contains("not agreed") ? "REJECTED" : "FAILED"
        }
    }

    /// What kind of question this was, in a word or two: `Suspension`, `Cloture`, `Passage`.
    ///
    /// The checks run most-specific first: "On Motion to Suspend the Rules and Pass" is a
    /// suspension, not a passage, and "On Cloture on the Motion to Proceed" is cloture.
    var questionKind: String {
        if kind == .election { return "Speaker election" }
        let q = question.lowercased()
        let table: [(String, String)] = [
            // The Senate's override question names passage, so it goes before "passage".
            ("objections of the president", "Veto override"),
            ("veto", "Veto override"),
            ("conference report", "Conference report"),
            ("suspend the rules", "Suspension"),
            ("cloture", "Cloture"),
            ("previous question", "Previous question"),
            ("recommit", "Motion to recommit"),
            ("motion to table", "Motion to table"),
            ("discharge", "Motion to discharge"),
            ("motion to refer", "Motion to refer"),
            ("motion to proceed", "Motion to proceed"),
            ("concur", "Concur"),
            ("nomination", "Nomination"),
            ("amendment", "Amendment"),
            ("passage", "Passage"),
            ("resolution", "Resolution"),
            ("adjourn", "Adjourn"),
            ("journal", "Journal"),
        ]
        if let hit = table.first(where: { q.contains($0.0) }) { return hit.1 }
        var trimmed = question
        for prefix in ["On the ", "On "] where trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
            break
        }
        return trimmed
    }
}

public extension Chamber {
    /// `House` or `Senate`.
    var name: String { self == .house ? "House" : "Senate" }
}

public extension Position {
    /// How the record prints it: `YEA`, `NAY`, `PRESENT`, `MISSED`.
    var shortLabel: String {
        switch self {
        case .yea: "YEA"
        case .nay: "NAY"
        case .present: "PRESENT"
        case .notVoting: "MISSED"
        case .candidate: "BALLOT"
        }
    }
}

/// Plural names for the parties the API reports.
public enum PartyName {
    public static func plural(_ party: String) -> String {
        switch party {
        case "D": "Democrats"
        case "R": "Republicans"
        case "I": "Independents"
        default: party
        }
    }

    public static func singular(_ party: String) -> String {
        switch party {
        case "D": "Democrat"
        case "R": "Republican"
        case "I": "Independent"
        default: party
        }
    }

    public static func of(_ party: String, count: Int) -> String {
        count == 1 ? singular(party) : plural(party)
    }
}

/// U.S. states and territories by postal code, for "New York's 8th District".
public enum StateName {
    public static func full(_ code: String) -> String { names[code] ?? code }

    /// The name as it reads mid-sentence: `the District of Columbia`, `the U.S. Virgin Islands`,
    /// `the Northern Mariana Islands`, and every other name unchanged ("Delegate for District of
    /// Columbia" is how a form reads, not a person).
    public static func inSentence(_ code: String) -> String {
        ["DC", "VI", "MP"].contains(code) ? "the \(full(code))" : full(code)
    }

    /// `8th`, `21st`, `112th`.
    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        let suffix = (11...13).contains(tens) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }

    /// `New York's 8th District`, `Wyoming's at-large district`, and just `District of Columbia`
    /// where one delegate covers the whole place — "D.C.'s at-large district" would suggest a
    /// representative and senators it does not have.
    public static func districtName(state: String, district: Int) -> String {
        let name = full(state)
        if Member.delegateJurisdictions.contains(state) { return name }
        let possessive = name.hasSuffix("s") ? "\(name)'" : "\(name)'s"
        return district == 0 ? "\(possessive) at-large district" : "\(possessive) \(ordinal(district)) District"
    }

    private static let names: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
        "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire",
        "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
        "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee",
        "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming", "DC": "District of Columbia",
        "PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands", "AS": "American Samoa",
        "MP": "Northern Mariana Islands",
    ]
}
