package app.floor.android.model

import app.floor.android.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every model this app decodes, against the real recorded responses the iOS tests use
 * (`ListsTests`, `VoteOutcomeTests`). `vote-*.json` is `GET /v1/votes/{id}`, whose vote fields sit
 * flat beside the breakdowns, so a [Vote] decodes straight from it.
 */
class ModelsTest {
    @Test
    fun decodesRecentFinalsNewestFirstWithWhatEachWasOn() {
        val votes = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes
        assertEquals(10, votes.size)
        assertTrue(votes.all { it.vote.state == VoteState.FINAL })
        val dates = votes.mapNotNull { it.vote.occurredAtInstant }
        assertEquals(10, dates.size)
        assertEquals(dates.sortedDescending(), dates)
        assertEquals(MeasureSummary.Kind.NOMINATION, votes.first().measure?.kind)
        assertTrue(votes.any { it.measure?.citation == "H.R. 2102" })
        assertEquals(setOf(Chamber.HOUSE, Chamber.SENATE), votes.map { it.vote.chamber }.toSet())
    }

    @Test
    fun decodesAVoteWithEveryField() {
        val vote = Fixtures.decode("vote-passage-hr1013", Vote.serializer())
        assertEquals(Chamber.HOUSE, vote.chamber)
        assertEquals(VoteKind.QUESTION, vote.kind)
        assertEquals(VoteThreshold.MAJORITY, vote.threshold)
        assertEquals(VoteTotals(yea = 295, nay = 128, present = 0, notVoting = 10), vote.totals)
        assertEquals("Passed", vote.result)
        assertNotNull(vote.occurredAtInstant)
        assertTrue(vote.candidates.isEmpty())
    }

    @Test
    fun decodesTheExplainerWithItsRule() {
        val explainer = Fixtures.decode("vote-cloture-explained", Vote.serializer()).explainer
        assertNotNull(explainer)
        assertEquals("cloture_motion_to_proceed", explainer!!.kind)
        assertTrue(explainer.source.isNotEmpty())
        assertNull(Fixtures.decode("vote-cloture-failed", Vote.serializer()).explainer)
    }

    @Test
    fun decodesASpeakerBallot() {
        val vote = Fixtures.decode("vote-election", Vote.serializer())
        assertEquals(VoteKind.ELECTION, vote.kind)
        assertEquals("Jeffries", vote.leadingCandidate?.name)
        assertEquals(212, vote.leadingCandidate?.total)
        // Leading a ballot is not winning it (HANDOFF lesson 16).
        assertNull(vote.electedSpeaker)
        assertNull(vote.line)
        assertNull(vote.outcome)
        assertEquals("Speaker election", vote.questionKind)
    }

    @Test
    fun aMissingNullableFieldDecodesAsNull() {
        val json = """{"votes":[{"vote":{"id":"x","kind":"question","chamber":"house","congress":119,"session":2,
            "question":"On Passage","state":"final","threshold":"majority",
            "totals":{"yea":1,"nay":0,"present":0,"notVoting":0}},"measure":null}]}"""
        val row = app.floor.android.api.FloorApi.json.decodeFromString(RecentVotes.serializer(), json).votes.single()
        assertNull(row.measure)
        assertNull(row.vote.rollNumber)
        assertNull(row.vote.occurredAtInstant)
    }
}
