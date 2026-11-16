package app.floor.android.model

import app.floor.android.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun question(
    yea: Int, nay: Int, present: Int = 0, notVoting: Int = 0, threshold: VoteThreshold,
    result: String?, question: String = "On Passage",
) = Vote(
    id = "x", kind = VoteKind.QUESTION, chamber = Chamber.HOUSE, congress = 119, session = 2, rollNumber = 1,
    question = question, state = VoteState.FINAL, threshold = threshold,
    totals = VoteTotals(yea, nay, present, notVoting), result = result,
)

/** The threshold arithmetic, ported with the iOS `VoteOutcomeTests` cases. */
class VoteOutcomeTest {
    /** H.R. 1013, House roll 321 of 2026: 295–128, 423 cast, so 212 needed. */
    @Test
    fun majorityOfThoseVoting() {
        val vote = Fixtures.decode("vote-passage-hr1013", Vote.serializer())
        val line = vote.line!!
        assertEquals(423, line.cast)
        assertEquals(212, line.needed)
        assertEquals(83, line.over)
        assertNull(line.short)
        assertEquals(295.0 / 423, line.yeaShare, 1e-9)
        assertEquals(212.0 / 423, line.lineShare, 1e-9)
        assertEquals("MAJORITY", line.label)
        assertEquals(Outcome.CARRIED, vote.outcome)
        assertEquals("PASSED", vote.outcomeWord)
    }

    /** H.J.Res. 1 under suspension, 212–206: two-thirds of 418 is 279, so it lost by 67. */
    @Test
    fun twoThirdsOfThoseVoting() {
        val vote = Fixtures.decode("vote-two-thirds-failed", Vote.serializer())
        val line = vote.line!!
        assertEquals(VoteThreshold.TWO_THIRDS, vote.threshold)
        assertEquals(279, line.needed)
        assertEquals(67, line.short)
        assertEquals(Outcome.FAILED, vote.outcome)
        assertEquals("FAILED", vote.outcomeWord)
        assertEquals("TWO-THIRDS", line.label)
        assertEquals(67, question(yea = 67, nay = 33, threshold = VoteThreshold.TWO_THIRDS, result = null).line?.needed)
    }

    /** Cloture is three-fifths of the Senate sworn, 60, however many vote. */
    @Test
    fun clotureNeedsSixtyWhoeverVotes() {
        val vote = Fixtures.decode("vote-cloture-failed", Vote.serializer())
        val line = vote.line!!
        assertEquals(60, line.needed)
        assertEquals(7, line.short)
        assertEquals("60 OF 100", line.label)
        assertEquals(Outcome.FAILED, vote.outcome)
        assertEquals("REJECTED", vote.outcomeWord)
        val thin = question(yea = 49, nay = 45, notVoting = 6, threshold = VoteThreshold.THREE_FIFTHS_SWORN, result = null)
        assertEquals(60.0 / 94, thin.line!!.lineShare, 1e-9)
    }

    @Test
    fun readsTheChambersOwnResultFirst() {
        assertEquals(Outcome.FAILED, question(yea = 10, nay = 90, threshold = VoteThreshold.MAJORITY, result = "Not Agreed to").outcome)
        assertEquals("AGREED", question(yea = 61, nay = 32, threshold = VoteThreshold.MAJORITY, result = "Motion to Table Agreed to").outcomeWord)
        assertEquals("CONFIRMED", question(yea = 47, nay = 41, threshold = VoteThreshold.MAJORITY, result = "Nomination Confirmed").outcomeWord)
        // A Vice President's tie-break: the arithmetic says lost, the Senate says agreed.
        assertEquals(Outcome.CARRIED, question(yea = 50, nay = 50, threshold = VoteThreshold.MAJORITY, result = "Motion Agreed to").outcome)
        assertEquals(Outcome.CARRIED, question(yea = 220, nay = 210, threshold = VoteThreshold.MAJORITY, result = null).outcome)
    }

    @Test
    fun aSustainedVetoIsAFailedOverride() {
        val q = "On Passage of the Bill, the Objections of the President Notwithstanding"
        val sustained = question(yea = 60, nay = 40, threshold = VoteThreshold.TWO_THIRDS, result = "Veto Sustained", question = q)
        assertEquals(Outcome.FAILED, sustained.outcome)
        assertEquals("Veto override", sustained.questionKind)
        assertEquals("OVERRIDDEN", question(yea = 70, nay = 30, threshold = VoteThreshold.TWO_THIRDS, result = "Veto Overridden", question = q).outcomeWord)
        assertEquals(Outcome.CARRIED, question(yea = 220, nay = 200, threshold = VoteThreshold.MAJORITY, result = "Decision of Chair Sustained").outcome)
    }

    @Test
    fun theLineGoesQuietWhenTheRecordDisagrees() {
        val tieBreak = question(yea = 50, nay = 50, threshold = VoteThreshold.MAJORITY, result = "Motion Agreed to").line!!
        assertTrue(tieBreak.contradicted)
        assertNull(tieBreak.over)
        assertNull(tieBreak.short)
        val agree = question(yea = 220, nay = 200, threshold = VoteThreshold.MAJORITY, result = "Passed").line!!
        assertFalse(agree.contradicted)
        assertEquals(9, agree.over)
    }

    @Test
    fun namesTheKindOfQuestion() {
        fun kind(q: String) = question(yea = 1, nay = 1, threshold = VoteThreshold.MAJORITY, result = null, question = q).questionKind
        assertEquals("Suspension", kind("On Motion to Suspend the Rules and Pass, as Amended"))
        assertEquals("Cloture", kind("On Cloture on the Motion to Proceed"))
        assertEquals("Previous question", kind("On Ordering the Previous Question"))
        assertEquals("Nomination", kind("On the Nomination"))
        assertEquals("Concur", kind("On Motion to Concur in the Senate Amendment"))
        assertEquals("Conference report", kind("On Agreeing to the Conference Report"))
        assertEquals("Quorum Call", kind("On the Quorum Call"))
        // Every question in the recorded feed maps to a short kind.
        val votes = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes
        assertTrue(votes.none { it.vote.questionKind.startsWith("On ") })
    }
}
