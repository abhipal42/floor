import Foundation

public struct Member: Codable, Sendable, Hashable, Identifiable {
    public var bioguideId: String
    public var firstName: String
    public var lastName: String
    /// `D`, `R` or `I`.
    public var party: String
    public var state: String
    /// nil for senators.
    public var district: Int?
    public var chamber: Chamber

    public var id: String { bioguideId }

    public init(
        bioguideId: String, firstName: String, lastName: String, party: String, state: String,
        district: Int?, chamber: Chamber
    ) {
        self.bioguideId = bioguideId
        self.firstName = firstName
        self.lastName = lastName
        self.party = party
        self.state = state
        self.district = district
        self.chamber = chamber
    }

    public var fullName: String { "\(firstName) \(lastName)" }

    /// `D-NC-12` for a representative, `R-WY-AL` at large, `R-TX` for a senator, `D-DC` for a
    /// delegate (who has the whole jurisdiction, so a district number would only be noise).
    public var partyAndSeat: String {
        "\(party)-\(seatBadge)"
    }

    /// `NC-12`, `WY-AL` (at large, which the API sends as district 0), `TX` for a senator, `DC` for
    /// a delegate.
    public var seatBadge: String {
        guard chamber == .house, !isDelegate, let district else { return state }
        return "\(state)-\(district == 0 ? "AL" : String(district))"
    }

    /// The small caption under a member's name: `House · TX-37`, `House · WY-AL`, `Senate · TX`,
    /// `Delegate · DC`.
    public var seatCaption: String {
        let seat = isDelegate ? title : (chamber == .house ? "House" : "Senate")
        return "\(seat) · \(seatBadge)"
    }

    /// A non-voting House member: the delegates of D.C. and four territories, and Puerto Rico's
    /// resident commissioner. They sit in the House and vote in the Committee of the Whole —
    /// amendments — but can't vote to pass a bill, and their jurisdiction has no senators.
    public var isDelegate: Bool {
        chamber == .house && Self.delegateJurisdictions.contains(state)
    }

    /// `Representative`, `Delegate`, `Resident Commissioner`, `Senator`.
    public var title: String {
        switch chamber {
        case .senate: "Senator"
        case .house where state == "PR": "Resident Commissioner"
        case .house where isDelegate: "Delegate"
        case .house: "Representative"
        }
    }

    /// Where a House member has no vote on passage and no senators beside them.
    static let delegateJurisdictions: Set<String> = ["DC", "PR", "GU", "VI", "AS", "MP"]
}

/// How often a member sided with the majority of their own party.
///
/// ``votes`` is the denominator actually used, not every vote they cast: votes where their party
/// split evenly are left out, as are votes where too few of their party voted for a majority to
/// mean anything. An independent therefore reports zero, and the UI must show nothing rather than
/// a percentage of nothing.
public struct PartyLoyalty: Codable, Sendable, Hashable {
    public var votes: Int
    public var withParty: Int
    public var againstParty: Int

    public init(votes: Int, withParty: Int, againstParty: Int) {
        self.votes = votes
        self.withParty = withParty
        self.againstParty = againstParty
    }

    /// Share of counted votes cast with their party, or nil when there is nothing to report.
    public var withPartyShare: Double? {
        votes > 0 ? Double(withParty) / Double(votes) : nil
    }
}

/// `GET /v1/members/{id}`
public struct MemberDetail: Codable, Sendable, Hashable, Identifiable {
    public var member: Member
    public var partyLoyalty: PartyLoyalty

    public var id: String { member.bioguideId }

    public init(member: Member, partyLoyalty: PartyLoyalty) {
        self.member = member
        self.partyLoyalty = partyLoyalty
    }
}

/// Just enough about the bill or nomination a vote was on to label it in a list.
///
/// Carried on each row so a feed can name what each vote was about without a request per row.
public struct MeasureSummary: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case bill, nomination
    }

    public var id: String
    public var kind: Kind
    /// As the chamber cites it: `H.R. 1013`, `PN1093-3`.
    public var citation: String
    /// A bill's short title where it has one, else its full title; a nomination's nominee, or the
    /// post for a military nomination that names nobody.
    public var title: String
    /// A bill's CRS policy area — its topic — so the feed can say a vote is in a topic you follow.
    /// nil for a nomination, for a bill CRS has not classified, and in a response saved by an
    /// earlier build (the field is new in v0.2.29).
    public var policyArea: String?

    public init(id: String, kind: Kind, citation: String, title: String, policyArea: String? = nil) {
        self.id = id
        self.kind = kind
        self.citation = citation
        self.title = title
        self.policyArea = policyArea
    }

    /// `H.R. 1013 · Retirement Fairness Act`, as a card headline.
    public var headline: String { "\(citation) · \(title)" }
}

/// One row of a member's voting record.
public struct MemberVote: Codable, Sendable, Hashable, Identifiable {
    public var vote: Vote
    public var position: Position
    /// The candidate they named, on a Speaker election.
    public var choice: String?
    /// nil for a procedural vote that refers to no measure, e.g. a motion to adjourn.
    public var measure: MeasureSummary?

    public var id: String { vote.id }

    public init(vote: Vote, position: Position, choice: String?, measure: MeasureSummary?) {
        self.vote = vote
        self.position = position
        self.choice = choice
        self.measure = measure
    }
}

/// `GET /v1/members/{id}/votes`
public struct MemberVotes: Codable, Sendable, Hashable {
    public var votes: [MemberVote]

    public init(votes: [MemberVote]) {
        self.votes = votes
    }
}

public struct District: Codable, Sendable, Hashable {
    public var congress: Int
    public var state: String
    public var district: Int
    public var countyFips: String?

    public init(congress: Int, state: String, district: Int, countyFips: String?) {
        self.congress = congress
        self.state = state
        self.district = district
        self.countyFips = countyFips
    }

    /// `TX-37`, `TX-AL` for an at-large seat, or just `DC` where a delegate covers the whole place.
    public var name: String {
        if Member.delegateJurisdictions.contains(state) { return state }
        return district == 0 ? "\(state)-AL" : "\(state)-\(district)"
    }
}

/// `GET /v1/reps?address=` — the district an address falls in and who represents it.
public struct Reps: Codable, Sendable, Hashable {
    public var district: District
    public var members: [Member]

    public init(district: District, members: [Member]) {
        self.district = district
        self.members = members
    }

    public var representative: Member? { members.first { $0.chamber == .house } }
    public var senators: [Member] { members.filter { $0.chamber == .senate } }
}
