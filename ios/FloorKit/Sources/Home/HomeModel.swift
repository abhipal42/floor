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
/// added — and of the bills and topics you follow, merges them into one feed (Finals' "Following"),
/// and the latest finals in both chambers beside it.
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

    /// Finals' first switch: every recent final, or "Following" — the ones a member, bill or topic
    /// you follow is in (`yours`, named before bills and topics could be followed).
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
    /// Each followed bill as `GET /v1/bills/{id}` last gave it, by id: its votes are in the Following
    /// feed, and its stage and latest action are the Following tab's Bills.
    public internal(set) var billRecords: [String: Bill] = [:]
    /// The latest finals on bills in the topics you follow (`/v1/votes?topic=…`), both chambers.
    var topicRows: [RecentVote] = []
    /// The topics and chamber `topicRows` was fetched for, or nil before any fetch did.
    private var topicsLoadedFor: (topics: Set<String>, chamber: Chamber?)?
    /// Followed bills whose record could not be loaded at all, by id.
    public private(set) var unavailableBills: [String] = []
    /// All 32 topics with their counts: the Following tab's Topics. Loaded when that segment shows.
    public private(set) var topicList: TopicList?
    /// Set when the topics could not be loaded and none were saved.
    public private(set) var topicListError: String?
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
        let state = follows.state
        scope = state.yourMembers(reps: delegation?.members ?? []).isEmpty && state.followedBillIds.isEmpty
            && state.followedTopics.isEmpty ? .all : .yours
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
        /// A topic's page: every bill in one CRS policy area.
        case topic(name: String)
        /// The catch-up deck.
        case catchUp
    }

    /// Your district's members, as onboarding found them; empty with no district.
    public var reps: [Member] { delegation?.members ?? [] }

    /// Your reps (minus any you hid) then everyone you follow: who "Your members" means.
    public var yourMembers: [Member] { follows.state.yourMembers(reps: reps) }

    /// The bills you follow, by id, in your order.
    public var followedBillIds: [String] { follows.state.followedBillIds }

    /// The topics you follow, in your order.
    public var followedTopics: [String] { follows.state.followedTopics }

    /// How many followed bills the feed fetches, one request each: the most recently followed.
    /// The rest are listed from their saved rows, and their votes are not in Finals (`billLimitNote`).
    static let billFetchLimit = 20

    /// The followed bills whose records the feed fetches — the ``billFetchLimit`` most recently
    /// followed — in your order.
    public var fetchedBillIds: [String] {
        let entries = follows.state.entries(.bill)
        guard entries.count > Self.billFetchLimit else { return entries.map(\.id) }
        let newest = Set(entries.sorted { $0.followedAt > $1.followedAt }.prefix(Self.billFetchLimit).map(\.id))
        return entries.map(\.id).filter(newest.contains)
    }

    /// Said under the feed and the Bills list when you follow more bills than the feed fetches.
    public var billLimitNote: String? {
        let rest = followedBillIds.count - fetchedBillIds.count
        guard rest > 0 else { return nil }
        return "Finals has votes on your \(Self.billFetchLimit) most recently followed bills. "
            + "The other \(rest) \(rest == 1 ? "is" : "are") listed as last saved."
    }

    /// Anything to put in Finals' "Following": a member, a bill or a topic.
    public var followsAnything: Bool {
        !yourMembers.isEmpty || !followedBillIds.isEmpty || !followedTopics.isEmpty
    }

    /// The Following tab's Bills, in your order: each bill's freshest row — from its record when it
    /// has loaded, else as saved when you followed it. A fresh record from a response saved before
    /// the API sent stages keeps the saved row's stage and label rather than losing them.
    public var followedBills: [BillListItem] {
        follows.state.entries(.bill).compactMap { entry in
            guard let record = billRecords[entry.id] else { return entry.bill }
            return BillListItem(bill: record, keeping: entry.bill)
        }
    }

    /// The Following tab's followed topics, each with its counts once `/v1/topics` has answered.
    public var followedTopicRows: [(name: String, topic: Topic?)] {
        followedTopics.map { name in (name, topicList?.topics.first { $0.name == name }) }
    }

    /// Topics you don't follow, biggest first: the Following tab's suggestions.
    public var suggestedTopics: [Topic] {
        let followed = Set(followedTopics)
        return Array((topicList?.topics ?? [])
            .filter { !followed.contains($0.name) && $0.bills > 0 }
            .sorted { ($0.bills, $1.name) > ($1.bills, $0.name) }
            .prefix(Self.suggestionCount))
    }

    static let suggestionCount = 6

    /// Why `item` is in the Following feed beyond its member chips: the bills and topics you follow
    /// that it is on. One card per vote whatever matched, so a vote on a followed bill in a followed
    /// topic, with followed members on it, is one card that says both.
    public func matches(_ item: FeedItem) -> [FollowMatch] {
        Self.matches(item, bills: Set(followedBillIds), topics: Set(followedTopics))
    }

    nonisolated static func matches(_ item: FeedItem, bills: Set<String>, topics: Set<String>) -> [FollowMatch] {
        guard let measure = item.measure, measure.kind == .bill else { return [] }
        var found: [FollowMatch] = []
        if bills.contains(measure.id) { found.append(.bill(citation: measure.citation)) }
        if let area = measure.policyArea, topics.contains(area) { found.append(.topic(area)) }
        return found
    }

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
    public func followSearch() -> FollowSearchModel {
        FollowSearchModel(api: api)
    }

    /// A topic's page.
    public func topicPage(name: String) -> TopicPageModel {
        TopicPageModel(name: name, api: api)
    }

    /// The scope actually shown: "Following" needs something followed.
    public var shownScope: Scope { followsAnything ? scope : .all }

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

    /// Changes when the set of your members, of the bills or topics you follow, or the chamber
    /// filter does, for the view's `.task(id:)`, which runs `sync`. Order is left out: reordering
    /// only regroups (`orderKey`).
    public var syncKey: String {
        [yourMembers.map(\.bioguideId), followedBillIds, followedTopics]
            .map { $0.sorted().joined(separator: ",") }
            .joined(separator: "|") + "|" + filter.rawValue
    }

    /// Changes when the order of your members does: the cards list them in that order.
    public var orderKey: String { yourMembers.map(\.bioguideId).joined(separator: ",") }

    /// How many finals to ask for in "All".
    static let recentLimit = 40

    /// Everything, from scratch: first load, pull to refresh.
    public func load() async {
        await fetch(yourMembers, bills: fetchedBillIds, replacing: true, recent: true, topics: true)
    }

    /// Brings the feed up to date with what you follow and the chamber filter, fetching only what is
    /// missing: a newly followed member's or bill's record, the topics' votes when a topic was
    /// added, or the latest finals for a newly picked chamber. Unfollowing, hiding and reordering
    /// fetch nothing; the cards are regrouped from what is held.
    public func sync() async {
        guard !needsRefresh else {
            await load()
            return
        }
        let missing = yourMembers.filter { records[$0.bioguideId] == nil }
        let missingBills = fetchedBillIds.filter { billRecords[$0] == nil }
        // A topic added, or the chamber switched: the topics' finals are asked for by chamber.
        let topics = Topic.canonical(followedTopics)
        let topicsDue = !topics.isEmpty && (topicsLoadedFor.map {
            !Set(topics).isSubset(of: $0.topics) || $0.chamber != filter.chamber
        } ?? true)
        if !missing.isEmpty || !missingBills.isEmpty || topicsDue {
            await fetch(missing, bills: missingBills, replacing: false, recent: false, topics: topicsDue)
        } else {
            loadedFor = Set(yourMembers.map(\.bioguideId))
            regroup()
        }
        if recentChamber != .some(filter.chamber) { await loadRecent() }
    }

    /// The cards again from the records held, in your members' current order: your members' votes,
    /// then every vote on a bill you follow and the topics' latest finals, one card per vote.
    public func regroup() {
        let members = yourMembers
        let memberItems = Self.merge(members.compactMap { m in records[m.bioguideId].map { (m, $0) } },
                                     order: members.map(\.bioguideId))
        let topics = Set(followedTopics)
        let billVotes = fetchedBillIds.compactMap { billRecords[$0] }.flatMap { bill in
            bill.votes.map { RecentVote(vote: $0, measure: bill.measure) }
        }
        // Rows for a topic since unfollowed stay out without a refetch.
        let topicVotes = topicRows.filter { $0.measure?.policyArea.map(topics.contains) ?? false }
        items = Self.combine(memberItems, with: billVotes + topicVotes)
        if recentChamber != nil { allItems = Self.annotate(recentRows, with: items) }
        let ids = Set(members.map(\.bioguideId))
        unavailable = unavailable.filter { ids.contains($0.bioguideId) }
        let billIds = Set(followedBillIds)
        unavailableBills = unavailableBills.filter(billIds.contains)
    }

    /// Loads the 32 topics and their counts for the Following tab's Topics, saved first then fresh.
    public func loadTopics() async {
        do {
            try await revalidate(api, report: { _ in }) { pass in
                topicList = try await pass.api.topics()
                topicListError = nil
            }
        } catch is CancellationError {
        } catch {
            if topicList == nil {
                topicListError = (error as? FloorAPIError)?.errorDescription ?? "Couldn't load topics."
            }
        }
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

    /// Loads `members`' and `bills`' records — each on its own, so one that fails leaves the rest —
    /// with `topics` the followed topics' latest finals, and with `recent` the latest finals.
    /// `replacing` starts the records afresh (a full load); otherwise they are added to what is held.
    private func fetch(
        _ members: [Member], bills: [String], replacing: Bool, recent includeRecent: Bool, topics includeTopics: Bool
    ) async {
        generation += 1
        let mine = generation
        // A feed already on screen stays there while it refreshes, rather than flashing a spinner.
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        let everyone = yourMembers
        let chamber = filter.chamber
        // Only the 32 are sent; a name that is not one (a hand edit, a renamed area) is no request.
        let topics = Topic.canonical(followedTopics)
        let anything = followsAnything

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
                // One request per followed bill, six at a time: its votes and where it stands.
                let billResults = try await throttledMap(bills) { id in
                    (id, await pass.attempt { try await $0.bill(id: id) })
                }
                var loadedBills: [String: Bill] = [:]
                var failedBills: [String] = []
                for (id, result) in billResults {
                    switch result {
                    case let .success(bill): loadedBills[id] = bill
                    case let .failure(error):
                        if error is CancellationError { throw error }
                        failedBills.append(id)
                        firstError = firstError ?? error
                    }
                }
                // Nothing you follow came: that is the feed failing, with the first one's own error.
                if loaded.isEmpty, loadedBills.isEmpty, let firstError { throw firstError }
                // The topics' latest finals: one request for all of them, in the chamber on screen,
                // best-effort. nil (failed, nothing saved) keeps the rows held and leaves the topics
                // due for the next sync.
                let topicVotes: [RecentVote]? = !includeTopics ? nil : topics.isEmpty ? []
                    : await pass.bestEffort {
                        try await $0.recentVotes(chamber: chamber, limit: Self.recentLimit, topics: topics).votes
                    }
                // Following nothing at all, the latest finals are the whole feed and must load; beside
                // a Following feed (members, bills or topics) they are best-effort, so one failing
                // route cannot blank it.
                let recent: [RecentVote]? = !includeRecent ? nil : !anything
                    ? try await pass.api.recentVotes(chamber: chamber, limit: Self.recentLimit).votes
                    : await pass.bestEffort { try await $0.recentVotes(chamber: chamber, limit: Self.recentLimit).votes }
                guard mine == generation else { throw CancellationError() }
                if replacing {
                    records = [:]
                    billRecords = [:]
                }
                records.merge(loaded, uniquingKeysWith: { _, new in new })
                unavailable = (replacing ? [] : unavailable.filter { loaded[$0.bioguideId] == nil }) + failed
                billRecords.merge(loadedBills, uniquingKeysWith: { _, new in new })
                unavailableBills = (replacing ? [] : unavailableBills.filter { loadedBills[$0] == nil }) + failedBills
                if let topicVotes {
                    topicRows = topicVotes
                    topicsLoadedFor = (Set(topics), chamber)
                }
                // The saved rows follow the bills, so the list reads right before the next fetch.
                if !loadedBills.isEmpty {
                    follows.update { state in
                        for bill in loadedBills.values {
                            let saved = state.entries(.bill).first { $0.id == bill.id }?.bill
                            state.refresh(bill: BillListItem(bill: bill, keeping: saved))
                        }
                    }
                }
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
                // A newly followed member or bill failed to load: the feed on screen stays, and says so.
                unavailable += members.filter { records[$0.bioguideId] == nil && !unavailable.contains($0) }
                unavailableBills += bills.filter { billRecords[$0] == nil && !unavailableBills.contains($0) }
                return
            }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load recent votes.")
        }
    }

    /// Finals' note: the members' then the bills'.
    public var unavailableNote: String? {
        let notes = [unavailableMembersNote, unavailableBillsNote].compactMap(\.self)
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// "Couldn't load Cruz's votes." / "Couldn't load 3 members' votes: Cruz, Cornyn and Jeffries."
    public var unavailableMembersNote: String? {
        let names = unavailable.map(\.lastName)
        if names.count == 1 { return "Couldn't load \(names[0])'s votes." }
        if names.count > 1 { return "Couldn't load \(names.count) members' votes: \(Self.list(names))." }
        return nil
    }

    /// The Bills list's note: "Couldn't load H.R. 1013." / "Couldn't load 2 bills: H.R. 1013 and S. 2."
    public var unavailableBillsNote: String? {
        let saved = Dictionary(follows.state.followedBills.map { ($0.id, $0.citation) }, uniquingKeysWith: { a, _ in a })
        let bills = unavailableBills.map { saved[$0] ?? $0 }
        if bills.count == 1 { return "Couldn't load \(bills[0])." }
        if bills.count > 1 { return "Couldn't load \(bills.count) bills: \(Self.list(bills))." }
        return nil
    }

    private nonisolated static func list(_ names: [String]) -> String {
        names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
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
        return (followsAnything ? items : allItems).filter { item in
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
        return newestFirst(Array(byVote.values))
    }

    /// Newest vote first; a vote with no timestamp last; ties by id, so the order is stable.
    nonisolated static func newestFirst(_ items: [FeedItem]) -> [FeedItem] {
        items.sorted { lhs, rhs in
            switch (lhs.vote.occurredAtDate, rhs.vote.occurredAtDate) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.vote.id > rhs.vote.id
            }
        }
    }

    /// Your members' cards plus the votes on bills and in topics you follow, one card per vote: a
    /// vote already on a member's card stays that card (its measure filled in if the card lacked
    /// one, or lacked its topic), and any other becomes a card with no chips.
    nonisolated static func combine(_ items: [FeedItem], with extra: [RecentVote]) -> [FeedItem] {
        var byVote = Dictionary(items.map { ($0.vote.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in extra {
            if var known = byVote[row.vote.id] {
                if known.measure == nil {
                    known.measure = row.measure
                } else if known.measure?.policyArea == nil, let fuller = row.measure, fuller.id == known.measure?.id {
                    known.measure?.policyArea = fuller.policyArea
                }
                byVote[row.vote.id] = known
            } else {
                byVote[row.vote.id] = FeedItem(vote: row.vote, measure: row.measure, positions: [])
            }
        }
        return newestFirst(Array(byVote.values))
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
