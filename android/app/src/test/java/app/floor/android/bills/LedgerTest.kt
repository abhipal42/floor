package app.floor.android.bills

import app.floor.android.Fixtures
import app.floor.android.home.HomeState
import app.floor.android.model.MeasureSummary
import app.floor.android.model.RecentVotes
import app.floor.android.model.TopicGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.ZoneId
import java.util.Locale

/**
 * The Bills ledger from the live finals of Nov 17, 2026 (`votes-three`, each bill with its stage).
 * Robolectric, because the rule line's dates go through the platform's ICU.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class LedgerTest {
    private val rows = Fixtures.decode("votes-three", RecentVotes.serializer()).votes
    private val items = HomeState.annotate(rows, emptyList())
    private val eastern = ZoneId.of("America/New_York")

    private fun card(id: String, from: List<LedgerCard> = Ledger.cards(items)) = from.first { it.measure.id == id }

    private fun steps(id: String) = Ledger.track(card(id))?.map { it.label to it.state }

    @Test
    fun aRuleFoldsIntoTheBillItBringsUp() {
        val cards = Ledger.cards(items)
        assertTrue(cards.none { it.measure.id == "119-hres-1247" || it.measure.id == "119-hres-1650" })
        assertEquals(listOf("house-119-2-322", "house-119-2-320"), card("119-hr-2102").rules.map { it.vote.id })
        assertEquals("+ Rule adopted 271–135, Nov 12 · 245–175, Nov 11", Ledger.ruleLine(card("119-hr-2102").rules, eastern, Locale.US))
        assertEquals("+ Rule adopted 215–209 · 213–207, Nov 10", Ledger.ruleLine(card("119-hr-1013").rules, eastern, Locale.US))
        // A resolution that brings nothing up is a bill like any other.
        assertTrue(card("119-hres-1655").rules.isEmpty() && card("119-hres-1655").ruleFor == null)
        // Only bills: nominations and votes on nothing get no card.
        assertTrue(cards.all { it.measure.kind == MeasureSummary.Kind.BILL })
    }

    @Test
    fun aRuleWhoseBillIsNotListedKeepsACard() {
        val cards = Ledger.cards(items.filter { it.measure?.id != "119-hr-2102" })
        val rule = card("119-hres-1247", cards)
        assertEquals("Rule for H.R. 2102", rule.title)
        assertEquals(2, rule.votes.size)
        assertNull(Ledger.track(rule))
    }

    @Test
    fun theTrackFollowsTheStageAndTheBillsChambers() {
        val done = TrackStep.State.DONE
        val current = TrackStep.State.CURRENT
        val todo = TrackStep.State.AHEAD
        assertEquals(listOf("Introduced" to done, "House ✓" to current, "Senate" to todo, "Law" to todo), steps("119-hr-2102"))
        assertEquals(listOf("Introduced" to done, "Senate ✓" to current, "House" to todo, "Law" to todo), steps("119-s-4668"))
        assertEquals(listOf("Introduced" to done, "Senate ✓" to done, "House ✓" to done, "Law ✓" to current), steps("119-s-2403"))
        assertEquals(listOf("Introduced" to current, "Adopted" to todo), steps("119-sres-852"))
        // Failed in the Senate, the second chamber of a House concurrent resolution.
        assertEquals(
            listOf("Introduced" to done, "House ✓" to current, "Failed" to TrackStep.State.STOPPED, "Adopted" to todo),
            steps("119-hconres-89"),
        )
        assertEquals("Passed the House; next, the Senate", Ledger.spokenTrack(card("119-hr-2102")))
        assertEquals("Became law", Ledger.spokenTrack(card("119-s-2403")))
        assertEquals("Failed in the Senate", Ledger.spokenTrack(card("119-hconres-89")))
        assertEquals("Introduced; next, adoption", Ledger.spokenTrack(card("119-sres-852")))
    }

    @Test
    fun noStageNoTrack() {
        val unstaged = items.map { it.copy(measure = it.measure?.copy(stageRaw = null)) }
        assertNull(Ledger.track(card("119-hr-2102", Ledger.cards(unstaged))))
        val unknown = items.map { it.copy(measure = it.measure?.copy(stageRaw = "in_committee")) }
        assertNull(Ledger.track(card("119-hr-2102", Ledger.cards(unknown))))
    }

    @Test
    fun passedAndBlockedFilterOnTheLatestVote() {
        val passed = Ledger.sections(items, LedgerFilter.PASSED).flatMap { it.cards }.map { it.measure.citation }
        val blocked = Ledger.sections(items, LedgerFilter.BLOCKED).flatMap { it.cards }.map { it.measure.citation }
        assertEquals(setOf("H.R. 9340", "H.R. 7008", "S.Res. 852", "S.J.Res. 197", "H.Con.Res. 89"), blocked.toSet())
        assertTrue("H.R. 2102" in passed && "S. 4668" in passed && "H.R. 2347" in passed)
        assertTrue(passed.none { it in blocked })
        assertEquals(Ledger.cards(items).size, passed.size + blocked.size)
    }

    @Test
    fun sectionsAreTopicGroupsByTheirLatestVote() {
        val sections = Ledger.sections(items, LedgerFilter.ALL)
        // H.R. 2102 (Nov 12, Defense) is the latest bill vote, then H.R. 1013 (Nov 11, Money).
        assertEquals(listOf(TopicGroup.DEFENSE, TopicGroup.MONEY), sections.take(2).map { it.topic })
        assertEquals(sections.map { it.topic }.distinct(), sections.map { it.topic })
        assertEquals("R 182–18 · D 210–0", Ledger.partyLine(card("119-hr-2102").latest))
        assertEquals("Passed House", Ledger.voteKind(card("119-hr-2102").latest.vote))
        assertEquals("Motion to proceed", Ledger.voteKind(card("119-hr-2347").latest.vote))
        assertEquals("Motion to refer", Ledger.voteKind(card("119-hres-1655").latest.vote))
    }
}
