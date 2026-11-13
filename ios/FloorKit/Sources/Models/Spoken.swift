import Foundation

/// What VoiceOver reads for a card, built from the same models the card draws.
///
/// Plain functions of the data rather than strings assembled inside a view body, so the tests can
/// read them: a card that draws correctly but reads "Yea 295. Nay 128. Passed. Needed 212. Doggett
/// Nay" is the VoiceOver equivalent of the 2/1/6 digit bug, and only a test catches it.
///
/// Each label leads with the one sentence a listener needs — what was voted on, how it came out,
/// how your own members voted — and puts the detail (the measure's title, the chamber, the day,
/// the threshold) after it, because a VoiceOver user swiping a feed hears the first clause of
/// every card and the rest only of the ones they stop on.
public enum Spoken {
    // MARK: - Score cards

    /// `H.R. 1013, On Passage, passed, 295 yea to 128 nay; your rep Jeffries voted nay. Retirement Fairness
    /// for Charities and Educational Institutions Act of 2025. House, Nov 11, needed 212.`
    ///
    /// - Parameters:
    ///   - title: the measure's title as the card prints it, or the question for a procedural vote.
    ///   - citation: `H.R. 1013`, or nil for a vote on no measure.
    ///   - day: the date as the card prints it, already formatted, so this stays free of the clock
    ///     and the locale.
    public static func scoreboard(
        vote: Vote, title: String, citation: String?, positions: [MemberPosition], day: String? = nil
    ) -> String {
        // No citation (a procedural vote, a Speaker ballot): the question leads, and the chamber
        // follows in the detail rather than being said twice.
        var lead = [citation, vote.question, result(vote)]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !positions.isEmpty { lead += "; " + members(positions) }

        var detail: [String] = []
        if title != vote.question, !title.isEmpty { detail.append(sentence(title)) }
        var context = [vote.chamber.name, day].compactMap(\.self)
        if let line = vote.line, vote.state != .scheduled { context.append("needed \(line.needed)") }
        detail.append(context.joined(separator: ", "))
        return ([sentence(lead)] + detail.map(sentence)).joined(separator: " ")
    }

    /// How the vote came out, in words: `passed, 295 yea to 128 nay`, `agreed to, 62 yea to 21 nay`,
    /// `voting now, 120 yea to 80 nay so far`, `Jeffries led with 212, Johnson had 211; nobody was
    /// elected on this ballot`. Each number names its side: "failed, 212 to 206" leaves a listener
    /// to guess which was the 212.
    public static func result(_ vote: Vote) -> String {
        if vote.kind == .election { return electionResult(vote) }
        let score = "\(vote.totals.yea) yea to \(vote.totals.nay) nay"
        switch vote.state {
        case .scheduled: return "scheduled"
        case .open: return "voting now, \(score) so far"
        case .final:
            guard let word = vote.outcomeWord else { return "final, \(score)" }
            // A comma after the verb: "agreed to 62 yea to 21 nay" would double the "to", and
            // every outcome reads the same way.
            let verb = word == "AGREED" ? "agreed to" : word.lowercased()
            return "\(verb), \(score)"
        }
    }

    private static func electionResult(_ vote: Vote) -> String {
        let leaders = vote.candidates.sorted { $0.total > $1.total }
        guard let first = leaders.first else {
            return vote.state == .scheduled ? "scheduled" : "no ballots counted"
        }
        switch vote.state {
        case .scheduled: return "scheduled"
        case .open: return "voting now, \(first.name) leads with \(first.total)"
        case .final:
            if let elected = vote.electedSpeaker {
                return "\(elected.name) elected Speaker with \(elected.total)"
            }
            // Leading a ballot is not winning it (HANDOFF lesson 16), and a tie has no leader.
            let tied = leaders.filter { $0.total == first.total }
            if tied.count > 1 {
                return "\(list(tied.map(\.name))) tied with \(first.total); nobody was elected on this ballot"
            }
            let runnerUp = leaders.dropFirst().first.map { ", \($0.name) had \($0.total)" } ?? ""
            return "\(first.name) led with \(first.total)\(runnerUp); nobody was elected on this ballot"
        }
    }

    // MARK: - Your members

    /// `your rep Doggett voted nay`, `your senators Cornyn and Cruz voted yea`, `your rep Doggett
    /// voted for Jeffries`. Members who share a seat type and a position are read together.
    public static func members(_ positions: [MemberPosition]) -> String {
        var groups: [(role: Role, did: String, names: [String])] = []
        for position in positions {
            let role = Role(position.member)
            let did = action(position)
            if let index = groups.firstIndex(where: { $0.role == role && $0.did == did }) {
                groups[index].names.append(position.member.lastName)
            } else {
                groups.append((role, did, [position.member.lastName]))
            }
        }
        return groups
            .map { "your \($0.role.word(plural: $0.names.count > 1)) \(list($0.names)) \($0.did)" }
            .joined(separator: ", ")
    }

    /// `voted yea`, `voted nay`, `voted present`, `did not vote`, `voted for Jeffries`.
    public static func action(_ position: MemberPosition) -> String {
        switch position.position {
        case .yea: "voted yea"
        case .nay: "voted nay"
        case .present: "voted present"
        case .notVoting: "did not vote"
        case .candidate: "voted for \(position.choice ?? "a candidate")"
        }
    }

    /// `Lloyd Doggett, Democrat, Representative for Texas' 37th District`, `Ted Cruz, Republican,
    /// Senator for Texas`, `Eleanor Norton, Democrat, Delegate for the District of Columbia`.
    ///
    /// The cards print `House · TX-37`; read aloud that is "House dot T X dash 37", so the seat is
    /// spelled out here instead.
    public static func member(_ member: Member) -> String {
        "\(member.fullName), \(PartyName.singular(member.party)), \(member.title) for \(seat(member))"
    }

    /// `Texas' 37th District`, `Wyoming's at-large district`, `Texas` for a senator, `the District
    /// of Columbia` for its delegate.
    public static func seat(_ member: Member) -> String {
        guard member.chamber == .house, let district = member.district else { return StateName.inSentence(member.state) }
        if Member.delegateJurisdictions.contains(member.state) { return StateName.inSentence(member.state) }
        return StateName.districtName(state: member.state, district: district)
    }

    /// A delegation card on Home: the member, then their party-loyalty figure or that there is none.
    ///
    /// - Parameter withPartyShare: 0…1, or nil when there is no figure (an independent, or no
    ///   qualifying votes yet — lesson 15). One decimal place, as the ring's own figure is.
    public static func delegationCard(_ member: Member, withPartyShare share: Double?) -> String {
        let loyalty = share.map {
            "Voted with their party \(String(format: "%.1f", $0 * 100)) percent of the time"
        } ?? "No party-loyalty figure"
        return "\(Self.member(member)). \(loyalty)"
    }

    /// One of your members on the vote screen: `Hakeem Jeffries, Representative for New York's 8th
    /// District, voted nay, with 128 of 211 Democrats`.
    public static func memberPosition(_ position: MemberPosition, partyNote: String? = nil) -> String {
        let member = position.member
        return [member.fullName, "\(member.title) for \(seat(member))", action(position), partyNote]
            .compactMap(\.self)
            .joined(separator: ", ")
    }

    // MARK: - Helpers

    private enum Role: Equatable {
        case representative, delegate, residentCommissioner, senator

        init(_ member: Member) {
            switch member.title {
            case "Senator": self = .senator
            case "Delegate": self = .delegate
            case "Resident Commissioner": self = .residentCommissioner
            default: self = .representative
            }
        }

        func word(plural: Bool) -> String {
            switch self {
            case .representative: plural ? "reps" : "rep"
            case .delegate: plural ? "delegates" : "delegate"
            case .residentCommissioner: plural ? "resident commissioners" : "resident commissioner"
            case .senator: plural ? "senators" : "senator"
            }
        }
    }

    /// `Cruz`, `Cornyn and Cruz`, `A, B and C`.
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Ends a clause with a full stop unless it already has closing punctuation.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }
}
