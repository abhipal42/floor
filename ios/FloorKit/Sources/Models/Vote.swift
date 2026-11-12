import Foundation

public enum Chamber: String, Codable, Sendable {
    case house, senate
}

public enum VoteState: String, Codable, Sendable {
    case scheduled, open, final
}

/// How many votes a question needs. Mirrors `votesNeeded` in `@floor/shared`.
public enum VoteThreshold: String, Codable, Sendable {
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

/// A vote as returned by `GET /v1/votes/{id}`.
public struct Vote: Codable, Sendable, Identifiable, Equatable {
    public struct Totals: Codable, Sendable, Equatable {
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

    public var id: String
    public var chamber: Chamber
    public var congress: Int
    public var session: Int
    public var rollNumber: Int?
    public var question: String
    public var billId: String?
    public var state: VoteState
    public var threshold: VoteThreshold
    public var totals: Totals
    public var result: String?

    public init(
        id: String, chamber: Chamber, congress: Int, session: Int, rollNumber: Int?,
        question: String, billId: String?, state: VoteState, threshold: VoteThreshold,
        totals: Totals, result: String?
    ) {
        self.id = id
        self.chamber = chamber
        self.congress = congress
        self.session = session
        self.rollNumber = rollNumber
        self.question = question
        self.billId = billId
        self.state = state
        self.threshold = threshold
        self.totals = totals
        self.result = result
    }

    /// Votes needed to pass given who has voted so far.
    public var votesNeeded: Int {
        threshold.votesNeeded(voting: totals.voting)
    }

    /// The side currently ahead, or nil when tied.
    public var leader: VotePositionSide? {
        if totals.yea == totals.nay { return nil }
        return totals.yea > totals.nay ? .yea : .nay
    }
}

public enum VotePositionSide: String, Sendable {
    case yea, nay
}

public extension Vote {
    /// Real House roll call 100 of 2025, for previews and tests.
    static let sample = Vote(
        id: "house-119-1-100", chamber: .house, congress: 119, session: 1, rollNumber: 100,
        question: "On Motion to Concur in the Senate Amendment", billId: "119-hconres-14",
        state: .final, threshold: .majority,
        totals: .init(yea: 216, nay: 214, present: 0, notVoting: 3), result: "Passed"
    )
}
