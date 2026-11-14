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


/// Loads the recent votes of everyone you follow — your reps (unless hidden) and the members you
/// added — merges them into one feed, and the latest finals in both chambers beside it.
@MainActor
@Observable
public final class HomeModel {
    public enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case house = "House"
        case senate = "Senate"

        /// The chamber this filter asks `/v1/votes` for; nil for both.
        public var chamber: Chamber? {
            switch self {
            case .all: nil
            case .house: .house
            case .senate: .senate
            }
        }
    }

    /// Finals' first switch: every recent final, or only the ones your members voted on.
    public enum Scope: String, CaseIterable, Sendable {
        case all
        case yours
    }

    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// Your members' votes, one card per vote. `internal(set)` so tests can seed a feed and
    /// exercise the filters without a server; the merge itself is a static function and is tested
    /// directly.
    public internal(set) var items: [FeedItem] = []
    /// The latest finals in both chambers, each carrying whichever of your members voted on it.
    public internal(set) var allItems: [FeedItem] = []
    /// Each member's recent votes, newest first, by Bioguide ID: the Following tab's latest-vote chip.
    public internal(set) var records: [String: [MemberVote]] = [:]
    public var filter: Filter = .all
    /// Defaults to your members when you have any; with none, "All" is the only feed there is.
    public var scope: Scope
    /// Each member's party-loyalty record, for the rings on the delegation strip and the Following
    /// rows. Loaded beside the feed; a member whose record fails to load simply shows no figure.
    public internal(set) var loyalty: [String: PartyLoyalty] = [:]
    /// Set while any of the feed or the rings is saved rather than fresh; see `revalidate`.
    public private(set) var saved: SavedCopy?
    /// Bumped by each load, so a load that has been overtaken (a pull-to-refresh beside the tab's
    /// own task) drops its results instead of writing them over newer ones.
    private var generation = 0
    /// The members the feed on screen was loaded for. Following or hiding someone changes
    /// `yourMembers`; only the members not yet loaded are then fetched (`sync`).
    private var loadedFor: Set<String>?
    /// The latest finals as `/v1/votes` sent them, and the chamber they were asked for.
    private var recentRows: [RecentVote] = []
    private var recentChamber: Chamber??
    /// Your members whose votes could not be loaded at all — no fresh copy and no saved one. The feed
    /// shows everyone else and says who is missing, rather than one member blanking it.
    public private(set) var unavailable: [Member] = []
    /// Deck cards opened this session, for the progress dots and "N of 5 caught up".
    public var seenInDeck: Set<String> = []

    /// nil when you skipped the district: the app then runs on the members you follow alone.
    public let delegation: Delegation?
    public let follows: Follows
    private let api: FloorAPI
    private let perMember: Int

    /// - Parameter perMember: how many votes to ask for per member. The merged feed is longer than
    ///   this when the chambers voted on different days.
    public init(delegation: Delegation?, follows: Follows, api: FloorAPI, perMember: Int = 25) {
        self.delegation = delegation
        self.follows = follows
        self.api = api
        self.perMember = perMember
        scope = follows.state.yourMembers(reps: delegation?.members ?? []).isEmpty ? .all : .yours
    }

    /// For previews and tests: a follow list that lives only in memory.
    public convenience init(delegation: Delegation?, api: FloorAPI, perMember: Int = 25) {
        self.init(delegation: delegation, follows: Follows(store: InMemoryFollowStore()), api: api, perMember: perMember)
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

    /// Your district's members, as onboarding found them; empty with no district.
    public var reps: [Member] { delegation?.members ?? [] }

    /// Your reps (minus any you hid) then everyone you follow: who "Your members" means.
    public var yourMembers: [Member] { follows.state.yourMembers(reps: reps) }

    /// Your members as the vote route can take them for one vote: `?members=` names at most ten, so
    /// the ones the feed knows voted on it go first, then the rest of your members in order.
    func voteMembers(for voteId: String) -> [Member] {
        let onCard = (items + allItems).first { $0.vote.id == voteId }?.positions.map(\.member) ?? []
        var seen = Set<String>()
        return Array((onCard + yourMembers).filter { seen.insert($0.bioguideId).inserted }.prefix(10))
    }

    /// Screens are built here so the API client stays private to this model.
    public func voteScreen(id: String) -> VoteScreenModel {
        let members = voteMembers(for: id)
        return VoteScreenModel(voteId: id, memberIds: members.map(\.bioguideId), api: api, delegation: members)
    }

    public func billScreen(id: String) -> BillScreenModel {
        BillScreenModel(billId: id, api: api, members: yourMembers)
    }

    public func repScreen(id: String) -> RepScreenModel {
        RepScreenModel(bioguideId: id, api: api)
    }

    /// The "+ Add" sheet's search, a fresh one each time it opens.
    public func memberSearch() -> MemberSearchModel {
        MemberSearchModel(api: api)
    }

    /// The scope actually shown: "Your members" needs someone in it.
    public var shownScope: Scope { yourMembers.isEmpty ? .all : scope }

    /// The feed for the scope, before the chamber filter: the board, the deck and the cards.
    public var scopedItems: [FeedItem] { shownScope == .yours ? items : allItems }

    public var visibleItems: [FeedItem] {
        switch filter {
        case .all: scopedItems
        case .house: scopedItems.filter { $0.vote.chamber == .house }
        case .senate: scopedItems.filter { $0.vote.chamber == .senate }
        }
    }

    /// What an empty feed says. D.C. and the territories have no senators, so their Senate filter
    /// is empty by design, not for want of recent votes — unless you follow a senator.
    public var emptyFeedMessage: String {
        if filter == .senate, shownScope == .yours, let delegation, delegation.senators.isEmpty,
           !yourMembers.contains(where: { $0.chamber == .senate }) {
            return "\(StateName.full(delegation.district.state)) has no senators, so there are no Senate votes to show."
        }
        return "No recent votes in this chamber."
    }

    /// True until a load has finished with everything fresh — including one that was cancelled
    /// part-way, as pushing a vote cancels the tab's task — so the tab refreshes when it reappears.
    public var needsRefresh: Bool {
        guard case .loaded = phase, saved == nil else { return true }
        return loadedFor == nil
    }

    /// Changes when the set of your members or the chamber filter does, for the view's
    /// `.task(id:)`, which runs `sync`. Order is left out: reordering only regroups (`orderKey`).
    public var syncKey: String {
        yourMembers.map(\.bioguideId).sorted().joined(separator: ",") + "|" + filter.rawValue
    }

    /// Changes when the order of your members does: the cards list them in that order.
    public var orderKey: String { yourMembers.map(\.bioguideId).joined(separator: ",") }

    /// How many finals to ask for in "All".
    static let recentLimit = 40

    /// Everything, from scratch: first load, pull to refresh.
    public func load() async {
        await fetch(yourMembers, replacing: true, recent: true)
    }

    /// Brings the feed up to date with your members and the chamber filter, fetching only what is
    /// missing: a newly followed member's record, or the latest finals for a newly picked chamber.
    /// Unfollowing, hiding and reordering fetch nothing; the cards are regrouped from what is held.
    public func sync() async {
        guard !needsRefresh else {
            await load()
            return
        }
        let missing = yourMembers.filter { records[$0.bioguideId] == nil }
        if !missing.isEmpty {
            await fetch(missing, replacing: false, recent: false)
        } else {
            loadedFor = Set(yourMembers.map(\.bioguideId))
            regroup()
        }
        if recentChamber != .some(filter.chamber) { await loadRecent() }
    }

    /// The cards again from the records held, in your members' current order.
    public func regroup() {
        let members = yourMembers
        items = Self.merge(members.compactMap { m in records[m.bioguideId].map { (m, $0) } },
                           order: members.map(\.bioguideId))
        if recentChamber != nil { allItems = Self.annotate(recentRows, with: items) }
        let ids = Set(members.map(\.bioguideId))
        unavailable = unavailable.filter { ids.contains($0.bioguideId) }
    }

    /// The latest finals for the chamber picked, so "All" + Senate is the Senate's latest forty
    /// rather than the Senate's share of both chambers' forty. A failure keeps what is on screen.
    public func loadRecent() async {
        let chamber = filter.chamber
        do {
            try await revalidate(api, report: { _ in }) { pass in
                let rows = try await pass.api.recentVotes(chamber: chamber, limit: Self.recentLimit).votes
                guard filter.chamber == chamber else { throw CancellationError() }
                recentRows = rows
                recentChamber = .some(chamber)
                regroup()
            }
        } catch {
            // Cancelled, or offline with nothing saved: the list on screen stays, filtered here.
        }
    }

    /// Loads `members`' records — each on its own, so one that fails leaves the rest — and, with
    /// `recent`, the latest finals. `replacing` starts the records afresh (a full load); otherwise
    /// they are added to what is held.
    private func fetch(_ members: [Member], replacing: Bool, recent includeRecent: Bool) async {
        generation += 1
        let mine = generation
        // A feed already on screen stays there while it refreshes, rather than flashing a spinner.
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        let everyone = yourMembers
        let chamber = filter.chamber

        do {
            // Saved feed first, then the network; see `revalidate`.
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [perMember] pass in
                // One request per member, six at a time — not one per card, which is what the
                // measure on each row avoids.
                let results = try await throttledMap(members) { member in
                    (member, await pass.attempt { try await $0.memberVotes(id: member.bioguideId, limit: perMember).votes })
                }
                var loaded: [String: [MemberVote]] = [:]
                var failed: [Member] = []
                var firstError: (any Error)?
                for (member, result) in results {
                    switch result {
                    case let .success(votes): loaded[member.bioguideId] = votes
                    case let .failure(error):
                        if error is CancellationError { throw error }
                        failed.append(member)
                        firstError = firstError ?? error
                    }
                }
                // Nobody's record came: that is the feed failing, with the first member's own error.
                if loaded.isEmpty, let firstError { throw firstError }
                // With nobody to follow, the latest finals are the whole feed and must load; beside
                // your members' feed they are best-effort, so one failing route cannot blank it.
                let recent: [RecentVote]? = !includeRecent ? nil : everyone.isEmpty
                    ? try await pass.api.recentVotes(chamber: chamber, limit: Self.recentLimit).votes
                    : await pass.bestEffort { try await $0.recentVotes(chamber: chamber, limit: Self.recentLimit).votes }
                guard mine == generation else { throw CancellationError() }
                if replacing { records = [:] }
                records.merge(loaded, uniquingKeysWith: { _, new in new })
                unavailable = (replacing ? [] : unavailable.filter { loaded[$0.bioguideId] == nil }) + failed
                if let recent {
                    recentRows = recent
                    recentChamber = .some(chamber)
                }
                loadedFor = Set(everyone.map(\.bioguideId))
                regroup()
                phase = .loaded
                let found = await loadLoyalty(pass, members: members)
                guard mine == generation else { throw CancellationError() }
                loyalty.merge(found, uniquingKeysWith: { _, new in new })
            }
        } catch is CancellationError {
            // Overtaken or cancelled: nothing to say, and `needsRefresh` still holds.
        } catch {
            guard mine == generation else { return }
            if case .loaded = phase, !replacing {
                // A newly followed member failed to load: the feed on screen stays, and says so.
                unavailable += members.filter { records[$0.bioguideId] == nil && !unavailable.contains($0) }
                return
            }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load recent votes.")
        }
    }

    /// "Couldn't load Cruz's votes." / "Couldn't load 3 members' votes: Cruz, Cornyn and Jeffries."
    public var unavailableNote: String? {
        let names = unavailable.map(\.lastName)
        guard let first = names.first else { return nil }
        if names.count == 1 { return "Couldn't load \(first)'s votes." }
        let list = names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Couldn't load \(names.count) members' votes: \(list)."
    }

    /// Best-effort: a record that fails to refresh falls back to its saved ring, and the note says
    /// so. Merged rather than assigned, so a ring with nothing to show keeps what it had.
    private func loadLoyalty(_ pass: Pass, members: [Member]) async -> [(String, PartyLoyalty)] {
        let found = try? await throttledMap(members) { member in
            let id = member.bioguideId
            return await pass.bestEffort({ try await $0.member(id: id) }).map { (id, $0.partyLoyalty) }
        }
        return (found ?? []).compactMap(\.self)
    }

    /// The most recent final in the feed, for the split-flap board.
    public var latestFinal: FeedItem? { scopedItems.first { $0.vote.state == .final } }

    /// The catch-up deck: five finals from this feed, chosen by ``CatchUp/select(_:count:)``.
    public var deck: [FeedItem] { CatchUp.select(scopedItems) }

    /// Bills your members voted on recently, newest vote first, one row per bill — or, following
    /// nobody, the bills in the latest finals. There is no "all bills" endpoint, so the Bills tab is
    /// built from the feeds already loaded.
    public var bills: [FeedItem] {
        var seen = Set<String>()
        return (yourMembers.isEmpty ? allItems : items).filter { item in
            guard let measure = item.measure, measure.kind == .bill else { return false }
            return seen.insert(measure.id).inserted
        }
    }

    /// One member's most recent vote, for the Following tab's chip.
    public func latestVote(of member: Member) -> MemberVote? { records[member.bioguideId]?.first }

    /// Groups every member's rows by vote, newest first.
    ///
    /// Two senators voting on the same roll call produce one card carrying both positions, not two
    /// cards; so does every followed member who voted on it. Ordering is by when the vote happened;
    /// a vote with no timestamp sorts last rather than jumping to the top.
    ///
    /// - Parameter order: Bioguide IDs in the order a card lists its members (your reps, then the
    ///   members you follow, in your order). nil orders House before Senate, then by surname.
    nonisolated static func merge(_ records: [(Member, [MemberVote])], order: [String]? = nil) -> [FeedItem] {
        var byVote: [String: FeedItem] = [:]
        // Sort the inputs so a card's positions come out in a stable order whatever order the
        // requests finished in.
        let rank = Dictionary((order ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = records.sorted { lhs, rhs in
            if order != nil {
                return (rank[lhs.0.bioguideId] ?? .max) < (rank[rhs.0.bioguideId] ?? .max)
            }
            return (lhs.0.chamber == .house ? 0 : 1, lhs.0.lastName) < (rhs.0.chamber == .house ? 0 : 1, rhs.0.lastName)
        }
        for (member, rows) in ordered {
            for row in rows {
                let position = FeedItem.Position(member: member, position: row.position, choice: row.choice)
                if var existing = byVote[row.vote.id] {
                    // A member listed twice (a rep you also follow) is one chip, not two.
                    guard !existing.positions.contains(where: { $0.id == position.id }) else { continue }
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

    /// The latest finals as cards, each carrying your members' positions where your feed has that
    /// vote. A vote none of them took part in is a card with no chips.
    nonisolated static func annotate(_ recent: [RecentVote], with yours: [FeedItem]) -> [FeedItem] {
        let byVote = Dictionary(yours.map { ($0.vote.id, $0) }, uniquingKeysWith: { a, _ in a })
        return recent.map { row in
            guard var known = byVote[row.vote.id] else {
                return FeedItem(vote: row.vote, measure: row.measure, positions: [])
            }
            known.vote = row.vote
            known.measure = known.measure ?? row.measure
            return known
        }
    }
}
