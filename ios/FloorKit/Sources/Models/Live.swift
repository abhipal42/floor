import Foundation

/// One chamber as the live worker last saw it (`GET /v1/live`).
///
/// Models only: no screen uses these yet. The live UI (Live Activities, widgets, the open-vote card)
/// waits for a locked design.
public struct ChamberStatus: Codable, Sendable, Hashable, Identifiable {
    public var chamber: Chamber
    /// Sitting now, or within 15 minutes of convening.
    public var inSession: Bool
    /// The next (or current) convening, ISO 8601, when the chamber has published it.
    public var convenesAt: String?
    /// `YYYY-MM-DD`: the House's legislative day, or the Senate's meeting date.
    public var legislativeDay: String?
    /// When the worker last polled this chamber, ISO 8601. Minutes old means the worker is down.
    public var checkedAt: String

    public var id: Chamber { chamber }

    public init(chamber: Chamber, inSession: Bool, convenesAt: String?, legislativeDay: String?, checkedAt: String) {
        self.chamber = chamber
        self.inSession = inSession
        self.convenesAt = convenesAt
        self.legislativeDay = legislativeDay
        self.checkedAt = checkedAt
    }
}

/// A vote with the live layer's timestamps. Flat on the wire (the vote's fields beside these three),
/// nested here, like ``VoteDetail``.
///
/// `state == .open` means a floor source has named the roll call and its official XML has not posted
/// yet — not that members are still voting: neither chamber publishes that (HANDOFF lesson 41).
public struct LiveVote: Codable, Sendable, Hashable, Identifiable {
    public var vote: Vote
    /// The floor's own time for the vote, ISO 8601. House only.
    public var openedAt: String?
    /// When the worker first saw a floor source name it, ISO 8601.
    public var announcedAt: String?
    /// When the worker first saw its roll call XML while polling live; nil if it was backfilled.
    public var postedAt: String?

    public var id: String { vote.id }

    private enum CodingKeys: String, CodingKey {
        case openedAt, announcedAt, postedAt
    }

    public init(vote: Vote, openedAt: String?, announcedAt: String?, postedAt: String?) {
        self.vote = vote
        self.openedAt = openedAt
        self.announcedAt = announcedAt
        self.postedAt = postedAt
    }

    public init(from decoder: Decoder) throws {
        vote = try Vote(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openedAt = try container.decodeIfPresent(String.self, forKey: .openedAt)
        announcedAt = try container.decodeIfPresent(String.self, forKey: .announcedAt)
        postedAt = try container.decodeIfPresent(String.self, forKey: .postedAt)
    }

    public func encode(to encoder: Encoder) throws {
        try vote.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(openedAt, forKey: .openedAt)
        try container.encode(announcedAt, forKey: .announcedAt)
        try container.encode(postedAt, forKey: .postedAt)
    }
}

/// `GET /v1/live`: each chamber's session state, and the votes open or just final, newest first.
public struct Live: Codable, Sendable, Hashable {
    public var chambers: [ChamberStatus]
    public var votes: [LiveVote]

    public init(chambers: [ChamberStatus], votes: [LiveVote]) {
        self.chambers = chambers
        self.votes = votes
    }

    public var openVotes: [LiveVote] { votes.filter { $0.vote.state == .open } }
}
