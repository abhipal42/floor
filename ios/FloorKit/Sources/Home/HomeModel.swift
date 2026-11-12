import APIClient
import Foundation
import Models
import Onboarding
import VoteScreen

/// One card in the feed: a vote, and how each of your own members voted on it.
///
/// Your representative votes on House roll calls and your senators on Senate ones, so a row carries
/// whichever of them took part — one for a House vote, two for a Senate vote.
public struct FeedItem: Identifiable, Sendable, Hashable {
    public struct Position: Sendable, Hashable, Identifiable {
        public var member: Member
        public var position: Models.Position
        public var choice: String?

        public var id: String { member.bioguideId }
    }

    public var vote: Vote
    public var measure: MeasureSummary?
    public var positions: [Position]

    public var id: String { vote.id }

    /// What to put on the card: the measure's name where there is one, else the question itself,
    /// which is all a procedural vote has.
    public var title: String {
        measure?.headline ?? vote.question
    }

    /// "Doggett voted Nay", or "Cornyn Yea · Cruz Nay" when your senators split.
    public var summary: String {
        guard !positions.isEmpty else { return "" }
        if positions.count == 1, let only = positions.first {
            // "voted did not vote" is how this reads if not-voting goes through the usual phrasing.
            return only.position == .notVoting
                ? "\(only.member.lastName) did not vote"
                : "\(only.member.lastName) voted \(label(only))"
        }
        return positions.map { "\($0.member.lastName) \(label($0))" }.joined(separator: " · ")
    }

    /// True when your members did not all vote the same way.
    public var isSplit: Bool {
        Set(positions.map(\.position)).count > 1
    }

    private func label(_ position: Position) -> String {
        switch position.position {
        case .yea: "Yea"
        case .nay: "Nay"
        case .present: "Present"
        case .notVoting: "did not vote"
        case .candidate: position.choice ?? "a candidate"
        }
    }
}

/// Loads the recent votes of everyone in your delegation and merges them into one feed.
@MainActor
@Observable
public final class HomeModel {
    public enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case house = "House"
        case senate = "Senate"
    }

    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// `internal(set)` so tests can seed a feed and exercise the filter without a server; the
    /// merge itself is a static function and is tested directly.
    public internal(set) var items: [FeedItem] = []
    public var filter: Filter = .all

    public let delegation: Delegation
    private let api: FloorAPI
    private let perMember: Int

    /// - Parameter perMember: how many votes to ask for per member. The merged feed is longer than
    ///   this when the chambers voted on different days.
    public init(delegation: Delegation, api: FloorAPI, perMember: Int = 25) {
        self.delegation = delegation
        self.api = api
        self.perMember = perMember
    }

    /// The screen for one card, built here so the API client stays private to this model.
    public func voteScreen(for item: FeedItem) -> VoteScreenModel {
        VoteScreenModel(voteId: item.vote.id, memberIds: delegation.memberIds, api: api)
    }

    public var visibleItems: [FeedItem] {
        switch filter {
        case .all: items
        case .house: items.filter { $0.vote.chamber == .house }
        case .senate: items.filter { $0.vote.chamber == .senate }
        }
    }

    public func load() async {
        phase = .loading
        let members = delegation.members
        guard !members.isEmpty else {
            phase = .failed("We don't know who represents you yet.")
            return
        }

        do {
            // One request per member, in parallel. Three members, so three requests — not one per
            // card, which is what the measure on each row avoids.
            let records: [(Member, [MemberVote])] = try await withThrowingTaskGroup(
                of: (Member, [MemberVote]).self
            ) { group in
                for member in members {
                    group.addTask { [api, perMember] in
                        (member, try await api.memberVotes(id: member.bioguideId, limit: perMember).votes)
                    }
                }
                var collected: [(Member, [MemberVote])] = []
                for try await record in group { collected.append(record) }
                return collected
            }
            items = Self.merge(records)
            phase = .loaded
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load recent votes.")
        } catch {
            phase = .failed("Couldn't load recent votes.")
        }
    }

    /// Groups every member's rows by vote, newest first.
    ///
    /// Two senators voting on the same roll call produce one card carrying both positions, not two
    /// cards. Ordering is by when the vote happened; a vote with no timestamp sorts last rather
    /// than jumping to the top.
    nonisolated static func merge(_ records: [(Member, [MemberVote])]) -> [FeedItem] {
        var byVote: [String: FeedItem] = [:]
        // Sort the inputs so a card's positions come out in a stable order whatever order the
        // requests finished in.
        let ordered = records.sorted { lhs, rhs in
            (lhs.0.chamber == .house ? 0 : 1, lhs.0.lastName) < (rhs.0.chamber == .house ? 0 : 1, rhs.0.lastName)
        }
        for (member, rows) in ordered {
            for row in rows {
                let position = FeedItem.Position(member: member, position: row.position, choice: row.choice)
                if var existing = byVote[row.vote.id] {
                    existing.positions.append(position)
                    // Keep whichever row knows the measure; they should agree, but a null must not
                    // overwrite a name.
                    existing.measure = existing.measure ?? row.measure
                    byVote[row.vote.id] = existing
                } else {
                    byVote[row.vote.id] = FeedItem(
                        vote: row.vote, measure: row.measure, positions: [position]
                    )
                }
            }
        }
        return byVote.values.sorted { lhs, rhs in
            switch (lhs.vote.occurredAtDate, rhs.vote.occurredAtDate) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.vote.id > rhs.vote.id
            }
        }
    }
}
