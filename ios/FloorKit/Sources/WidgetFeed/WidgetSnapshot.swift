import Foundation
import Models
import Onboarding

/// Everything the two home-screen widgets draw, built from your members' recent votes.
///
/// Small shows ``latestFinal``; medium shows up to three of ``rows`` (``mediumRows(chosen:)``). It
/// covers every one of your members — your reps and everyone you follow. It is `Codable` so the last
/// good copy can be kept in the App Group and shown when a refresh fails. It holds the district,
/// the members — what the delegation and follow stores already hold — and their public votes; never an
/// address or a coordinate, which the app does not keep either.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    /// One member's position on one vote.
    public struct Call: Codable, Sendable, Hashable {
        public var member: Member
        public var position: Position
        /// The candidate they named, on a Speaker election.
        public var choice: String?

        public init(member: Member, position: Position, choice: String?) {
            self.member = member
            self.position = position
            self.choice = choice
        }
    }

    /// The newest final vote any of your members — reps or followed — took part in, and one of them on it.
    public struct Final: Codable, Sendable, Hashable {
        public var vote: Vote
        public var measure: MeasureSummary?
        /// The member whose chip the small widget shows: your representative on a House vote, the
        /// first senator by surname on a Senate one, else the first member you follow who voted.
        public var call: Call

        public init(vote: Vote, measure: MeasureSummary?, call: Call) {
            self.vote = vote
            self.measure = measure
            self.call = call
        }
    }

    /// One member and their most recent vote, or nil when they have none on record yet.
    public struct Row: Codable, Sendable, Hashable, Identifiable {
        public var member: Member
        public var latest: MemberVote?
        /// Their record did not load this time, so `latest` says nothing — the row reads "Couldn't
        /// load", not "No recorded votes yet".
        public var unavailable: Bool

        public var id: String { member.bioguideId }

        public init(member: Member, latest: MemberVote?, unavailable: Bool = false) {
            self.member = member
            self.latest = latest
            self.unavailable = unavailable
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            member = try container.decode(Member.self, forKey: .member)
            latest = try container.decodeIfPresent(MemberVote.self, forKey: .latest)
            unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        }
    }


    /// The district without its county: the widget needs the seat (`TX-37`), not where in it you
    /// are, so `countyFips` is dropped before anything is saved. nil when you skipped the district.
    public var district: District?
    /// Every one of your members, your reps first: one row each.
    public var members: [Member]
    /// Which of `members` are your own reps (not hidden): the medium widget's default rows.
    public var repIds: [String]
    public var latestFinal: Final?
    public var rows: [Row]
    /// When the votes were fetched.
    public var fetchedAt: Date

    public init(
        district: District?, members: [Member], repIds: [String], latestFinal: Final?, rows: [Row], fetchedAt: Date
    ) {
        self.district = district
        self.members = members
        self.repIds = repIds
        self.latestFinal = latestFinal
        self.rows = rows
        self.fetchedAt = fetchedAt
    }

    /// Builds the snapshot from each member's record, newest first as the API returns it.
    ///
    /// - Parameter records: Bioguide ID → that member's recent votes.
    /// - Parameters:
    ///   - records: Bioguide ID → that member's recent votes; a member absent from it did not load.
    ///   - only: the members that were asked for (the medium widget fetches only the rows it draws);
    ///     nil for all of them.
    public static func make(
        members who: WidgetMembers, records: [String: [MemberVote]], fetchedAt: Date, only: [String]? = nil
    ) -> WidgetSnapshot {
        let members = who.all
        let asked = only.map(Set.init)
        let rows = members.filter { asked?.contains($0.bioguideId) ?? true }.map { member in
            Row(member: member, latest: records[member.bioguideId]?.first, unavailable: records[member.bioguideId] == nil)
        }

        var latest: Final?
        for member in members {
            for row in records[member.bioguideId] ?? [] where row.vote.state == .final {
                let candidate = Final(
                    vote: row.vote, measure: row.measure,
                    call: Call(member: member, position: row.position, choice: row.choice)
                )
                // Strictly newer only, so on a vote several members share, the first in order —
                // your rep, then your senators, then whoever you follow — keeps it.
                if latest.map({ isNewer(row.vote, than: $0.vote) }) ?? true { latest = candidate }
            }
        }

        return WidgetSnapshot(
            district: who.district, members: members, repIds: who.reps.map(\.bioguideId), latestFinal: latest,
            rows: rows, fetchedAt: fetchedAt
        )
    }

    /// Your district's members only, as before following existed.
    public static func make(
        delegation: Delegation, records: [String: [MemberVote]], fetchedAt: Date
    ) -> WidgetSnapshot {
        make(members: WidgetMembers(delegation: delegation), records: records, fetchedAt: fetchedAt)
    }

    /// True when this snapshot was built for exactly these members, so a saved copy from before
    /// "Change address", a follow or a hide is never shown for the new set.
    ///
    /// Compared as sets: reordering who you follow changes nothing a snapshot shows that a refresh
    /// would not redo anyway, and is no reason to throw a saved copy away.
    public func belongs(to who: WidgetMembers) -> Bool {
        district == who.district
            && Set(members.map(\.bioguideId)) == Set(who.all.map(\.bioguideId))
            && Set(repIds) == Set(who.reps.map(\.bioguideId))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        district = try container.decodeIfPresent(District.self, forKey: .district)
        members = try container.decode([Member].self, forKey: .members)
        // Absent in a snapshot saved before following: no reps known, so the medium widget's
        // default falls back to its first rows until the next refresh.
        repIds = try container.decodeIfPresent([String].self, forKey: .repIds) ?? []
        latestFinal = try container.decodeIfPresent(Final.self, forKey: .latestFinal)
        rows = try container.decode([Row].self, forKey: .rows)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    }

    public func belongs(to delegation: Delegation) -> Bool {
        belongs(to: WidgetMembers(delegation: delegation))
    }

    /// The medium widget's rows: the members picked in its Edit menu, in that order, up to three;
    /// with none picked — or none of the picked still among your members — your reps, as the widget
    /// was before following; with no reps either, the first three you follow.
    public func mediumRows(chosen: [String]?) -> [Row] {
        let byId = Dictionary(rows.map { ($0.member.bioguideId, $0) }, uniquingKeysWith: { a, _ in a })
        return Self.mediumPick(ids: rows.map(\.member.bioguideId), repIds: repIds, chosen: chosen).compactMap { byId[$0] }
    }

    /// The medium widget's rule, on ids, so the fetch and the drawing pick alike: the chosen ids
    /// still among `ids`, in order, without repeats, up to three; else the reps; else the first three.
    public static func mediumPick(ids: [String], repIds: [String], chosen: [String]?) -> [String] {
        let present = Set(ids)
        var seen = Set<String>()
        let picked = (chosen ?? []).filter { present.contains($0) && seen.insert($0).inserted }
        if !picked.isEmpty { return Array(picked.prefix(mediumCount)) }
        let reps = repIds.filter(present.contains)
        return Array((reps.isEmpty ? ids : reps).prefix(mediumCount))
    }

    /// Rows a medium widget has room for.
    public static let mediumCount = 3

    static func seatOnly(_ district: District) -> District {
        var seat = district
        seat.countyFips = nil
        return seat
    }

    /// Your representative (or delegate) first, then senators by surname — the order the app's feed
    /// and the mock use.
    static func ordered(_ members: [Member]) -> [Member] {
        members.sorted { lhs, rhs in
            (lhs.chamber == .house ? 0 : 1, lhs.lastName) < (rhs.chamber == .house ? 0 : 1, rhs.lastName)
        }
    }

    /// Newer by when it closed; a vote with no timestamp is never newer than one with. Equal times
    /// (the same roll call, seen in both senators' records) are not newer, so the first one kept wins.
    static func isNewer(_ a: Vote, than b: Vote) -> Bool {
        switch (a.occurredAtDate, b.occurredAtDate) {
        case let (l?, r?): l > r
        case (_?, nil): true
        case (nil, _): false
        }
    }
}

/// Who the widgets show, as the app left it in the App Group: your district's members (minus any
/// you hid) and everyone you follow.
public struct WidgetMembers: Sendable, Hashable {
    /// Seat only, never the county. nil with no district.
    public var district: District?
    /// Your reps, not hidden: representative first, then senators by surname.
    public var reps: [Member]
    /// Members you follow, in your order.
    public var followed: [Member]

    public init(delegation: Delegation?, follows: FollowState = .empty) {
        district = delegation.map { WidgetSnapshot.seatOnly($0.district) }
        reps = WidgetSnapshot.ordered(follows.visibleReps(delegation?.members ?? []))
        // A rep is a rep, also when followed: hidden wins (`FollowState.yourMembers`).
        followed = follows.followed(excludingReps: delegation?.members ?? [])
    }

    /// Reps then followed, without repeats: one row each.
    public var all: [Member] {
        var seen = Set<String>()
        return (reps + followed).filter { seen.insert($0.bioguideId).inserted }
    }

    public var isEmpty: Bool { all.isEmpty }

    /// The ids the medium widget draws for this pick: all it needs to fetch.
    public func mediumIds(chosen: [String]?) -> [String] {
        WidgetSnapshot.mediumPick(ids: all.map(\.bioguideId), repIds: reps.map(\.bioguideId), chosen: chosen)
    }

    /// What the app saved in this suite.
    public static func read(from group: UserDefaults) -> WidgetMembers {
        WidgetMembers(
            delegation: UserDefaultsDelegationStore(defaults: group).load(),
            follows: UserDefaultsFollowStore(defaults: group).load()
        )
    }
}
