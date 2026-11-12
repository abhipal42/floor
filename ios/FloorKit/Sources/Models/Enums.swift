import Foundation

/// The shared string enums from the API contract (`apps/api/openapi.json`).
///
/// These are single types rather than one per containing model on purpose: `Vote.chamber` and
/// `Member.chamber` are the same thing and must compare equal.

public enum Chamber: String, Codable, Sendable, Hashable, CaseIterable {
    case house, senate
}

/// `election` is a Speaker election, where members vote for a candidate instead of yea or nay.
public enum VoteKind: String, Codable, Sendable, Hashable, CaseIterable {
    case question, election
}

public enum VoteState: String, Codable, Sendable, Hashable, CaseIterable {
    case scheduled, open, final
}

/// How many votes a question needs. Mirrors `votesNeeded` in `@floor/shared`.
public enum VoteThreshold: String, Codable, Sendable, Hashable, CaseIterable {
    case majority
    case threeFifthsSworn = "three_fifths_sworn"
    case twoThirds = "two_thirds"

    public func votesNeeded(voting: Int, sworn: Int = 100) -> Int {
        switch self {
        case .majority: voting / 2 + 1
        case .twoThirds: (voting * 2 + 2) / 3
        case .threeFifthsSworn: (sworn * 3 + 4) / 5
        }
    }
}

/// How one member voted. `candidate` appears only on Speaker elections, alongside a `choice`.
public enum Position: String, Codable, Sendable, Hashable, CaseIterable {
    case yea, nay, present
    case notVoting = "not_voting"
    case candidate
}

/// The two sides of a yea/nay question, for talking about which one is ahead.
public enum VotePositionSide: String, Sendable, Hashable {
    case yea, nay
}
