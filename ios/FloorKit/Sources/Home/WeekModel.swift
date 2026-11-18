import APIClient
import Foundation
import Models
import Observation
import Onboarding

/// The Week tab (round 11, section A of <https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r>): what
/// the House has listed for a week, and when the Senate meets, from `GET /v1/schedule`.
@MainActor
@Observable
public final class WeekModel {
    public enum Phase: Equatable {
        case loading
        case loaded(Schedule)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var saved: SavedCopy?
    /// Weeks from this one: 0 is this week, 1 next week (the ingest stores both), -1 last week.
    public private(set) var offset = 0

    public let follows: Follows
    @ObservationIgnored private let api: FloorAPI
    @ObservationIgnored private let now: () -> Date
    private var generation = 0

    public init(api: FloorAPI, follows: Follows, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.follows = follows
        self.now = now
    }

    /// Today in Washington, `YYYY-MM-DD`: which Senate meeting is "today".
    public var today: String { WeekPlan.day(now()) }

    /// The Monday asked for, `YYYY-MM-DD`.
    public var week: String { Schedule.monday(of: now(), offsetWeeks: offset) }

    public var needsRefresh: Bool {
        if case .loaded = phase { return saved != nil }
        return true
    }

    public func show(offset: Int) async {
        guard offset != self.offset else { return }
        self.offset = offset
        phase = .loading
        await load()
    }

    public func load() async {
        generation += 1
        let mine = generation
        if case .loaded = phase {} else { saved = nil }
        let week = week
        do {
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { pass in
                let schedule = try await pass.api.schedule(week: week)
                guard mine == generation else { throw CancellationError() }
                phase = .loaded(schedule)
            }
        } catch is CancellationError {
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load the week.")
        }
    }

    public func groups(_ schedule: Schedule) -> [WeekSort.Group] {
        WeekSort.groups(schedule.house.items, state: follows.state)
    }
}

/// How the week's House list is grouped and ordered, apart from the view so it can be tested.
public enum WeekSort {
    /// Why an item has the gold edge.
    public enum Followed: Hashable, Sendable {
        case bill
        /// Through a followed topic, by its name.
        case topic(String)
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var item: ScheduleItem
        public var followed: Followed?
        /// Taken off the week's list; kept, dimmed, at the end of its group.
        public var pulled: Bool { item.removedAt != nil }
        public var id: String { "\(item.category.rawValue)|\(item.billId ?? item.label)" }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public var category: ScheduleCategory
        public var rows: [Row]
        public var id: ScheduleCategory { category }

        /// Items still on the list.
        public var count: Int { rows.filter { !$0.pulled }.count }

        /// `Debated under a rule`, `Fast track, needs ⅔`, `Other items`.
        public var title: String {
            switch category {
            case .rule: "Debated under a rule"
            case .suspension: "Fast track, needs ⅔"
            case .other: "Other items"
            }
        }
    }

    /// The House's groups in the House's order (rule, suspension, other), each led by what you
    /// follow — directly, or through a followed topic — then the House's own order, then anything
    /// pulled from the list. A group with no rows is left out.
    public static func groups(_ items: [ScheduleItem], state: FollowState) -> [Group] {
        let topics = Set(state.followedTopics)
        let rows = items.map { item -> Row in
            if let id = item.billId, state.isFollowing(bill: id) { return Row(item: item, followed: .bill) }
            if let area = item.policyArea.flatMap(Topic.canonical), topics.contains(area) {
                return Row(item: item, followed: .topic(area))
            }
            return Row(item: item, followed: nil)
        }
        return ScheduleCategory.allCases.compactMap { category in
            let mine = rows.enumerated().filter { $0.element.item.category == category }
            guard !mine.isEmpty else { return nil }
            let sorted = mine.sorted { a, b in
                let ka = (a.element.pulled ? 2 : (a.element.followed == nil ? 1 : 0), a.offset)
                let kb = (b.element.pulled ? 2 : (b.element.followed == nil ? 1 : 0), b.offset)
                return ka < kb
            }
            return Group(category: category, rows: sorted.map(\.element))
        }
    }

    /// How many rows a group shows before "+ N more": every followed one, and at least five.
    public static func visibleCount(_ group: Group) -> Int {
        max(5, group.rows.filter { $0.followed != nil }.count)
    }
}

public extension ScheduleItem {
    /// `Placed on the Union Calendar, Calendar No. 702 · Oct 29`: the latest step, as a row says it.
    var latestLine: String? {
        guard let latestAction else { return nil }
        let text = latestAction.text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return [text, Formats.monthDay(latestAction.on)].compactMap(\.self).joined(separator: " · ")
    }
}
