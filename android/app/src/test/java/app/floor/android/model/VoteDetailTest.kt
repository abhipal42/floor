package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `GET /v1/votes/{id}` and `GET /v1/vote-kinds` against the recorded responses the iOS tests use
 * (`VoteScreenModelTests`, `ContractTests`), and the vote screen's arithmetic on them.
 */
class VoteDetailTest {
    private fun detail(name: String) = Fixtures.decode(name, VoteDetail.serializer())

    @Test
    fun decodesTheFlatVoteBesideItsBreakdowns() {
        val d = detail("vote-cloture-explained")
        assertEquals("senate-119-2-253", d.vote.id)
        assertEquals(VoteThreshold.THREE_FIFTHS_SWORN, d.vote.threshold)
        assertEquals("cloture_motion_to_proceed", d.vote.explainer?.kind)
        assertEquals(listOf("R", "D", "I"), d.partyTotals.map { it.party })
        assertEquals(listOf("Cornyn", "Cruz"), d.positions.map { it.member.lastName })
        assertTrue(d.positions.all { it.position == Position.YEA && it.member.chamber == Chamber.SENATE })
        assertEquals("H.R. 7008 · Stop Insider Trading Act", d.title)
        assertTrue(d.candidateTotals.isEmpty())
    }

    @Test
    fun decodesEveryRecordedVote() {
        listOf(
            "vote-cloture-explained", "vote-cloture-failed", "vote-election", "vote-passage-hr1013",
            "vote-question", "vote-two-thirds-failed",
        ).forEach { name ->
            val d = detail(name)
            // Every party row adds up to the vote's own totals.
            assertEquals(name, d.vote.totals.yea, d.partyTotals.sumOf { it.yea })
            assertEquals(name, d.vote.totals.notVoting, d.partyTotals.sumOf { it.notVoting })
        }
    }

    @Test
    fun roundTripsThroughItsOwnFlatShape() {
        val d = detail("vote-passage-hr1013")
        val text = FloorApi.json.encodeToString(VoteDetail.serializer(), d)
        assertEquals(d, FloorApi.json.decodeFromString(VoteDetail.serializer(), text))
    }

    @Test
    fun aProceduralVoteIsTitledByItsQuestion() {
        val d = detail("vote-election")
        assertNull(d.measure)
        assertEquals("Election of the Speaker", d.title)
    }

    @Test
    fun boxScoreLeadsWithTheLargerPartyAndTheRollWithDemocrats() {
        // 219 Republicans on the roll to 214 Democrats.
        val passage = detail("vote-passage-hr1013")
        assertEquals(listOf("R", "D"), passage.boxScore.map { it.party })
        assertEquals(listOf("D", "R"), passage.rollParties.map { it.party })
        assertEquals(433, passage.rollCount)

        val cloture = detail("vote-cloture-explained")
        assertEquals(listOf("R", "D", "I"), cloture.boxScore.map { it.party })
        assertEquals(listOf("D", "R", "I"), cloture.rollParties.map { it.party })
        assertEquals(100, cloture.rollCount)
        assertTrue(!cloture.anyPresent)
    }

    @Test
    fun crossoverSentencesComeFromTheCounts() {
        assertEquals("A party-line vote: no Democrat or Republican crossed.", detail("vote-cloture-explained").crossoverSentence)
        // The iOS snapshot of H.Con.Res. 14 says the same.
        assertEquals("2 Republicans crossed to join a unanimous Democratic side.", detail("vote-question").crossoverSentence)
        assertEquals("83 Democrats crossed to join a unanimous Republican side.", detail("vote-passage-hr1013").crossoverSentence)
        assertNull(detail("vote-election").crossoverSentence)
    }

    @Test
    fun speakerBallotGroupsCandidatesStrongestFirst() {
        val d = detail("vote-election")
        val strength = d.candidatesByStrength
        assertEquals("Jeffries", strength.first().candidate)
        assertEquals(d.vote.candidates.sumOf { it.total }, strength.sumOf { it.total })
        assertEquals(strength.sortedByDescending { it.total }, strength)
    }

    @Test
    fun squaresAreOnePerMemberInRollOrder() {
        val party = PartyTotals("D", yea = 2, nay = 1, present = 1, notVoting = 1)
        assertEquals(
            listOf(Position.YEA, Position.YEA, Position.NAY, Position.PRESENT, Position.NOT_VOTING),
            party.squares,
        )
    }

    @Test
    fun decodesTheKindsOfVoteInTableOrder() {
        val kinds = Fixtures.decode("vote-kinds", VoteKindList.serializer()).kinds
        assertEquals(42, kinds.size)
        val first = kinds.first()
        assertEquals("Cloture Motion", first.title)
        assertEquals(Chamber.SENATE, first.chamber)
        assertEquals(
            "Senate · When: The vote needed a simple majority (cloture on a nomination) · " +
                "Senate Rule XXII; precedents of Nov. 21, 2013 and Apr. 6, 2017",
            first.footnote,
        )
        // As the iOS list titles them: the question less its "On the" / "On Motion to".
        val titles = kinds.map { it.title }
        assertTrue(titles.contains("Cloture on the Motion to Proceed"))
        assertTrue(titles.contains("Suspend the Rules and Pass"))
        assertTrue(kinds.any { it.chamber == null })
    }

    @Test
    fun aKindWithNoQuestionIsTitledByItsKey() {
        assertEquals("motion to table", VoteKindInfo("motion_to_table", "t", "s").title)
    }
}
