package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.home.FlapBoardRows
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** What TalkBack reads, the split-flap board's letters, and the saved-data line. */
class SpokenTest {
    private val hr1013 = Fixtures.decode("vote-passage-hr1013", Vote.serializer())

    @Test
    fun readsACardAsSentences() {
        val text = Spoken.scoreboard(hr1013, "Retirement Fairness Act", "H.R. 1013", "Nov 11")
        assertEquals(
            "H.R. 1013, ${hr1013.question}, passed, 295 yea to 128 nay. Retirement Fairness Act. House, Nov 11, needed 212.",
            text,
        )
    }

    @Test
    fun aSpeakerBallotSaysNobodyWasElected() {
        val ballot = Fixtures.decode("vote-election", Vote.serializer())
        assertTrue(Spoken.result(ballot).startsWith("Jeffries led with 212, McCarthy had 201; nobody was elected"))
    }

    @Test
    fun lettersTheSplitFlapBoard() {
        val measure = MeasureSummary("119-hr-1013", MeasureSummary.Kind.BILL, "H.R. 1013", "Retirement Fairness Act")
        val rows = FlapBoardRows.rows(RecentVote(hr1013.copy(rollNumber = 321), measure))
        assertEquals(listOf("HOUSE  ROLL 321 ", "H.R. 1013 PASSED", "YEA 295 NAY 128 "), rows)
        assertTrue(rows.all { it.length == 16 })
        val long = RecentVote(hr1013, MeasureSummary("x", MeasureSummary.Kind.BILL, "H.Con.Res. 1000", "x"))
        assertEquals("     PASSED     ", FlapBoardRows.rows(long)[1])
        val ballot = FlapBoardRows.rows(RecentVote(Fixtures.decode("vote-election", Vote.serializer()), null))
        assertEquals("NO SPEAKER YET", ballot[1].trim())
        assertEquals("JEFFRIES 212", ballot[2].trim())
    }

    @Test
    fun saysHowOldASavedCopyIs() {
        val now = Instant.parse("2026-11-16T12:00:00Z")
        fun ago(minutes: Long) = now.minusSeconds(minutes * 60)
        assertEquals("just now", SavedCopy.age(now, now))
        assertEquals("12 min ago", SavedCopy.age(ago(12), now))
        assertEquals("2 h ago", SavedCopy.age(ago(150), now))
        assertEquals("3 d ago", SavedCopy.age(ago(60 * 24 * 3 + 5), now))
        assertEquals("Offline · saved 2 h ago", SavedCopy(ago(120), SavedCopy.Status.OFFLINE).text(now))
        assertEquals("Saved just now · refreshing…", SavedCopy(now, SavedCopy.Status.REFRESHING).text(now))
        assertEquals("Couldn't refresh · saved 5 min ago", SavedCopy(ago(5), SavedCopy.Status.REFRESH_FAILED).text(now))
    }
}
