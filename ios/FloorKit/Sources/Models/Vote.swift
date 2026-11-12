import Foundation

public struct VoteTotals: Codable, Sendable, Hashable {
    public var yea: Int
    public var nay: Int
    public var present: Int
    public var notVoting: Int

    public init(yea: Int, nay: Int, present: Int, notVoting: Int) {
        self.yea = yea
        self.nay = nay
        self.present = present
        self.notVoting = notVoting
    }

    /// Members who cast yea, nay or present.
    public var voting: Int { yea + nay + present }
}

/// One candidate's total in a Speaker election.
public struct Candidate: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var total: Int

    public var id: String { name }

    public init(name: String, total: Int) {
        self.name = name
        self.total = total
    }
}

/// A vote as the API returns it inside a bill, a nomination or a member's record.
///
/// `GET /v1/votes/{id}` returns the richer ``VoteDetail``.
public struct Vote: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: VoteKind
    public var chamber: Chamber
    public var congress: Int
    public var session: Int
    public var rollNumber: Int?
    public var question: String
    public var billId: String?
    public var nominationId: String?
    /// How the chamber cited the measure on the roll call, e.g. `H CON RES 14` or `PN1093-3`.
    public var billRef: String?
    /// When the roll call closed, ISO 8601. See ``occurredAtDate``.
    public var occurredAt: String?
    public var state: VoteState
    public var threshold: VoteThreshold
    public var totals: VoteTotals
    /// Empty unless `kind` is `.election`.
    public var candidates: [Candidate]
    /// How the chamber recorded the outcome, e.g. `Passed` or `Nomination Confirmed`. On a Speaker
    /// election it is the name of the candidate who led *that ballot*, which is not the same as
    /// having been elected: see ``electedSpeaker``.
    public var result: String?

    public init(
        id: String, kind: VoteKind, chamber: Chamber, congress: Int, session: Int, rollNumber: Int?,
        question: String, billId: String?, nominationId: String?, billRef: String?, occurredAt: String?,
        state: VoteState, threshold: VoteThreshold, totals: VoteTotals, candidates: [Candidate],
        result: String?
    ) {
        self.id = id
        self.kind = kind
        self.chamber = chamber
        self.congress = congress
        self.session = session
        self.rollNumber = rollNumber
        self.question = question
        self.billId = billId
        self.nominationId = nominationId
        self.billRef = billRef
        self.occurredAt = occurredAt
        self.state = state
        self.threshold = threshold
        self.totals = totals
        self.candidates = candidates
        self.result = result
    }

    /// Votes needed to pass given who has voted so far.
    public var votesNeeded: Int {
        threshold.votesNeeded(voting: totals.voting)
    }

    /// The side currently ahead, or nil when tied. Always nil for a Speaker election, which has
    /// no yea/nay sides.
    public var leader: VotePositionSide? {
        if kind == .election { return nil }
        if totals.yea == totals.nay { return nil }
        return totals.yea > totals.nay ? .yea : .nay
    }

    /// ``occurredAt`` parsed, or nil when the roll call has no timestamp yet.
    public var occurredAtDate: Date? {
        occurredAt.flatMap(Formats.instant)
    }

    /// The candidate with the most votes on this ballot, or nil for a question vote. Leading a
    /// ballot is not winning it — 17 of the 20 Speaker ballots since 2023 elected nobody.
    public var leadingCandidate: Candidate? {
        kind == .election ? candidates.max(by: { $0.total < $1.total }) : nil
    }

    /// The candidate elected Speaker on this ballot, or nil if the ballot settled nothing.
    ///
    /// A Speaker needs more than half the votes cast *for a person*, so members voting present lower
    /// the bar. McCarthy was elected on the fifteenth ballot of January 2023 with 216 of 428 cast —
    /// a plain 218 threshold would have missed it.
    public var electedSpeaker: Candidate? {
        guard let leader = leadingCandidate else { return nil }
        let castForAPerson = candidates.reduce(0) { $0 + $1.total }
        return leader.total * 2 > castForAPerson ? leader : nil
    }
}

/// One party's counts on a vote.
public struct PartyTotals: Codable, Sendable, Hashable, Identifiable {
    public var party: String
    public var yea: Int
    public var nay: Int
    public var present: Int
    public var notVoting: Int

    public var id: String { party }

    public init(party: String, yea: Int, nay: Int, present: Int, notVoting: Int) {
        self.party = party
        self.yea = yea
        self.nay = nay
        self.present = present
        self.notVoting = notVoting
    }

    /// Members of this party who cast yea, nay or present.
    public var voting: Int { yea + nay + present }
}

/// How many of one party backed one candidate in a Speaker election.
public struct CandidateTotal: Codable, Sendable, Hashable, Identifiable {
    public var party: String
    public var candidate: String
    public var total: Int

    public var id: String { "\(party)-\(candidate)" }

    public init(party: String, candidate: String, total: Int) {
        self.party = party
        self.candidate = candidate
        self.total = total
    }
}

/// One member's own position on a vote, as returned for the members named in `?members=`.
public struct MemberPosition: Codable, Sendable, Hashable, Identifiable {
    public var member: Member
    public var position: Position
    /// The candidate they named, on a Speaker election.
    public var choice: String?

    public var id: String { member.bioguideId }

    public init(member: Member, position: Position, choice: String?) {
        self.member = member
        self.position = position
        self.choice = choice
    }
}

/// `GET /v1/votes/{id}` — a vote plus the breakdowns the vote screen needs.
///
/// The wire format is flat: the vote's own fields sit beside `partyTotals` and the rest. ``vote``
/// is decoded from that same container, so it can be handed straight to a card that takes a
/// ``Vote`` without copying sixteen fields across.
public struct VoteDetail: Codable, Sendable, Hashable, Identifiable {
    public var vote: Vote
    /// Per-party counts. A Speaker election reports its party split in ``candidateTotals``, and
    /// carries party rows here only for members who voted present or did not vote.
    public var partyTotals: [PartyTotals]
    /// Which candidate each party backed. Empty unless the vote is a Speaker election.
    public var candidateTotals: [CandidateTotal]
    /// How the members named in `?members=` voted. Empty when the request named none.
    public var positions: [MemberPosition]

    public var id: String { vote.id }

    private enum CodingKeys: String, CodingKey {
        case partyTotals, candidateTotals, positions
    }

    public init(vote: Vote, partyTotals: [PartyTotals], candidateTotals: [CandidateTotal], positions: [MemberPosition]) {
        self.vote = vote
        self.partyTotals = partyTotals
        self.candidateTotals = candidateTotals
        self.positions = positions
    }

    public init(from decoder: Decoder) throws {
        vote = try Vote(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partyTotals = try container.decode([PartyTotals].self, forKey: .partyTotals)
        candidateTotals = try container.decode([CandidateTotal].self, forKey: .candidateTotals)
        positions = try container.decode([MemberPosition].self, forKey: .positions)
    }

    public func encode(to encoder: Encoder) throws {
        try vote.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(partyTotals, forKey: .partyTotals)
        try container.encode(candidateTotals, forKey: .candidateTotals)
        try container.encode(positions, forKey: .positions)
    }
}
