package app.floor.android.member

import app.floor.android.Fixtures
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberVotes
import app.floor.android.model.Promises
import app.floor.android.model.RecordStats
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.ZoneId
import java.util.Locale

/** The one-scroll member page's words and sections, on Schumer's record as the API served it on Nov 17, 2026. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class MemberPageTest {
    private val detail = Fixtures.decode("arena-schumer-detail", MemberDetail.serializer())
    private val votes = Fixtures.decode("arena-schumer-votes-40", MemberVotes.serializer()).votes
    private val schumer = detail.member
    private val eastern = ZoneId.of("America/New_York")

    @Test
    fun theEyebrowSaysWhoTheyAreToYou() {
        assertEquals("YOUR SENATOR · NEW YORK", heroEyebrow(schumer, isRep = true, following = false))
        assertEquals("FOLLOWING", heroEyebrow(schumer, isRep = false, following = true))
        assertEquals("SENATE · NEW YORK", heroEyebrow(schumer, isRep = false, following = false))
        assertEquals("Democrat · Senate", heroSubtitle(schumer))
    }

    @Test
    fun theHeroReadsAsOneSentence() {
        val figures = HeroFigures.of(detail.partyLoyalty.withPartyShare, RecordStats(votes))
        assertEquals(
            "Chuck Schumer. Your Senator, New York. Democrat, Senate. with their party ${figures.withParty}, " +
                "showed up ${figures.showedUp.replace("/", " of ")}, on the winning side ${figures.winning.replace("/", " of ")}.",
            heroSpoken(schumer, heroEyebrow(schumer, true, false), figures),
        )
        assertEquals("97.6%", figures.withParty)
    }

    @Test
    fun aVoteRowSaysTheResultTheScoreAndTheDay() {
        assertEquals("Anna St. John", voteTitle(votes[0]))
        assertEquals("Confirmed 52–46 · Nov 17", voteLine(votes[0], eastern, Locale.US))
        assertEquals("Cloture Motion", voteTitle(votes[1]))
        assertEquals("Agreed 70–27 · Nov 16", voteLine(votes[1], eastern, Locale.US))
    }

    @Test
    fun aSectionWithNothingInItHasNoChip() {
        val full = MemberState(
            record = Load.Loaded(MemberRecord(detail, votes)),
            promises = Load.Loaded(Fixtures.decode("arena-schumer-promises", Promises.serializer())),
            posts = Load.Loaded(Fixtures.decode("arena-schumer-posts", MemberPosts.serializer())),
        )
        assertEquals(MemberSection.entries, visibleSections(full))
        val bare = MemberState(
            record = Load.Loaded(MemberRecord(MemberDetail(schumer.copy(social = null)), emptyList())),
            promises = Load.Loaded(Promises()),
            posts = Load.Loaded(MemberPosts()),
        )
        assertEquals(listOf(MemberSection.MONEY, MemberSection.CONTACT), visibleSections(bare))
        // Still loading, a section keeps its place.
        assertEquals(MemberSection.entries.drop(1), visibleSections(MemberState(record = Load.Loaded(MemberRecord(detail, emptyList())))))
    }
}
