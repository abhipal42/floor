package app.floor.android.week

import app.floor.android.Fixtures
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.store.FollowKind
import app.floor.android.store.FollowState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant

/**
 * iOS `WeekTests`: the Week tab's grouping and order on the House's real list for the week of
 * Nov 16, 2026 (`schedule-2026-11-16.json`): 2 bills under a rule, 13 under suspension.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class WeekTest {
    private fun schedule(name: String = "schedule-2026-11-16") = Fixtures.decode(name, Schedule.serializer())

    @Test
    fun groupsInTheHousesOrderWithTheHousesOrderInside() {
        val week = schedule()
        val groups = WeekSort.groups(week.house.items, FollowState())
        assertEquals(listOf(ScheduleCategory.RULE, ScheduleCategory.SUSPENSION), groups.map { it.category })
        assertEquals(listOf(2, 13), groups.map { it.count })
        assertEquals("Debated under a rule", groups[0].title)
        assertEquals("Fast track, needs ⅔", groups[1].title)
        // Nothing followed: the source's own order.
        assertEquals(week.house.items.filter { it.category == ScheduleCategory.SUSPENSION }.map { it.billId }, groups[1].rows.map { it.item.billId })
        assertTrue(groups.flatMap { it.rows }.all { it.followed == null })
    }

    @Test
    fun whatYouFollowSortsFirst() {
        val week = schedule()
        // A bill directly, and a topic that takes in H.R. 5490 (International Affairs).
        val state = FollowState().follow(FollowKind.BILL, "119-hr-9640").follow(FollowKind.TOPIC, "International Affairs")
        val suspension = WeekSort.groups(week.house.items, state).first { it.category == ScheduleCategory.SUSPENSION }
        assertEquals(listOf("119-hr-9640", "119-hr-5490"), suspension.rows.take(2).map { it.item.billId })
        assertEquals(WeekSort.Followed.Bill, suspension.rows[0].followed)
        assertEquals(WeekSort.Followed.Topic("International Affairs"), suspension.rows[1].followed)
        assertTrue(suspension.rows.drop(2).all { it.followed == null })
        // The rest keep the House's order.
        val rest = week.house.items.filter { it.category == ScheduleCategory.SUSPENSION && it.billId !in setOf("119-hr-9640", "119-hr-5490") }
        assertEquals(rest.map { it.billId }, suspension.rows.drop(2).map { it.item.billId })
        // Every followed row shows before "+ N more".
        assertEquals(5, WeekSort.visibleCount(suspension))
        assertEquals("FOLLOWING · INTERNATIONAL", WeekSort.tag(suspension.rows[1].followed))
    }

    @Test
    fun aPulledItemGoesLastAndIsNotCounted() {
        val week = schedule()
        val items = week.house.items.toMutableList()
        val first = items.indexOfFirst { it.category == ScheduleCategory.SUSPENSION }
        items[first] = items[first].copy(removedAt = "2026-11-15T12:00:00.000Z")
        val state = FollowState().follow(FollowKind.BILL, items[first].billId!!)
        val suspension = WeekSort.groups(items, state).first { it.category == ScheduleCategory.SUSPENSION }
        assertEquals(items[first].billId, suspension.rows.last().item.billId)
        assertTrue(suspension.rows.last().pulled)
        assertEquals(12, suspension.count)
    }

    @Test
    fun anUnpublishedWeekIsNullNotRecess() {
        val later = schedule("schedule-2026-11-23")
        assertNull(later.house.inSession)
        assertTrue(later.house.items.isEmpty())
        assertNull(later.senate)
        assertTrue(later.senateReason?.isNotEmpty() == true)
        assertTrue(WeekSort.groups(later.house.items, FollowState()).isEmpty())
    }

    @Test
    fun weekRangeAndMonday() {
        val week = schedule()
        assertEquals("Nov 16–20", week.weekRange)
        assertEquals("Nov 30 – Dec 4", Schedule.weekRange("2026-11-30"))
        // Saturday Nov 14, 2026 in Washington is in the week of Monday Nov 9; next week is Nov 16.
        val saturday = Instant.parse("2026-11-14T17:00:00.000Z")
        assertEquals("2026-11-09", Schedule.monday(saturday))
        assertEquals("2026-11-16", Schedule.monday(saturday, offsetWeeks = 1))
        // Sunday night in Washington is still that week, though it is Monday in UTC.
        assertEquals("2026-11-09", Schedule.monday(Instant.parse("2026-11-16T03:00:00.000Z")))
        assertEquals("2026-11-16", Schedule.monday(Instant.parse("2026-11-16T14:00:00.000Z")))
    }

    @Test
    fun theSenateProgramLinksTheMeasuresItNames() {
        val senate = schedule().senate!!
        val program = senate.meetings.first().program!!
        val links = WeekSort.links(program, senate.items)
        assertEquals(listOf("119-hr-2347"), links.map { it.billId })
        assertEquals("H.R. 2347", program.substring(links[0].start, links[0].end))
        assertEquals("Convenes Monday 3:00 PM ET", WeekSort.convenes(senate.meetings.first()))
        assertEquals("Source: senate.gov and the Congressional Record's Daily Digest (172/171)", WeekSort.senateSource(senate))
    }

    @Test
    fun aRowSaysItsLatestStep() {
        val item = schedule().house.items.first()
        assertEquals("Placed on the Union Calendar, Calendar No. 752 · Oct 29", item.latestLine)
        assertEquals("Source: House Majority Leader, updated Nov 13", WeekSort.sourceLine(schedule()))
    }
}
