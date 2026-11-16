import Foundation

/// `GET /v1/members?q=` — sitting members matching a name, a state or a seat, Senate first.
public struct MemberSearch: Codable, Sendable, Hashable {
    public var members: [Member]
    /// Members-elect matching the same query (a state, a seat, an elect's name), and the matching
    /// seats with no winner yet. Empty from an older API and once they take office.
    public var elect: [MemberElect]
    public var pending: [PendingSeat]

    public init(members: [Member], elect: [MemberElect] = [], pending: [PendingSeat] = []) {
        self.members = members
        self.elect = elect
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case members, elect, pending }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = try c.decode([Member].self, forKey: .members)
        (elect, pending) = ElectLists.decode(c, elect: .elect, pending: .pending)
    }
}

/// One row of `GET /v1/votes`: a final vote and what it was on, with nobody's position.
public struct RecentVote: Codable, Sendable, Hashable, Identifiable {
    public var vote: Vote
    /// nil for a procedural vote that refers to no measure.
    public var measure: MeasureSummary?

    public var id: String { vote.id }

    public init(vote: Vote, measure: MeasureSummary?) {
        self.vote = vote
        self.measure = measure
    }
}

/// `GET /v1/votes` — the most recent final votes, newest first.
public struct RecentVotes: Codable, Sendable, Hashable {
    public var votes: [RecentVote]

    public init(votes: [RecentVote]) {
        self.votes = votes
    }
}

public extension MemberSearch {
    static let sample = MemberSearch(members: [.sampleSenator, .sample])
}

public extension RecentVote {
    static let sample = RecentVote(vote: .sample, measure: .sample)
}

public extension RecentVotes {
    static let sample = RecentVotes(votes: [.sample])
}
