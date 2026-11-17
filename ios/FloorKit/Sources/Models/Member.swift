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
    /// `YYYY-MM-DD`: the day they leave, when a member-elect replaces them and that day has not come
    /// (`2027-01-03`). nil otherwise, and in a response from an API older than members-elect.
    public var leavingOn: String?
    /// Official accounts (round 13), on the member's own record (`/v1/members/{id}`). nil in lists,
    /// from an API older than round 13, and in a response saved by an earlier build.
    public var social: MemberSocial?

    public var id: String { bioguideId }

    public init(
        bioguideId: String, firstName: String, lastName: String, party: String, state: String,
        district: Int?, chamber: Chamber, leavingOn: String? = nil, social: MemberSocial? = nil
    ) {
        self.bioguideId = bioguideId
        self.firstName = firstName
        self.lastName = lastName
        self.party = party
        self.state = state
        self.district = district
        self.chamber = chamber
        self.leavingOn = leavingOn
        self.social = social
    }

    private enum CodingKeys: String, CodingKey {
        case bioguideId, firstName, lastName, party, state, district, chamber, leavingOn, social
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bioguideId = try c.decode(String.self, forKey: .bioguideId)
        firstName = try c.decode(String.self, forKey: .firstName)
        lastName = try c.decode(String.self, forKey: .lastName)
        party = try c.decode(String.self, forKey: .party)
        state = try c.decode(String.self, forKey: .state)
        district = try c.decodeIfPresent(Int.self, forKey: .district)
        chamber = try c.decode(Chamber.self, forKey: .chamber)
        leavingOn = try c.decodeIfPresent(String.self, forKey: .leavingOn)
        // Lenient: accounts this build can't read are no accounts, never an unreadable member.
        social = ((try? c.decodeIfPresent(MemberSocial.self, forKey: .social)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
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
/// How to reach a member's office. Every field can be nil: most House offices list no web form,
/// and the app falls back to the House's "Write Your Representative" form for those.
public struct MemberContact: Codable, Sendable, Hashable {
    public var phone: String?
    public var contactForm: String?
    public var website: String?
    public var office: String?
    /// Mailing address.
    public var address: String?

    public init(phone: String?, contactForm: String?, website: String?, office: String?, address: String?) {
        self.phone = phone
        self.contactForm = contactForm
        self.website = website
        self.office = office
        self.address = address
    }
}

public struct MemberDetail: Codable, Sendable, Hashable, Identifiable {
    public var member: Member
    public var partyLoyalty: PartyLoyalty
    /// nil in a response saved by an earlier build.
    public var contact: MemberContact?

    public var id: String { member.bioguideId }

    public init(member: Member, partyLoyalty: PartyLoyalty, contact: MemberContact? = nil) {
        self.member = member
        self.partyLoyalty = partyLoyalty
        self.contact = contact
    }

    private enum CodingKeys: String, CodingKey { case member, partyLoyalty, contact }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        member = try c.decode(Member.self, forKey: .member)
        partyLoyalty = try c.decode(PartyLoyalty.self, forKey: .partyLoyalty)
        contact = try c.decodeIfPresent(MemberContact.self, forKey: .contact)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(member, forKey: .member)
        try c.encode(partyLoyalty, forKey: .partyLoyalty)
        try c.encodeIfPresent(contact, forKey: .contact)
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
    /// A bill's sponsor, for a feed card's citation line. nil for a nomination, and in a response
    /// from before v0.2.57 (as are the three fields below).
    public var sponsor: MeasureSponsor?
    /// The opening of a bill's CRS summary without its title line, about 320 characters at most, cut
    /// at a sentence end. CRS's words, not AI's. nil for a nomination and a bill CRS has not summarized.
    public var summaryLead: String?
    /// A nomination's position title, e.g. `United States Circuit Judge for the Tenth Circuit`.
    public var position: String?
    /// For a House special rule, the bill it brings to the floor (`119-hr-2102`), so a feed can file
    /// the rule's votes under that bill.
    public var forBillId: String?

    public init(
        id: String, kind: Kind, citation: String, title: String, policyArea: String? = nil,
        sponsor: MeasureSponsor? = nil, summaryLead: String? = nil, position: String? = nil, forBillId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.citation = citation
        self.title = title
        self.policyArea = policyArea
        self.sponsor = sponsor
        self.summaryLead = summaryLead
        self.position = position
        self.forBillId = forBillId
    }

    /// `H.R. 1013 · Retirement Fairness Act`, as a card headline.
    public var headline: String { "\(citation) · \(title)" }
}

/// A bill's sponsor as ``MeasureSummary`` carries it.
public struct MeasureSponsor: Codable, Sendable, Hashable {
    public var bioguideId: String
    public var lastName: String
    public var party: String
    public var state: String

    public init(bioguideId: String, lastName: String, party: String, state: String) {
        self.bioguideId = bioguideId
        self.lastName = lastName
        self.party = party
        self.state = state
    }

    /// `Bilirakis (R-FL)`.
    public var label: String { "\(lastName) (\(party)-\(state))" }
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
    /// Members-elect for these seats only (the state's Senate seats, this House district), and the
    /// seats among them with no winner yet. Empty from an older API and once they take office.
    public var elect: [MemberElect]
    public var pending: [PendingSeat]

    public init(district: District, members: [Member], elect: [MemberElect] = [], pending: [PendingSeat] = []) {
        self.district = district
        self.members = members
        self.elect = elect
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case district, members, elect, pending }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        district = try c.decode(District.self, forKey: .district)
        members = try c.decode([Member].self, forKey: .members)
        (elect, pending) = ElectLists.decode(c, elect: .elect, pending: .pending)
    }

    public var representative: Member? { members.first { $0.chamber == .house } }
    public var senators: [Member] { members.filter { $0.chamber == .senate } }
}
