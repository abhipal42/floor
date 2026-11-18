package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.util.Locale

/**
 * v0.2.60's news and polls: decoding (lenient), the tone bar's proportions, the story / other
 * grouping behind the filter chips, and the words. Schumer and Gillibrand's real headlines of
 * Nov 11–17, 2026, tones hand-labelled (each fixture says so in `_note`).
 */
class NewsTest {
    private val schumer = Fixtures.decode("news-schumer", MemberNews.serializer())
    private val gillibrand = Fixtures.decode("news-gillibrand", MemberNews.serializer())
    private val eastern = ZoneId.of("America/New_York")

    @Test
    fun theToneBarCountsEverythingButTheOffice() {
        val tone = ToneCounts(favorable = 1, neutral = 5, critical = 3, office = 4)
        assertEquals(9, tone.counted)
        assertEquals(listOf(Tone.FAVORABLE to 1f / 9, Tone.NEUTRAL to 5f / 9, Tone.CRITICAL to 3f / 9), tone.bar)
        // A tone with none has no segment, and nothing counted is no bar at all.
        assertEquals(listOf(Tone.NEUTRAL to 1f), ToneCounts(neutral = 5, office = 1).bar)
        assertEquals(emptyList<Pair<Tone, Float>>(), ToneCounts(office = 2).bar)
        assertEquals("Coverage tone: 1 favorable, 5 neutral, 3 critical", tone.spoken)
    }

    @Test
    fun schumersWeekIsOneStoryAndThreeOthers() {
        assertEquals(12, schumer.headlines.size)
        assertEquals(ToneCounts(1, 7, 4, 0), schumer.tone)
        val story = schumer.shownStories.single()
        val rows = schumer.storyHeadlines(story)
        assertEquals(9, rows.size)
        // Newest first: the three the card shows.
        assertEquals(
            listOf("The Hill", "The New York Times", "NPR"),
            rows.take(3).map { it.source },
        )
        assertEquals(3, schumer.otherHeadlines.size)
        assertTrue(schumer.otherHeadlines.none { it.storyId == story.id })
        assertEquals(
            listOf("All", "Van Hollen challenges… · 9", "Other · 3"),
            schumer.filters.map { it.label },
        )
    }

    @Test
    fun notAiReadIsAPlainList() {
        val plain = schumer.copy(tone = null)
        assertEquals(emptyList<NewsStory>(), plain.shownStories)
        assertEquals(listOf(NewsFilter.All), plain.filters)
        assertEquals(12, plain.otherHeadlines.size)
        assertEquals("12 headlines this week.", plain.spokenSummary)
    }

    @Test
    fun aStoryWithFewerThanTwoHeadlinesHereIsNotAStory() {
        val story = schumer.stories.single()
        val one = schumer.copy(headlines = schumer.headlines.filter { it.storyId != story.id } + schumer.storyHeadlines(story).take(1))
        assertEquals(emptyList<NewsStory>(), one.shownStories)
        assertEquals(listOf("All"), one.filters.map { it.label })
        assertEquals(4, one.otherHeadlines.size)
    }

    @Test
    fun gillibrandsOfficeReleaseIsShownNotCounted() {
        assertEquals(ToneCounts(0, 5, 0, 1), gillibrand.tone)
        assertEquals(listOf(NewsFilter.All), gillibrand.filters)
        val office = gillibrand.headlines.single { it.toneValue == Tone.OFFICE }
        assertEquals("Merkley (.gov)", office.source)
        assertTrue(office.spoken(eastern, Locale.US).endsWith("from their office"))
        assertEquals("6 headlines this week", gillibrand.countLine)
        assertEquals("6 headlines this week. AI read: 0 favorable, 5 neutral, 0 critical.", gillibrand.spokenSummary)
        assertEquals("No published poll has named Kirsten Gillibrand in the last 90 days.", News.noPolls("Kirsten Gillibrand"))
    }

    @Test
    fun aHeadlineReadsItsTitleSourceDayAndTone() {
        val top = schumer.headlines.first()
        assertEquals("The Hill · Nov 17", top.sourceLine(eastern, Locale.US))
        assertEquals(
            "Schumer declares he has votes to beat Van Hollen and become majority leader, The Hill, Nov 17, favorable coverage",
            top.spoken(eastern, Locale.US),
        )
    }

    @Test
    fun pollsReadAsThePollsterWorded() {
        val (yougov, dfp, nbc) = schumer.polls
        assertEquals("Economist/YouGov · Nov 13–16 · U.S. adults", yougov.header(Locale.US))
        assertEquals(Triple(22f, 28f, 50f), yougov.bar)
        // No third share reported: the remainder is drawn, unlabelled.
        assertNull(dfp.other)
        assertEquals(Triple(32f, 12f, 56f), dfp.bar)
        assertEquals("NBC News · Oct 28–30 · registered voters", nbc.header(Locale.US))
        assertEquals("Oct 28 – Nov 2", News.fieldDates("2026-10-28", "2026-11-02", Locale.US))
        assertEquals("Nov 13", News.fieldDates("2026-11-13", "2026-11-13", Locale.US))
        assertEquals("22%", News.percent(22.0))
        assertEquals("22.5%", News.percent(22.5))
        assertEquals("Each poll opens its release. Only polls that name Chuck Schumer are shown.", News.pollsFootnote("Chuck Schumer"))
    }

    @Test
    fun anUnknownToneOrAMissingFieldReadsAsNull() {
        val news = FloorApi.json.decodeFromString(
            MemberNews.serializer(),
            """{"memberId":"X","tone":null,"headlines":[{"id":"a","title":"T","tone":"glowing"},{"bad":1}],"polls":[{"id":"p"}]}""",
        )
        assertEquals(1, news.headlines.size)
        assertNull(news.headlines.single().toneValue)
        assertEquals(emptyList<Poll>(), news.polls)
        assertTrue(FloorApi.json.decodeFromString(MemberNews.serializer(), MemberNews.NONE_BODY).isEmpty)
    }

    @Test
    fun aChipTitleIsCutAtAWord() {
        assertEquals("Leadership fight", News.shorten("Leadership fight"))
        assertEquals("Van Hollen challenges…", News.shorten("Van Hollen challenges Schumer for majority leader"))
        assertEquals("Leadership fight", NewsStory("s", "Van Hollen challenges Schumer", shortTitle = "Leadership fight").chipTitle)
    }
}
