import Foundation
import Models
import Onboarding

/// Everything the two home-screen widgets draw, built from your members' recent votes.
///
/// Small shows ``latestFinal``; medium shows ``rows``, one per member. It is `Codable` so the last
/// good copy can be kept in the App Group and shown when a refresh fails. It holds the district and
/// the members — what the delegation store already holds — and their public votes; never an
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

    /// The newest final vote any of your members took part in, and one of them on it.
    public struct Final: Codable, Sendable, Hashable {
        public var vote: Vote
        public var measure: MeasureSummary?
        /// The member whose chip the small widget shows: your representative on a House vote, the
        /// first senator by surname on a Senate one.
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

        public var id: String { member.bioguideId }

        public init(member: Member, latest: MemberVote?) {
            self.member = member
            self.latest = latest
        }
    }

    /// The district without its county: the widget needs the seat (`TX-37`), not where in it you
    /// are, so `countyFips` is dropped before anything is saved.
    public var district: District
    public var members: [Member]
    public var latestFinal: Final?
    public var rows: [Row]
    /// When the votes were fetched.
    public var fetchedAt: Date

    public init(district: District, members: [Member], latestFinal: Final?, rows: [Row], fetchedAt: Date) {
        self.district = district
        self.members = members
        self.latestFinal = latestFinal
        self.rows = rows
        self.fetchedAt = fetchedAt
    }

    /// Builds the snapshot from each member's record, newest first as the API returns it.
    ///
    /// - Parameter records: Bioguide ID → that member's recent votes.
    public static func make(
        delegation: Delegation, records: [String: [MemberVote]], fetchedAt: Date
    ) -> WidgetSnapshot {
        let members = ordered(delegation.members)
        let rows = members.map { member in
            Row(member: member, latest: records[member.bioguideId]?.first)
        }

        var latest: Final?
        for member in members {
            for row in records[member.bioguideId] ?? [] where row.vote.state == .final {
                let candidate = Final(
                    vote: row.vote, measure: row.measure,
                    call: Call(member: member, position: row.position, choice: row.choice)
                )
                // Strictly newer only, so on a vote two senators share, the first in order keeps it.
                if latest.map({ isNewer(row.vote, than: $0.vote) }) ?? true { latest = candidate }
            }
        }

        return WidgetSnapshot(
            district: seatOnly(delegation.district), members: members, latestFinal: latest, rows: rows,
            fetchedAt: fetchedAt
        )
    }

    /// True when this snapshot was built for exactly this delegation, so a saved copy from before
    /// "Change address" is never shown for the new one.
    public func belongs(to delegation: Delegation) -> Bool {
        district == Self.seatOnly(delegation.district)
            && Set(members.map(\.bioguideId)) == Set(delegation.memberIds)
    }

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
