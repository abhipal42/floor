import Foundation
import Models
import Onboarding
import Testing
@testable import Home

/// The Week tab's grouping and order (round 11, section A), on the House's real list for the week of
/// Nov 16, 2026 (`schedule-2026-11-16.json`): 2 bills under a rule, 13 under suspension.
@Suite("Week")
struct WeekTests {
    private func schedule(_ name: String = "schedule-2026-11-16") throws -> Schedule {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        return try JSONDecoder().decode(Schedule.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")))
    }

    private func item(_ schedule: Schedule, _ id: String) throws -> ScheduleItem {
        try #require(schedule.house.items.first { $0.billId == id })
    }

    @Test func groupsInTheHousesOrderWithTheHousesOrderInside() throws {
        let week = try schedule()
        let groups = WeekSort.groups(week.house.items, state: FollowState())
        #expect(groups.map(\.category) == [.rule, .suspension])
        #expect(groups.map(\.count) == [2, 13])
        #expect(groups[0].title == "Debated under a rule")
        #expect(groups[1].title == "Fast track, needs ⅔")
        // Nothing followed: the source's own order.
        #expect(groups[1].rows.map(\.item.billId) == week.house.items.filter { $0.category == .suspension }.map(\.billId))
        #expect(groups.flatMap(\.rows).allSatisfy { $0.followed == nil })
    }

    @Test func whatYouFollowSortsFirst() throws {
        let week = try schedule()
        var state = FollowState()
        // A bill directly, and a topic that takes in H.R. 5490 (International Affairs).
        state.follow(.bill, "119-hr-9640")
        state.follow(topic: "International Affairs")
        let suspension = try #require(WeekSort.groups(week.house.items, state: state).first { $0.category == .suspension })
        #expect(suspension.rows.prefix(2).map(\.item.billId) == ["119-hr-9640", "119-hr-5490"])
        #expect(suspension.rows[0].followed == .bill)
        #expect(suspension.rows[1].followed == .topic("International Affairs"))
        #expect(suspension.rows.dropFirst(2).allSatisfy { $0.followed == nil })
        // The rest keep the House's order.
        let rest = week.house.items.filter { $0.category == .suspension && !["119-hr-9640", "119-hr-5490"].contains($0.billId) }
        #expect(suspension.rows.dropFirst(2).map(\.item.billId) == rest.map(\.billId))
        // Every followed row shows before "+ N more".
        #expect(WeekSort.visibleCount(suspension) == 5)
    }

    @Test func aPulledItemGoesLastAndIsNotCounted() throws {
        let week = try schedule()
        var items = week.house.items
        let first = try #require(items.firstIndex { $0.category == .suspension })
        items[first].removedAt = "2026-11-15T12:00:00.000Z"
        var state = FollowState()
        state.follow(.bill, items[first].billId!)
        let suspension = try #require(WeekSort.groups(items, state: state).first { $0.category == .suspension })
        #expect(suspension.rows.last?.item.billId == items[first].billId)
        #expect(suspension.rows.last?.pulled == true)
        #expect(suspension.count == 12)
    }

    @Test func anUnpublishedWeekIsNullNotRecess() throws {
        let later = try schedule("schedule-2026-11-23")
        #expect(later.house.inSession == nil)
        #expect(later.house.items.isEmpty)
        #expect(later.senate == nil)
        #expect(later.senateReason?.isEmpty == false)
        #expect(WeekSort.groups(later.house.items, state: FollowState()).isEmpty)
    }

    @Test func weekRangeAndMonday() throws {
        let week = try schedule()
        #expect(week.weekRange == "Nov 16–20")
        #expect(week.weekOf == "November 16")
        // Saturday Nov 14, 2026 in Washington is in the week of Monday Nov 9; next week is Nov 16.
        let saturday = try #require(Formats.instant("2026-11-14T17:00:00.000Z"))
        #expect(Schedule.monday(of: saturday) == "2026-11-09")
        #expect(Schedule.monday(of: saturday, offsetWeeks: 1) == "2026-11-16")
        // Sunday night in Washington is still that week, though it is Monday in UTC.
        let sundayNight = try #require(Formats.instant("2026-11-16T03:00:00.000Z"))
        #expect(Schedule.monday(of: sundayNight) == "2026-11-09")
        let monday = try #require(Formats.instant("2026-11-16T14:00:00.000Z"))
        #expect(Schedule.monday(of: monday) == "2026-11-16")
    }

    @Test func theSenateProgramLinksTheMeasuresItNames() throws {
        let week = try schedule()
        let senate = try #require(week.senate)
        let program = try #require(senate.meetings.first?.program)
        let linked = WeekSenateView.linked(program, items: senate.items)
        let links = linked.runs.compactMap(\.link)
        #expect(links == [FloorLink.bill(id: "119-hr-2347").url])
        // Verbatim: the text itself is unchanged.
        #expect(String(linked.characters) == program)
        let meeting = try #require(senate.meetings.first)
        // The time style puts a narrow no-break space before PM.
        let convenes = WeekSenateView.convenes(meeting).replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(convenes == "Convenes Monday 3:00 PM ET")
    }
}
