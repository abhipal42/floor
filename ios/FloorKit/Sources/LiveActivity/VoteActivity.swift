import Foundation
import Models
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The Live Activity for one vote (round 8, "A · Live Activity" and "B · Dynamic Island" of
/// https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn), generalized from "your rep" to everyone and
/// every bill you follow.
///
/// **A wire contract, not only a Swift type.** The worker starts and ends these by push
/// (`apps/worker/src/push.ts`, `activityAttributes` / `activityContent`), and ActivityKit decodes
/// the push's `attributes` and `content-state` into these with a plain `JSONDecoder` — so the keys,
/// the shapes and the type's name (`attributes-type: "VoteActivityAttributes"`) must match exactly.
/// Both sides are tested on `Tests/ModelsTests/Fixtures/live-activity-*.json`. Times are ISO 8601
/// strings, never `Date`: ActivityKit's decoder would read a `Date` as seconds since 2001.
public struct VoteActivityAttributes: Codable, Sendable, Hashable {
    /// What changes while the activity runs: open, then final with the score and your members' calls.
    public struct ContentState: Codable, Sendable, Hashable {
        public var state: VoteState
        /// How the chamber recorded the outcome, once final.
        public var result: String?
        /// Nil while open: the House posts no running count, so the open state shows what is known.
        public var totals: VoteTotals?
        /// The floor's own time for the vote (House).
        public var openedAt: String?
        /// When a floor source first named it: the only time the Senate's sources give.
        public var calledAt: String?
        /// Up to three of your members on the vote; `position` nil until the roll call posts.
        public var members: [Call]
        /// Your members on the vote beyond those listed.
        public var moreMembers: Int

        public init(
            state: VoteState, result: String?, totals: VoteTotals?, openedAt: String?, calledAt: String?,
            members: [Call], moreMembers: Int
        ) {
            self.state = state
            self.result = result
            self.totals = totals
            self.openedAt = openedAt
            self.calledAt = calledAt
            self.members = members
            self.moreMembers = moreMembers
        }
    }

    /// One of your members on the vote.
    public struct Call: Codable, Sendable, Hashable, Identifiable {
        /// Bioguide ID.
        public var id: String
        /// Surname, as the lock screen prints it.
        public var name: String
        /// Nil: not recorded yet.
        public var position: Position?
        /// The candidate they named, on a Speaker ballot.
        public var choice: String?

        public init(id: String, name: String, position: Position?, choice: String?) {
            self.id = id
            self.name = name
            self.position = position
            self.choice = choice
        }
    }

    public var voteId: String
    public var chamber: Chamber
    public var kind: VoteKind
    public var rollNumber: Int?
    public var threshold: VoteThreshold
    /// `On Passage`.
    public var question: String
    /// `H.R. 1013`, or nil for a procedural vote.
    public var citation: String?
    /// The bill's short title, or the nominee.
    public var title: String?

    public init(
        voteId: String, chamber: Chamber, kind: VoteKind, rollNumber: Int?, threshold: VoteThreshold,
        question: String, citation: String?, title: String?
    ) {
        self.voteId = voteId
        self.chamber = chamber
        self.kind = kind
        self.rollNumber = rollNumber
        self.threshold = threshold
        self.question = question
        self.citation = citation
        self.title = title
    }

    /// The lock screen lists this many members; the rest are counted. The worker's `ACTIVITY_MEMBERS_MAX`.
    public static let membersShown = 3
    /// The final stays up this long, then the activity ends itself (round 8, section A).
    public static let lingerAfterFinal: TimeInterval = 15 * 60
    /// An open vote with no final after this long reads as stale.
    public static let staleAfter: TimeInterval = 2 * 3600

    /// From a vote on `/v1/live`.
    public init(live: LiveVote) {
        self.init(
            voteId: live.vote.id, chamber: live.vote.chamber, kind: live.vote.kind, rollNumber: live.vote.rollNumber,
            threshold: live.vote.threshold, question: live.vote.question, citation: live.measure?.citation,
            title: live.measure?.title
        )
    }
}

public extension VoteActivityAttributes.ContentState {
    /// From a vote on `/v1/live` and your members on it, listed by surname. Positions only once final:
    /// an open vote's are not known, whatever `positions` says.
    init(live: LiveVote, members: [Member], positions: [MemberPosition] = []) {
        let final = live.vote.state == .final
        let byId = Dictionary(positions.map { ($0.member.bioguideId, $0) }, uniquingKeysWith: { a, _ in a })
        // By surname, as the worker lists them (`activityContent`), so an activity reads the same
        // whether the app or a push drew it.
        let sorted = members.sorted { ($0.lastName, $0.bioguideId) < ($1.lastName, $1.bioguideId) }
        let calls = sorted.map { member in
            let called = final ? byId[member.bioguideId] : nil
            return VoteActivityAttributes.Call(
                id: member.bioguideId, name: member.lastName, position: called?.position, choice: called?.choice
            )
        }
        self.init(
            state: final ? .final : .open,
            result: final ? live.vote.result : nil,
            totals: final ? live.vote.totals : nil,
            openedAt: live.openedAt,
            calledAt: live.announcedAt,
            members: Array(calls.prefix(VoteActivityAttributes.membersShown)),
            moreMembers: max(0, calls.count - VoteActivityAttributes.membersShown)
        )
    }
}

#if canImport(ActivityKit) && os(iOS)
extension VoteActivityAttributes: ActivityAttributes {}
#endif
