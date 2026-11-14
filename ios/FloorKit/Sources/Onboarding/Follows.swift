import Foundation
import Models
import Observation

/// What can be followed: members (v0.2.28), and bills and CRS policy areas — "topics" — since
/// v0.2.29 (the locked Round 10 design). An entry is a kind and an id, whatever the kind, which is
/// why bills and topics needed no storage migration.
public enum FollowKind: String, Codable, Sendable, Hashable, CaseIterable {
    case member
    /// A bill, by API id: `119-hr-2207`.
    case bill
    /// A CRS policy area, by its name as `Bill.policyArea` gives it: `Taxation`.
    case topic
}

/// One thing you follow.
public struct FollowEntry: Codable, Sendable, Hashable {
    public var kind: FollowKind
    /// A Bioguide ID, a bill id or a policy area, by `kind`.
    public var id: String
    public var followedAt: Date
    /// For a member: their public record as it was when you followed them, so the list, the feed
    /// and the widget can name them without a request. Public data about them; nothing about you.
    public var member: Member?
    /// For a bill: its list row as last seen (citation, label, stage, latest action), so the Bills
    /// list can name it before — or without — a request. Refreshed whenever the bill is fetched.
    /// Absent in a record from v0.2.28, which never followed a bill.
    public var bill: BillListItem?

    public init(kind: FollowKind, id: String, followedAt: Date, member: Member? = nil, bill: BillListItem? = nil) {
        self.kind = kind
        self.id = id
        self.followedAt = followedAt
        self.member = member
        self.bill = bill
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, followedAt, member, bill
    }

    /// Lossy where it can be: the saved member or bill row is a cache of public data, so one this
    /// build cannot read (a later build's new stage, a bad write) is dropped and the entry kept —
    /// the next fetch fills it in. Only a kind and id it cannot read lose the entry, and only it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FollowKind.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        followedAt = (try? container.decodeIfPresent(Date.self, forKey: .followedAt)) ?? .distantPast
        member = try? container.decodeIfPresent(Member.self, forKey: .member)
        bill = try? container.decodeIfPresent(BillListItem.self, forKey: .bill)
    }

    /// Unique across kinds: `member:J000294`.
    public var key: String { "\(kind.rawValue):\(id)" }
}

/// Everything the Following tab keeps: what you follow, in your order; which of your own reps you
/// hid; and each member's alert choice.
///
/// **No address and no coordinates**, ever: your reps are not in here at all (they come from the
/// saved `Delegation`, i.e. your district), only the ids of any you chose to hide. Kept on the phone
/// in the App Group, so the widget can read it; there is no account.
public struct FollowState: Codable, Sendable, Hashable {
    /// Display order, per kind. Following adds to the front, so the newest is first until you
    /// reorder.
    public private(set) var entries: [FollowEntry]
    /// Bioguide IDs of your own reps you hid. They can't be unfollowed — they are your district —
    /// only hidden from the tab, the feed's "Your members" and the widgets' default.
    public private(set) var hiddenReps: [String]
    /// "How they voted" choices you changed, by Bioguide ID. Absent means the default: on for your
    /// reps, off for members you follow (round 9, section C). Read by `AlertSync` (Alerts module).
    public private(set) var alerts: [String: Bool]
    /// The same for bills you follow, by bill id: "A vote on H.R. 1013, which you follow." Absent
    /// means off, as for a member you follow. Absent in records from before v0.2.30.
    public private(set) var billAlerts: [String: Bool]
    /// "A vote opened": alert, and start a Live Activity, when a vote involving your members or bills
    /// opens. Off by default (round 9, section C).
    public private(set) var voteOpened: Bool

    public init(
        entries: [FollowEntry] = [], hiddenReps: [String] = [], alerts: [String: Bool] = [:],
        billAlerts: [String: Bool] = [:], voteOpened: Bool = false
    ) {
        self.entries = []
        self.hiddenReps = []
        self.alerts = alerts
        self.billAlerts = billAlerts
        self.voteOpened = voteOpened
        for entry in entries where !contains(entry.kind, entry.id) { self.entries.append(entry) }
        for id in hiddenReps where !self.hiddenReps.contains(id) { self.hiddenReps.append(id) }
    }

    public static let empty = FollowState()

    // Every field is optional on the way in, so a record from an older build (or one a later build
    // added fields to) still opens; duplicates a hand edit or a bug could leave are dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Element by element, so one entry this build cannot read (a later build's kind, a bad
        // write) is dropped alone rather than failing the record and wiping every follow.
        let entries = (try? container.decodeIfPresent([Lossy<FollowEntry>].self, forKey: .entries)) ?? []
        self.init(
            entries: entries.compactMap(\.value),
            hiddenReps: (try? container.decodeIfPresent([String].self, forKey: .hiddenReps)) ?? [],
            alerts: (try? container.decodeIfPresent([String: Bool].self, forKey: .alerts)) ?? [:],
            billAlerts: (try? container.decodeIfPresent([String: Bool].self, forKey: .billAlerts)) ?? [:],
            voteOpened: (try? container.decodeIfPresent(Bool.self, forKey: .voteOpened)) ?? false
        )
    }

    // MARK: Any kind

    public func contains(_ kind: FollowKind, _ id: String) -> Bool {
        entries.contains { $0.kind == kind && $0.id == id }
    }

    /// The entries of one kind, in display order.
    public func entries(_ kind: FollowKind) -> [FollowEntry] {
        entries.filter { $0.kind == kind }
    }

    /// Follows something, newest first. Already followed: stays where it is, and its saved record is
    /// refreshed (a member can change party or seat; a bill moves).
    public mutating func follow(
        _ kind: FollowKind, _ id: String, member: Member? = nil, bill: BillListItem? = nil, at date: Date = Date()
    ) {
        if let index = entries.firstIndex(where: { $0.kind == kind && $0.id == id }) {
            if let member { entries[index].member = member }
            if let bill { entries[index].bill = bill }
            return
        }
        entries.insert(FollowEntry(kind: kind, id: id, followedAt: date, member: member, bill: bill), at: 0)
    }

    public mutating func unfollow(_ kind: FollowKind, _ id: String) {
        entries.removeAll { $0.kind == kind && $0.id == id }
        if kind == .member { alerts[id] = nil }
        if kind == .bill { billAlerts[id] = nil }
    }

    /// Moves within one kind's list, with `List`'s `onMove` arguments; other kinds keep their places.
    public mutating func move(_ kind: FollowKind, fromOffsets source: IndexSet, toOffset destination: Int) {
        var mine = entries(kind)
        let moved = source.sorted().map { mine[$0] }
        for index in source.sorted(by: >) { mine.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        mine.insert(contentsOf: moved, at: max(0, min(insertAt, mine.count)))
        var next = mine.makeIterator()
        entries = entries.map { $0.kind == kind ? next.next()! : $0 }
    }

    // MARK: Members

    /// Followed members, in your order. Only entries that carry a record; one without (a later
    /// build's hand-off, a bad write) cannot be named, so it is not shown.
    public var followedMembers: [Member] { entries(.member).compactMap(\.member) }

    public func isFollowing(member id: String) -> Bool { contains(.member, id) }

    public mutating func follow(member: Member, at date: Date = Date()) {
        follow(.member, member.bioguideId, member: member, at: date)
    }

    public mutating func unfollow(member id: String) { unfollow(.member, id) }

    public mutating func moveMembers(fromOffsets source: IndexSet, toOffset destination: Int) {
        move(.member, fromOffsets: source, toOffset: destination)
    }

    /// Moves among `shown` — the member ids on screen, which may leave some out (a rep's stale follow
    /// entry) — with `List.onMove`'s arguments. Members not shown, and other kinds, keep their places.
    public mutating func moveMembers(_ shown: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = shown
        let moved = source.sorted().map { order[$0] }
        for index in source.sorted(by: >) { order.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        order.insert(contentsOf: moved, at: max(0, min(insertAt, order.count)))
        let onScreen = Set(shown)
        let before = entries
        var next = order.makeIterator()
        entries = before.map { entry in
            guard entry.kind == .member, onScreen.contains(entry.id), let id = next.next(),
                  let replacement = before.first(where: { $0.kind == .member && $0.id == id })
            else { return entry }
            return replacement
        }
    }

    // MARK: Bills

    /// Followed bills' saved rows, in your order. As for members, an entry without a record (a hand
    /// edit, a bad write) cannot be named, so it is not shown.
    public var followedBills: [BillListItem] { entries(.bill).compactMap(\.bill) }

    /// Every followed bill's id, with or without a saved row: what the feed fetches.
    public var followedBillIds: [String] { entries(.bill).map(\.id) }

    public func isFollowing(bill id: String) -> Bool { contains(.bill, id) }

    public mutating func follow(bill: BillListItem, at date: Date = Date()) {
        follow(.bill, bill.id, bill: bill, at: date)
    }

    public mutating func unfollow(bill id: String) { unfollow(.bill, id) }

    /// A fresher row for a bill you follow; a bill you don't is left alone (no follow by side effect).
    public mutating func refresh(bill: BillListItem) {
        guard let index = entries.firstIndex(where: { $0.kind == .bill && $0.id == bill.id }) else { return }
        entries[index].bill = bill
    }

    // MARK: Topics

    /// Followed topics' names, in your order.
    public var followedTopics: [String] { entries(.topic).map(\.id) }

    public func isFollowing(topic name: String) -> Bool { contains(.topic, name) }

    public mutating func follow(topic name: String, at date: Date = Date()) { follow(.topic, name, at: date) }

    public mutating func unfollow(topic name: String) { unfollow(.topic, name) }

    // MARK: Your reps

    public func isHidden(rep id: String) -> Bool { hiddenReps.contains(id) }

    public mutating func setHidden(rep id: String, _ hidden: Bool) {
        hiddenReps.removeAll { $0 == id }
        if hidden { hiddenReps.append(id) }
    }

    /// After "Change address": the old reps' hidden flags and alert choices would name the old
    /// district, so they go — unless you also follow that member, whose choice is then yours.
    public mutating func forgetReps(_ ids: [String]) {
        hiddenReps.removeAll { ids.contains($0) }
        for id in ids where !isFollowing(member: id) { alerts[id] = nil }
    }

    /// Your reps (minus any you hid) then everyone you follow, without repeats: who "your members"
    /// means in the feed, on the vote and bill screens, and in the widgets.
    ///
    /// One rule everywhere: a rep is a rep, never also a followed member. A follow entry for one of
    /// your reps (you followed them before finding your district) is left out here, so hiding that
    /// rep hides them — hidden wins. `adoptReps` removes such entries when the district is found.
    public func yourMembers(reps: [Member]) -> [Member] {
        var seen = Set<String>()
        return (visibleReps(reps) + followed(excludingReps: reps)).filter { seen.insert($0.bioguideId).inserted }
    }

    /// Followed members who are not your reps, in your order: the Following group on the tab.
    public func followed(excludingReps reps: [Member]) -> [Member] {
        let repIds = Set(reps.map(\.bioguideId))
        return followedMembers.filter { !repIds.contains($0.bioguideId) }
    }

    /// Your district was just found: anyone you followed who turns out to be one of its members is a
    /// rep now (pinned, hideable), so their follow entry goes. Their alert choice, if any, stays.
    public mutating func adoptReps(_ ids: [String]) {
        entries.removeAll { $0.kind == .member && ids.contains($0.id) }
    }

    public func visibleReps(_ reps: [Member]) -> [Member] {
        reps.filter { !isHidden(rep: $0.bioguideId) }
    }

    // MARK: Alerts (the Alerts screen; sent to the API by `AlertSync`)

    /// Whether this member's votes should alert you: your choice if you made one, else on for your
    /// own reps and off for members you follow.
    public func alertsOn(member id: String, isRep: Bool) -> Bool { alerts[id] ?? isRep }

    public mutating func setAlerts(member id: String, _ on: Bool) { alerts[id] = on }

    /// Whether a vote on this bill should alert you: your choice, else off.
    public func alertsOn(bill id: String) -> Bool { billAlerts[id] ?? false }

    public mutating func setAlerts(bill id: String, _ on: Bool) { billAlerts[id] = on }

    public mutating func setVoteOpened(_ on: Bool) { voteOpened = on }

    /// Anything at all would alert: a "How they voted" switch on for one of `members` (your members,
    /// reps first) or a followed bill, or "A vote opened". What decides whether the phone registers.
    public func anyAlertOn(members: [Member], reps: [Member]) -> Bool {
        let repIds = Set(reps.map(\.bioguideId))
        return voteOpened
            || members.contains { alertsOn(member: $0.bioguideId, isRep: repIds.contains($0.bioguideId)) }
            || followedBillIds.contains { alertsOn(bill: $0) }
    }
}

/// One array element decoded on its own: nil, rather than a thrown error, when it can't be read.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Where `FollowState` is kept between launches.
public protocol FollowStore: Sendable {
    func load() -> FollowState
    func save(_ state: FollowState)
}

/// `UserDefaults` JSON, in the App Group suite beside the delegation so the widget can read it.
/// `@unchecked Sendable` for the reason ``UserDefaultsDelegationStore`` gives.
public struct UserDefaultsFollowStore: FollowStore, @unchecked Sendable {
    static let key = "floor.follows.v1"
    private let defaults: UserDefaults
    /// The app's own defaults, where a build without a working App Group kept the record. Dropped
    /// when the group is saved to, as the delegation store does with its legacy copy.
    private let legacy: UserDefaults?

    public init(defaults: UserDefaults) {
        self.init(defaults: defaults, legacy: nil)
    }

    private init(defaults: UserDefaults, legacy: UserDefaults?) {
        self.defaults = defaults
        self.legacy = legacy.flatMap { $0 === defaults ? nil : $0 }
    }

    /// The App Group's suite, or — in a build without the group, like the delegation store — the
    /// app's own defaults, so following still works and only the widget can't see it.
    ///
    /// The rules are the delegation store's (`UserDefaultsDelegationStore.shared`): a record in the
    /// app's own defaults (kept there while the group did not work) is copied into an empty group;
    /// a record already in the group wins; the legacy copy is kept until the next save, so a group
    /// that turns out not to work loses nothing; loading never deletes anything.
    public static func shared(
        group: UserDefaults? = UserDefaultsDelegationStore.groupDefaults(),
        fallback: UserDefaults = .standard
    ) -> UserDefaultsFollowStore {
        guard let group else { return UserDefaultsFollowStore(defaults: fallback) }
        migrate(from: fallback, to: group)
        return UserDefaultsFollowStore(defaults: group, legacy: fallback)
    }

    /// Copies the record from `legacy` into `group` when the group has none; says whether it did.
    @discardableResult
    public static func migrate(from legacy: UserDefaults, to group: UserDefaults) -> Bool {
        guard legacy !== group, let old = legacy.data(forKey: key), group.data(forKey: key) == nil else {
            return false
        }
        group.set(old, forKey: key)
        return group.data(forKey: key) != nil
    }

    /// An unreadable record reads as following nobody, rather than failing to launch.
    public func load() -> FollowState {
        guard let data = defaults.data(forKey: Self.key) else { return .empty }
        return (try? JSONDecoder().decode(FollowState.self, from: data)) ?? .empty
    }

    /// Saves to the group. The legacy copy is stale from here on, so it goes.
    public func save(_ state: FollowState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
        legacy?.removeObject(forKey: Self.key)
    }
}

/// For previews and tests.
public final class InMemoryFollowStore: FollowStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FollowState

    public init(_ initial: FollowState = .empty) {
        stored = initial
    }

    public func load() -> FollowState {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func save(_ state: FollowState) {
        lock.lock()
        defer { lock.unlock() }
        stored = state
    }
}

/// The follow list as the screens see it: the state, saved on every change.
@MainActor
@Observable
public final class Follows {
    public private(set) var state: FollowState
    @ObservationIgnored private let store: any FollowStore
    /// Called after each saved change; the app reloads the widgets here.
    @ObservationIgnored private let onChange: @MainActor () -> Void

    public init(store: any FollowStore, onChange: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onChange = onChange
        state = store.load()
    }

    public func update(_ change: (inout FollowState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        store.save(next)
        onChange()
    }

    public func isFollowing(_ member: Member) -> Bool { state.isFollowing(member: member.bioguideId) }

    /// After onboarding finds a district: see ``FollowState/adoptReps(_:)``.
    public func adopt(_ delegation: Delegation) {
        update { $0.adoptReps(delegation.memberIds) }
    }

    public func isFollowing(bill id: String) -> Bool { state.isFollowing(bill: id) }

    public func isFollowing(topic name: String) -> Bool { state.isFollowing(topic: name) }

    /// A bill's fresh record: if you follow it, its saved row becomes this (keeping a stage or label
    /// the record lacks); if not, nothing changes.
    public func refresh(record bill: Bill) {
        update { state in
            let saved = state.entries(.bill).first { $0.id == bill.id }?.bill
            state.refresh(bill: BillListItem(bill: bill, keeping: saved))
        }
    }

    /// Follow the bill if not followed, else unfollow it.
    public func toggle(bill: BillListItem) {
        update { state in
            if state.isFollowing(bill: bill.id) { state.unfollow(bill: bill.id) } else { state.follow(bill: bill) }
        }
    }

    /// Follow the topic if not followed, else unfollow it.
    public func toggle(topic name: String) {
        update { state in
            if state.isFollowing(topic: name) { state.unfollow(topic: name) } else { state.follow(topic: name) }
        }
    }

    /// Follow if not followed, else unfollow.
    public func toggle(_ member: Member) {
        update { state in
            if state.isFollowing(member: member.bioguideId) {
                state.unfollow(member: member.bioguideId)
            } else {
                state.follow(member: member)
            }
        }
    }
}
