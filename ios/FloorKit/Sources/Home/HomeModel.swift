import APIClient
import Foundation
import Models
import BillScreen
import Onboarding
import RepScreen
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

    /// The positions as the shared card takes them.
    public var memberPositions: [MemberPosition] {
        positions.map { MemberPosition(member: $0.member, position: $0.position, choice: $0.choice) }
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
    /// Each member's party-loyalty record, for the rings on the delegation strip. Loaded beside the
    /// feed; a member whose record fails to load simply shows an empty ring.
    public internal(set) var loyalty: [String: PartyLoyalty] = [:]
    /// Deck cards opened this session, for the progress dots and "N of 5 caught up".
    public var seenInDeck: Set<String> = []

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

    /// Where a tap can lead from Home. Value-based navigation, so the vote and bill screens can
    /// push each other without either package depending on the other.
    public enum Route: Hashable, Sendable {
        case vote(id: String)
        case bill(id: String)
        case member(id: String)
        /// The catch-up deck.
        case catchUp
    }

    /// Screens are built here so the API client stays private to this model.
    public func voteScreen(id: String) -> VoteScreenModel {
        VoteScreenModel(voteId: id, memberIds: delegation.memberIds, api: api, delegation: delegation.members)
    }

    public func billScreen(id: String) -> BillScreenModel {
        BillScreenModel(billId: id, api: api, members: delegation.members)
    }

    /// The Your three tab's model, one for the life of this delegation.
    @ObservationIgnored public private(set) lazy var yourThree = YourThreeModel(members: delegation.members, api: api)

    public func repScreen(id: String) -> RepScreenModel {
        RepScreenModel(bioguideId: id, api: api)
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
            await loadLoyalty()
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load recent votes.")
        } catch {
            phase = .failed("Couldn't load recent votes.")
        }
    }

    private func loadLoyalty() async {
        let found: [(String, PartyLoyalty)] = await withTaskGroup(of: (String, PartyLoyalty)?.self) { group in
            for member in delegation.members {
                group.addTask { [api] in
                    (try? await api.member(id: member.bioguideId)).map { (member.bioguideId, $0.partyLoyalty) }
                }
            }
            var collected: [(String, PartyLoyalty)] = []
            for await entry in group { if let entry { collected.append(entry) } }
            return collected
        }
        loyalty = Dictionary(found, uniquingKeysWith: { first, _ in first })
    }

    /// The most recent final in the feed, for the split-flap board.
    public var latestFinal: FeedItem? { items.first { $0.vote.state == .final } }

    /// The catch-up deck: five finals from this feed, chosen by ``CatchUp/select(_:count:)``.
    public var deck: [FeedItem] { CatchUp.select(items) }

    /// Bills your members voted on recently, newest vote first, one row per bill. There is no "all
    /// bills" endpoint, so the Bills tab is built from the feed already loaded.
    public var bills: [FeedItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard let measure = item.measure, measure.kind == .bill else { return false }
            return seen.insert(measure.id).inserted
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
