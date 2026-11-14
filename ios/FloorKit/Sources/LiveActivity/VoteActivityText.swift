import Foundation
import Models

/// The words the Live Activity prints and speaks, apart from the views so they are tested without
/// ActivityKit. Each is the mock's (round 8, sections A and B) where the mock shows it.
public enum VoteActivityText {
    public typealias Attributes = VoteActivityAttributes
    public typealias Content = VoteActivityAttributes.ContentState

    /// The vote as a `Vote`, so the threshold line and the outcome word are the app's own
    /// (`ThresholdLine`, `Vote.outcomeWord`) rather than a second copy of them.
    public static func vote(_ a: Attributes, _ c: Content) -> Vote {
        Vote(
            id: a.voteId, kind: a.kind, chamber: a.chamber, congress: 0, session: 0, rollNumber: a.rollNumber,
            question: a.question, billId: nil, nominationId: nil, billRef: nil, occurredAt: c.openedAt,
            state: c.state, threshold: a.threshold,
            totals: c.totals ?? VoteTotals(yea: 0, nay: 0, present: 0, notVoting: 0), candidates: [], result: c.result
        )
    }

    /// `House · Roll call 321`; `Senate · Floor` when no roll call number is known yet.
    public static func header(_ a: Attributes) -> String {
        "\(a.chamber.name) · " + (a.rollNumber.map { "Roll call \($0)" } ?? "Floor")
    }

    /// `Vote open` or `Final`.
    public static func status(_ c: Content) -> String { c.state == .final ? "Final" : "Vote open" }

    /// What the vote is on, in a word or two: `H.R. 1013`, or for a procedural vote its kind.
    public static func subject(_ a: Attributes, _ c: Content) -> String {
        if let citation = a.citation { return citation }
        return a.kind == .election ? "Speaker ballot" : vote(a, c).questionKind
    }

    /// `H.R. 1013 · On Passage` while open; `H.R. 1013 · Passed` once final.
    public static func headline(_ a: Attributes, _ c: Content) -> String {
        guard c.state == .final else { return a.citation.map { "\($0) · \(a.question)" } ?? a.question }
        return "\(subject(a, c)) · \(resultWord(a, c))"
    }

    /// `Passed`, `Agreed`, `Rejected`; a Speaker ballot never names a winner it did not have.
    public static func resultWord(_ a: Attributes, _ c: Content) -> String {
        if a.kind == .election { return "Final" }
        guard let word = vote(a, c).outcomeWord else { return "Final" }
        return word.prefix(1) + word.dropFirst().lowercased()
    }

    /// The small line under an open vote's headline: the bill's short title.
    public static func detail(_ a: Attributes, _ c: Content) -> String? {
        c.state == .open ? a.title : nil
    }

    /// `Needs a majority`, `Needs two-thirds`, `Needs 60 of 100`.
    public static func needs(_ a: Attributes) -> String {
        switch a.threshold {
        case .majority: "Needs a majority"
        case .twoThirds: "Needs two-thirds"
        case .threeFifthsSworn: "Needs 60 of 100"
        }
    }

    /// `Opened 2:43 PM` from the floor's time (House); `Called 2:31 PM` from when a floor source
    /// named it, which is all the Senate's sources give; nil with neither.
    public static func opened(_ c: Content, timeZone: TimeZone = .current) -> String? {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        if let at = c.openedAt.flatMap(Formats.instant) { return "Opened \(at.formatted(style))" }
        if let at = c.calledAt.flatMap(Formats.instant) { return "Called \(at.formatted(style))" }
        return nil
    }

    /// Under the final score: `10 not voting`, `2 present · 10 not voting`, or nil.
    public static func absentees(_ c: Content) -> String? {
        guard let t = c.totals else { return nil }
        let parts = [t.present > 0 ? "\(t.present) present" : nil, t.notVoting > 0 ? "\(t.notVoting) not voting" : nil]
        let line = parts.compactMap(\.self).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// The chip: `…` until recorded, then `YEA`, `NAY`, `DNV`, `PRESENT` or the candidate.
    public static func chip(_ call: Attributes.Call) -> String {
        call.position.map { $0.chip(choice: call.choice) } ?? "…"
    }

    /// One member's line. Open: `Doggett hasn't been recorded yet` alone, `Cornyn not recorded yet`
    /// in a list. Final: `Doggett voted nay · on the losing side`, or without the side (`long: false`)
    /// where the Dynamic Island has less room.
    public static func line(_ call: Attributes.Call, _ a: Attributes, _ c: Content, alone: Bool, long: Bool = true) -> String {
        guard let position = call.position, c.state == .final else {
            return alone ? "\(call.name) hasn't been recorded yet" : "\(call.name) not recorded yet"
        }
        let verb: String = switch position {
        case .yea: "voted yea"
        case .nay: "voted nay"
        case .present: "voted present"
        case .notVoting: "did not vote"
        case .candidate: "voted for \(call.choice ?? "a candidate")"
        }
        guard long, let side = side(position, a, c) else { return "\(call.name) \(verb)" }
        return "\(call.name) \(verb) · on the \(side) side"
    }

    /// `winning` or `losing` for a yea or nay on a question that is final; nil otherwise.
    static func side(_ position: Position, _ a: Attributes, _ c: Content) -> String? {
        guard position == .yea || position == .nay, let outcome = vote(a, c).outcome else { return nil }
        let won = (outcome == .carried) == (position == .yea)
        return won ? "winning" : "losing"
    }

    /// `+2 more of your members`, or nil.
    public static func more(_ c: Content) -> String? {
        c.moreMembers > 0 ? "+\(c.moreMembers) more of your members" : nil
    }

    /// The Dynamic Island's compact trailing text: `OPEN`, or the score.
    public static func compactTrailing(_ c: Content) -> String {
        guard c.state == .final, let t = c.totals else { return "OPEN" }
        return "\(t.yea)–\(t.nay)"
    }

    /// One sentence for VoiceOver, outcome and your members first.
    public static func spoken(_ a: Attributes, _ c: Content, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        let where_ = a.rollNumber.map { "\(a.chamber.name) roll call \($0)" } ?? "\(a.chamber.name) floor"
        if c.state == .final, let t = c.totals {
            parts.append("\(where_), \(subject(a, c)) \(resultWord(a, c).lowercased()), \(t.yea) yea to \(t.nay) nay")
            if let absent = absentees(c) { parts.append(absent) }
        } else {
            parts.append("\(where_), \(a.citation.map { "\($0), " } ?? "")\(a.question), vote open")
            parts.append(needs(a))
            if let opened = opened(c, timeZone: timeZone) { parts.append(opened) }
        }
        let calls = c.members.map { line($0, a, c, alone: c.members.count == 1) }
        let tail = (calls + [more(c)].compactMap(\.self)).joined(separator: ". ")
        return parts.joined(separator: ". ") + "." + (tail.isEmpty ? "" : " \(tail.replacingOccurrences(of: " · ", with: ", ")).")
    }
}
