import Foundation

/// `GET /v1/members?q=` — sitting members matching a name, a state or a seat, Senate first.
public struct MemberSearch: Codable, Sendable, Hashable {
    public var members: [Member]

    public init(members: [Member]) {
        self.members = members
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
