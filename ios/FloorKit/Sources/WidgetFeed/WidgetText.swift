import Foundation
import Models

/// The words the widgets print and speak, kept apart from the views so they can be tested without
/// WidgetKit.
public enum WidgetText {
    /// The position chip: `YEA`, `NAY`, `DNV`, `PRESENT`, or on a Speaker ballot the candidate the
    /// member named (`JEFFRIES`), since "candidate" says nothing. Names are printed as the Clerk
    /// records them — mostly surnames, but not always ("Donald J. Trump"), so they are not split.
    public static func chip(_ position: Position, choice: String?) -> String {
        switch position {
        case .yea: "YEA"
        case .nay: "NAY"
        case .present: "PRESENT"
        case .notVoting: "DNV"
        case .candidate: trimmed(choice)?.uppercased() ?? "BALLOT"
        }
    }

    /// What the vote was on, as the widgets head it: the measure's citation, else `Speaker ballot`
    /// or the kind of question (`Motion to adjourn`), which is all a procedural vote has.
    public static func citation(_ vote: Vote, measure: MeasureSummary?) -> String {
        if let measure { return measure.citation }
        return vote.kind == .election ? "Speaker ballot" : vote.questionKind
    }

    /// The small widget's result word, from the chamber's recorded result (``Vote/outcomeWord``):
    /// `PASSED`, `AGREED`, `CONFIRMED`, `FAILED`, `REJECTED`. A Speaker ballot says whether it
    /// elected anyone — its `result` names the ballot's leader, not a winner (lesson 16).
    public static func resultWord(_ vote: Vote) -> String? {
        if vote.kind == .election {
            guard vote.state == .final else { return nil }
            return vote.electedSpeaker == nil ? "NO ONE ELECTED" : "ELECTED"
        }
        return vote.outcomeWord
    }

    /// The medium widget's result: `Passed 295–128`, `Agreed 62–21`, `Johnson elected 216`,
    /// `Jeffries led 212`, `Voting now`.
    public static func resultLine(_ vote: Vote) -> String {
        switch vote.state {
        case .scheduled: return "Scheduled"
        case .open: return "Voting now"
        case .final: break
        }
        if vote.kind == .election {
            if let elected = vote.electedSpeaker {
                return "\(elected.name) elected \(elected.total)"
            }
            if let leader = vote.leadingCandidate {
                return "\(leader.name) led \(leader.total)"
            }
            return "Speaker ballot"
        }
        let word = vote.outcomeWord.map { $0.prefix(1) + $0.dropFirst().lowercased() } ?? "Final"
        return "\(word) \(vote.totals.yea)–\(vote.totals.nay)"
    }

    /// The medium widget's heading: `Your three · TX-37`; one member reads `Your delegate · DC`
    /// (or resident commissioner); a vacancy reads `Your two`.
    public static func header(_ snapshot: WidgetSnapshot) -> String {
        header(members: snapshot.members, district: snapshot.district)
    }

    public static func header(members: [Member], district: District) -> String {
        let who: String = switch members.count {
        case 1: members[0].isDelegate ? "Your \(members[0].title.lowercased())" : "Your member"
        case 2: "Your two"
        case 3: "Your three"
        default: "Your members"
        }
        return "\(who) · \(district.name)"
    }

    /// The line under a lone delegate's row, so the medium widget says why there is one member
    /// rather than looking like two failed to load.
    public static func loneMemberNote(_ snapshot: WidgetSnapshot) -> String? {
        guard snapshot.members.count == 1, let only = snapshot.members.first, only.isDelegate else { return nil }
        return "\(StateName.full(only.state)) has no senators. \(only.title)s vote on amendments, not on passage."
    }

    /// The small widget's heading: `Final · House`.
    public static func smallHeader(_ vote: Vote) -> String {
        "Final · \(vote.chamber.name)"
    }

    /// The two big numbers on the small widget: yea and nay, or on a Speaker ballot the two
    /// candidates who led it. A ballot with one candidate has no right-hand number — a 0 there
    /// would read as a second candidate who got nothing.
    public static func score(_ vote: Vote) -> (left: Score, right: Score?) {
        if vote.kind == .election {
            let top = vote.candidates.sorted { $0.total > $1.total }
            let first = top.first.map { Score(value: $0.total, label: $0.name, side: nil) }
            let second = top.dropFirst().first.map { Score(value: $0.total, label: $0.name, side: nil) }
            return (first ?? Score(value: 0, label: "", side: nil), second)
        }
        return (
            Score(value: vote.totals.yea, label: "Yea", side: .yea),
            Score(value: vote.totals.nay, label: "Nay", side: .nay)
        )
    }

    public struct Score: Sendable, Hashable {
        public var value: Int
        public var label: String
        /// Which colour it is printed in: yea green, nay orange, or the text colour for a candidate.
        public var side: VotePositionSide?
    }

    /// How old a snapshot may be before the widget says so.
    public static let staleAfter: TimeInterval = 2 * 60 * 60

    /// `As of 3:40 PM` (earlier today) or `As of Nov 12`, once the votes shown were fetched more
    /// than two hours ago — a refresh has been failing — else nil.
    public static func asOf(_ fetchedAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard now.timeIntervalSince(fetchedAt) > staleAfter else { return nil }
        let when = calendar.isDate(fetchedAt, inSameDayAs: now)
            ? fetchedAt.formatted(.dateTime.hour().minute())
            : fetchedAt.formatted(.dateTime.month(.abbreviated).day())
        return "As of \(when)"
    }

    /// The day a vote closed, as the app prints it everywhere: `Nov 11`.
    public static func day(_ vote: Vote) -> String? {
        vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - VoiceOver

    /// "Latest final, House. H.R. 1013, passed, 295 to 128. Doggett voted nay."
    public static func smallLabel(_ final: WidgetSnapshot.Final) -> String {
        let vote = final.vote
        var parts = ["Latest final, \(vote.chamber.name)", citation(vote, measure: final.measure)]
        if vote.kind == .election {
            parts.append(resultLine(vote))
        } else {
            let word = resultWord(vote).map { $0.prefix(1) + $0.dropFirst().lowercased() } ?? "Final"
            parts.append("\(word), \(vote.totals.yea) to \(vote.totals.nay)")
        }
        parts.append(spoken(final.call.member, final.call.position, choice: final.call.choice))
        return parts.joined(separator: ". ") + "."
    }

    /// "Doggett voted nay on H.R. 1013, passed 295 to 128, Nov 11."
    public static func rowLabel(_ row: WidgetSnapshot.Row) -> String {
        guard let latest = row.latest else { return "\(row.member.lastName) has no recorded votes yet." }
        let what = citation(latest.vote, measure: latest.measure)
        let result = resultLine(latest.vote).replacingOccurrences(of: "–", with: " to ")
        return [
            "\(spoken(row.member, latest.position, choice: latest.choice)) on \(what)", result, day(latest.vote),
        ].compactMap(\.self).joined(separator: ", ") + "."
    }

    static func spoken(_ member: Member, _ position: Position, choice: String?) -> String {
        let name = member.lastName
        return switch position {
        case .yea: "\(name) voted yea"
        case .nay: "\(name) voted nay"
        case .present: "\(name) voted present"
        case .notVoting: "\(name) did not vote"
        case .candidate: "\(name) voted for \(choice ?? "a candidate")"
        }
    }

    /// A candidate's name trimmed, or nil when there is none to print.
    static func trimmed(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }
}
