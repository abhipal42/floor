package app.floor.android.model

import app.floor.android.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The topic-colour table and the procedural kinds: data both platforms must hold the same. */
class StoryPartsTest {
    @Test
    fun everyPolicyAreaHasAColourAndNothingElseDoes() {
        assertEquals(Topic.names.toSet(), TopicGroup.table.keys)
        assertEquals(32, TopicGroup.table.size)
        // The topics list the API serves, as recorded.
        val served = Fixtures.decode("topics", TopicList.serializer()).topics.map { it.name }
        for (name in served) assertTrue("$name has no colour", name in TopicGroup.table)
    }

    @Test
    fun aMeasureTakesItsGroup() {
        val bill = MeasureSummary("119-hr-2102", MeasureSummary.Kind.BILL, "H.R. 2102", "Major Richard Star Act", "Armed Forces and National Security")
        assertEquals(TopicGroup.DEFENSE, TopicGroup.of(bill))
        assertEquals(TopicGroup.OTHER, TopicGroup.of(bill.copy(policyArea = null)))
        assertEquals(TopicGroup.OTHER, TopicGroup.of(null))
        val judge = MeasureSummary("119-pn-999-2", MeasureSummary.Kind.NOMINATION, "PN999-2", "Daniel Desmond Domenico", position = "United States Circuit Judge for the Tenth Circuit")
        assertEquals(TopicGroup.COURTS, TopicGroup.of(judge))
        assertEquals(TopicGroup.GOV, TopicGroup.of(judge.copy(position = "Member of the National Labor Relations Board")))
        assertEquals(TopicGroup.GOV, TopicGroup.of(judge.copy(position = null)))
    }

    @Test
    fun everyKindTheApiExplainsIsProceduralOrNot() {
        val kinds = Fixtures.decode("vote-kinds", VoteKindList.serializer()).kinds.map { it.kind }.toSet()
        assertTrue((VoteStep.procedural intersect VoteStep.substantive).isEmpty())
        assertEquals(kinds, VoteStep.procedural + VoteStep.substantive)
    }
}
