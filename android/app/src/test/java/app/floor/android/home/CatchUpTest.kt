package app.floor.android.home

import app.floor.android.Fixtures
import app.floor.android.model.RecentVotes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

/** The catch-up deck's deal and lines, on the live finals of Nov 17, 2026 (`votes-three`). */
class CatchUpTest {
    private val items = HomeState.annotate(Fixtures.decode("votes-three", RecentVotes.serializer()).votes, emptyList())
    private fun item(id: String) = items.first { it.vote.id == id }

    @Test
    fun failuresWithMoreYeasLeadThenTheClosestToTheLine() {
        val deck = CatchUp.select(items)
        assertEquals(5, deck.size)
        // 57–43 and 53–47, both short of 60; then the closest margins to each vote's own line.
        assertEquals(listOf("senate-119-2-254", "senate-119-2-253"), deck.take(2).map { it.vote.id })
        deck.zipWithNext { a, b ->
            if (!CatchUp.failedDespiteMajority(a) && !CatchUp.failedDespiteMajority(b)) {
                assert(kotlin.math.abs(a.vote.totals.yea - a.vote.votesNeeded) <= kotlin.math.abs(b.vote.totals.yea - b.vote.votesNeeded))
            }
        }
    }

    @Test
    fun theTwistIsComputedFromTheCount() {
        assertEquals("A majority voted yes and it still lost: 3 short of 60.", CatchUp.twist(item("senate-119-2-254")))
        assertEquals("Two votes against in the entire House.", CatchUp.twist(item("house-119-2-315")))
    }

    @Test
    fun aProceduralVoteSaysWhatItWasForInItsExplainersWords() {
        assertEquals("A vote to end debate on whether to take up a bill.", CatchUp.stepSentence(item("senate-119-2-254")))
        assertNull(CatchUp.stepSentence(item("house-119-2-323")))
    }

    @Test
    fun theDeckIsSinceItsOldestFinal() {
        val deck = CatchUp.select(items)
        assertEquals(deck.mapNotNull { it.vote.occurredAtInstant }.min(), CatchUp.since(deck))
        assert(CatchUp.since(deck)!! <= Instant.parse("2026-09-30T16:51:00Z"))
    }
}
