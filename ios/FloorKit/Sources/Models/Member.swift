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

    /// `D-NC-12` for a representative, `R-TX` for a senator.
    public var partyAndSeat: String {
        district.map { "\(party)-\(state)-\($0)" } ?? "\(party)-\(state)"
    }
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

/// One row of a member's voting record.
public struct MemberVote: Codable, Sendable, Hashable, Identifiable {
    public var vote: Vote
    public var position: Position
    /// The candidate they named, on a Speaker election.
    public var choice: String?

    public var id: String { vote.id }

    public init(vote: Vote, position: Position, choice: String?) {
        self.vote = vote
        self.position = position
        self.choice = choice
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

    /// `TX-37`, or `TX-AL` for an at-large seat.
    public var name: String { district == 0 ? "\(state)-AL" : "\(state)-\(district)" }
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
