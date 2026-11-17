package app.floor.android.home

import app.floor.android.Fixtures
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberVotes
import app.floor.android.model.Position
import app.floor.android.model.RecentVotes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
 * The Finals feed as stories, from the votes recorded the day the v0.2.57 mock was locked
 * (`votes-stories`: Nov 11-16, 2026). Robolectric, because the dates go through the platform's ICU.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class StoriesTest {
    private val rows = Fixtures.decode("votes-stories", RecentVotes.serializer()).votes
    private val eastern = ZoneId.of("America/New_York")
    private val today = Instant.parse("2026-11-17T15:00:00Z")

    private val newYork: List<FeedItem>
        get() {
            val members = listOf("nadler", "schumer", "gillibrand").map { Fixtures.decode("member-detail-$it", MemberDetail.serializer()).member }
            val records = listOf("nadler", "schumer", "gillibrand").map { Fixtures.decode("member-votes-$it-stories", MemberVotes.serializer()).votes }
            return HomeState.annotate(rows, HomeState.merge(members.zip(records), members.map { it.bioguideId }))
        }

    private fun stories(items: List<FeedItem> = HomeState.annotate(rows, emptyList())) = Stories.group(items)

    private fun story(items: List<FeedItem> = HomeState.annotate(rows, emptyList()), id: String) = stories(items).first { it.id == id }

    @Test
    fun oneStoryPerMeasureNewestFirst() {
        assertEquals(
            listOf("senate-119-2-264", "119-pn-999-2", "119-pn-1181-7", "119-pn-1181-1", "119-hr-2102", "119-hr-1013"),
            stories().map { it.id },
        )
    }

    @Test
    fun aRuleJoinsTheBillItIsFor() {
        val hr2102 = story(id = "119-hr-2102")
        assertEquals(listOf("house-119-2-320", "house-119-2-322", "house-119-2-323"), hr2102.steps.map { it.vote.id })
        assertEquals("house-119-2-323", hr2102.main?.vote?.id)
        assertTrue(hr2102.isFull)
        assertEquals("119-hr-2102", hr2102.measure?.id)
    }

    @Test
    fun aRuleWhoseBillIsNotInTheFeedIsItsOwnMini() {
        val withoutBill = HomeState.annotate(rows.filter { it.measure?.id != "119-hr-2102" }, emptyList())
        val rule = stories(withoutBill).first { it.id == "119-hres-1247" }
        assertEquals(2, rule.steps.size)
        assertFalse(rule.isFull)
    }

    @Test
    fun onlyProceduralVotesOrNoMeasureMakeAMini() {
        assertFalse(story(id = "119-pn-1181-7").isFull)
        assertFalse(story(id = "senate-119-2-264").isFull)
        assertTrue(story(id = "119-pn-1181-1").isFull)
        assertTrue(story(id = "119-pn-999-2").isFull)
    }

    @Test
    fun weeksAreRelativeAndFullCardsComeFirst() {
        val sections = Stories.sections(stories(), today, eastern, Locale.US)
        assertEquals(listOf("This week", "Last week"), sections.map { it.title })
        assertEquals(listOf("119-pn-999-2"), sections[0].full.map { it.id })
        assertEquals(listOf("senate-119-2-264"), sections[0].minis.map { it.id })
        assertEquals(listOf("119-pn-1181-1", "119-hr-2102", "119-hr-1013"), sections[1].full.map { it.id })
        assertEquals(listOf("119-pn-1181-7"), sections[1].minis.map { it.id })
        assertEquals("Also last week", sections[1].alsoTitle)
    }

    @Test
    fun anOlderWeekIsNamedByItsFirstDay() {
        val later = Instant.parse("2026-12-01T15:00:00Z")
        assertEquals(listOf("Week of Nov 15", "Week of Nov 8"), Stories.sections(stories(), later, eastern, Locale.US).map { it.title })
        // A Monday-first locale starts the week on Nov 16, the day of the Domenico vote.
        assertEquals(listOf("Week of 16 Nov", "Week of 9 Nov"), Stories.sections(stories(), later, eastern, Locale.UK).map { it.title })
    }

    @Test
    fun datesAreInTheReadersZone() {
        val cloture = story(id = "senate-119-2-264").latest.vote
        assertEquals("Cloture · Nov 16", Stories.stepName(cloture, eastern, Locale.US))
        assertEquals("Cloture · Nov 17", Stories.stepName(cloture, ZoneId.of("Pacific/Kiritimati"), Locale.US))
    }

    @Test
    fun stepsAreNamedInPlainWords() {
        assertEquals(
            listOf("Discharge petition · Nov 11", "Rule for debate · Nov 12", "Passage · Nov 12"),
            story(id = "119-hr-2102").steps.map { Stories.stepName(it.vote, eastern, Locale.US) },
        )
        assertEquals(
            listOf("Cloture · Nov 12", "Confirmation · Nov 16"),
            story(id = "119-pn-999-2").steps.map { Stories.stepName(it.vote, eastern, Locale.US) },
        )
    }

    @Test
    fun theVerdictComesFromTheMainStep() {
        assertEquals("PASSED HOUSE", Stories.verdict(story(id = "119-hr-2102").main!!.vote))
        assertEquals("CONFIRMED", Stories.verdict(story(id = "119-pn-999-2").main!!.vote))
        val vote = rows.first().vote
        assertEquals("AGREED TO", Stories.verdict(vote.copy(result = "Resolution Agreed to")))
        assertEquals("REJECTED", Stories.verdict(vote.copy(result = "Amendment Rejected")))
        assertEquals("FAILED", Stories.verdict(vote.copy(result = "Failed")))
        assertEquals("PASSED SENATE", Stories.verdict(vote.copy(result = "Bill Passed")))
        assertEquals("NO QUORUM", Stories.verdict(vote.copy(result = "No Quorum")))
    }

    @Test
    fun theBandAndMiniLinesReadAsTheMockDoes() {
        val hr2102 = story(id = "119-hr-2102").measure!!
        assertEquals("H.R. 2102 · Sponsor Bilirakis (R-FL)", Stories.citationLine(hr2102))
        assertEquals("Armed Forces and National Security", Stories.topicLine(hr2102))
        val domenico = story(id = "119-pn-999-2").measure!!
        assertEquals("U.S. Circuit Judge · PN999-2", Stories.citationLine(domenico))
        assertEquals("Nomination · Tenth Circuit", Stories.topicLine(domenico))
        assertEquals("Fifth Circuit · Cloture agreed Nov 12", Stories.miniLine(story(id = "119-pn-1181-7"), eastern, Locale.US))
        val unnamed = story(id = "senate-119-2-264")
        assertEquals("Cloture Motion", Stories.miniTitle(unnamed))
        assertEquals("Measure not named in the record · Nov 16", Stories.miniLine(unnamed, eastern, Locale.US))
    }

    @Test
    fun theSplitIsYeaThenNayLargestFirst() {
        val main = story(id = "119-hr-2102").main!!
        assertEquals(listOf(Triple("D", Position.YEA, 210), Triple("R", Position.YEA, 182), Triple("R", Position.NAY, 18)), Stories.split(main.partyTotals))
    }

    @Test
    fun yourMembersSayWhenTheyVotedTheSameOnEveryStep() {
        val hr2102 = Stories.members(story(newYork, "119-hr-2102"))
        assertEquals(listOf("Nadler"), hr2102.map { it.position.member.lastName })
        assertEquals(Position.YEA, hr2102[0].position.position)
        assertEquals("on all three", hr2102[0].sameOnAll?.let(Stories::onAll))
        val domenico = Stories.members(story(newYork, "119-pn-999-2"))
        assertEquals(listOf("Schumer" to 2, "Gillibrand" to null), domenico.map { it.position.member.lastName to it.sameOnAll })
        assertTrue(domenico.all { it.position.position == Position.NAY })
        assertEquals("on both", Stories.onAll(2))
        // "All" shows your three only: limiting to Schumer drops Gillibrand.
        assertEquals(listOf("Schumer"), Stories.members(story(newYork, "119-pn-999-2"), setOf("S000148")).map { it.position.member.lastName })
        assertTrue(Stories.members(story(id = "119-hr-2102")).isEmpty())
    }

    @Test
    fun aCardReadsAsOneSentence() {
        val hr2102 = story(newYork, "119-hr-2102")
        assertEquals(
            "Major Richard Star Act. Passed the House. Passage, 392 to 18. Nadler yea on all three.",
            Stories.spoken(hr2102, Stories.members(hr2102)),
        )
    }

    @Test
    fun anOlderApiStillDecodes() {
        val old = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes
        assertNull(old.first().partyTotals)
        assertNull(old.first().measure?.sponsor)
        assertNull(old.first().measure?.forBillId)
        // With no explainer kinds, nothing is procedural and every measure is a full card.
        assertTrue(Stories.group(HomeState.annotate(old, emptyList())).filter { it.measure != null }.all { it.isFull })
    }

    @Test
    fun yourFeedTakesTheSplitsOfTheLatestFinals() {
        val members = listOf(Fixtures.decode("member-detail-nadler", MemberDetail.serializer()).member)
        val yours = HomeState.merge(members.zip(listOf(Fixtures.decode("member-votes-nadler-stories", MemberVotes.serializer()).votes)), listOf("N000002"))
        assertTrue(yours.all { it.partyTotals.isEmpty() })
        assertTrue(HomeState.withSplits(yours, rows).all { it.partyTotals.isNotEmpty() })
    }
}
