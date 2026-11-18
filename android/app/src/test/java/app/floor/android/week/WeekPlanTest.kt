package app.floor.android.week

import app.floor.android.Fixtures
import app.floor.android.model.Chamber
import app.floor.android.model.RecentVotes
import app.floor.android.model.Schedule
import app.floor.android.model.TopicGroup
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
import java.time.ZoneId
import java.util.Locale

/**
 * The Week tab's headliners, fast track and Senate next, from the live schedule of the week of
 * Nov 16 (`schedule-three-2026-11-16`) and the latest finals (`votes-three`). Robolectric, because
 * the chips' days go through the platform's ICU.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class WeekPlanTest {
    private val schedule = Fixtures.decode("schedule-three-2026-11-16", Schedule.serializer())
    private val votes = Fixtures.decode("votes-three", RecentVotes.serializer()).votes
    private val eastern = ZoneId.of("America/New_York")
    private val none = FollowState()

    private fun headliners(follows: FollowState = none) = WeekPlan.headliners(schedule, votes, follows, eastern, Locale.US)

    @Test
    fun theSummarySaysOnlyWhatTheScheduleDoes() {
        // 16 House items and H.R. 2347, named in both Senate programs, counted once.
        assertEquals("Both chambers in · 17 measures listed", WeekPlan.summary(schedule))
    }

    @Test
    fun aLegislativeVehicleHeadlinesWhatItCarries() {
        val senate = headliners().first()
        assertEquals(Chamber.SENATE, senate.chamber)
        assertEquals("H.R. 2347", senate.item.label)
        assertEquals("Bipartisan American Affordability and Jobs Act", senate.headline)
        assertEquals("Riding on Survivor Justice Tax Prevention Act.", senate.context)
        assertEquals("SENATE · IN DEBATE", senate.label)
        // Its two latest real votes, both before this week, so by date; newest first.
        assertEquals(listOf("Nov 10 ✓ motion to proceed 62–21", "Nov 9 ✓ cloture to proceed 73–25"), senate.chips)
    }

    @Test
    fun withoutAVehicleTheProgramSentenceIsTheContext() {
        val program = schedule.senate!!.meetings.first().program!!
        assertNull(WeekPlan.vehicle(program, "H.R. 9999"))
        assertEquals("Bipartisan American Affordability and Jobs Act", WeekPlan.vehicle(program, "H.R. 2347"))
        val sentences = WeekPlan.sentences(program)
        assertEquals(2, sentences.size)
        assertTrue(sentences[1].startsWith("Following disposition of the nomination"))
    }

    @Test
    fun houseRuleBillsNameTheirRuleAndWhatComesWithThem() {
        val house = headliners().filter { it.chamber == Chamber.HOUSE }
        assertEquals(listOf("H.R. 3495", "H.R. 5267"), house.map { it.item.label })
        assertEquals("Up under a rule (H.Res. 1665), with American Franchise Act.", house[0].context)
        assertEquals("Up under a rule (H.Res. 1665), with Direct Seller and Real Estate Agent Harmonization Act.", house[1].context)
        assertEquals("HOUSE · FULL DEBATE", house[1].label)
        assertTrue(house.all { it.chips.isEmpty() })
    }

    @Test
    fun aFollowedHeadlinerKeepsItsFollow() {
        val labor = FollowState().follow(FollowKind.TOPIC, "Labor and Employment")
        assertTrue(headliners(labor).filter { it.chamber == Chamber.HOUSE }.all { it.row.followed != null })
        assertTrue(headliners(labor).first().row.followed == null)
    }

    @Test
    fun fastTrackGroupsTheSuspensionsByTopicLargestFirst() {
        val tiles = WeekPlan.fastTrack(schedule.house.items, none)
        assertEquals(
            listOf(TopicGroup.LAND to 6, TopicGroup.RIGHTS to 4, TopicGroup.DEFENSE to 1, TopicGroup.MONEY to 1, TopicGroup.GOV to 1),
            tiles.map { it.topic to it.count },
        )
        assertEquals(13, tiles.sumOf { it.count })
        assertEquals(listOf("H. Res. 1665"), WeekPlan.alsoListed(schedule.house.items, none).map { it.item.label })
    }

    @Test
    fun senateNextIsTodaysMeetingOrTheNextOne() {
        val senate = schedule.senate!!
        val monday = WeekPlan.senateNext(senate, Instant.parse("2026-11-16T12:00:00Z"))!!
        assertEquals("2026-11-16", monday.date)
        val tuesday = Instant.parse("2026-11-17T15:00:00Z")
        val next = WeekPlan.senateNext(senate, tuesday)!!
        assertEquals("2026-11-17", next.date)
        assertEquals("TODAY", WeekPlan.meetingDay(next, tuesday))
        assertEquals("10:00" to "AM", WeekPlan.convenes(next))
        assertEquals("TUESDAY", WeekPlan.meetingDay(next, Instant.parse("2026-11-16T12:00:00Z")))
        // After the week's last meeting, the last one posted.
        assertEquals("2026-11-17", WeekPlan.senateNext(senate, Instant.parse("2026-11-19T12:00:00Z"))!!.date)
    }
}
