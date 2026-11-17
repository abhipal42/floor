package app.floor.android.vote

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.model.SavedCopy
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant

/** The vote screen and the kinds-of-vote list against a local server answering with recorded responses. */
class VoteModelTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val server = MockWebServer()
    private val cloture = Fixtures.text("vote-cloture-explained")
    private val savedAt = Instant.parse("2026-11-16T10:00:00Z")

    @Before
    fun start() = server.start()

    @After
    fun stop() = server.close()

    private fun api(url: String = server.url("/").toString()) =
        FloorApi(url, cache = FileResponseCache(folder.root), now = { savedAt })

    private fun ok(body: String) = MockResponse.Builder().code(200).body(body).build()

    private fun loadedId(state: VoteScreenState) = (state.phase as VoteScreenState.Phase.Loaded).detail.vote.id

    @Test
    fun loadsOneVoteAndNamesNoMembersWithoutADistrict() = runTest {
        server.enqueue(ok(cloture))
        // The bill it was on follows; one that can't be had leaves the card naming the bill.
        server.enqueue(MockResponse.Builder().code(503).build())
        val model = VoteModel(api(), "senate-119-2-253")
        model.load()
        assertEquals("senate-119-2-253", loadedId(model.state))
        assertNull(model.state.saved)
        assertNull(model.state.bill)
        assertTrue(model.state.explainerOpen)
        val request = server.takeRequest()
        assertEquals("/v1/votes/senate-119-2-253", request.url.encodedPath)
        assertNull(request.url.queryParameter("members"))
        assertEquals("/v1/bills/119-hr-7008", server.takeRequest().url.encodedPath)
    }

    /** H.R. 1013's passage brings H.R. 1013 itself, for the card's "level 3 of 6". */
    @Test
    fun loadsTheBillTheVoteWasOn() = runTest {
        server.enqueue(ok(Fixtures.text("vote-passage-hr1013")))
        server.enqueue(ok(Fixtures.text("bill-hr1013")))
        val model = VoteModel(api(), "house-119-1-100")
        model.load()
        assertEquals("119-hr-1013", model.state.bill?.id)
        server.takeRequest()
        assertEquals("/v1/bills/119-hr-1013", server.takeRequest().url.encodedPath)
    }

    @Test
    fun asksForAtMostTenMembers() = runTest {
        server.enqueue(ok(cloture))
        val ids = (1..12).map { "A%06d".format(it) }
        api().vote("senate-119-2-253", ids)
        assertEquals(ids.take(10).joinToString(","), server.takeRequest().url.queryParameter("members"))
    }

    @Test
    fun keepsTheSavedVoteUpWhenOffline() = runTest {
        server.enqueue(ok(cloture))
        val url = server.url("/").toString()
        api(url).vote("senate-119-2-253")
        server.close()
        val model = VoteModel(api(url), "senate-119-2-253")
        model.load()
        assertEquals("senate-119-2-253", loadedId(model.state))
        assertEquals(SavedCopy(savedAt, SavedCopy.Status.OFFLINE), model.state.saved)
    }

    @Test
    fun saysWhyWhenTheServerRefusesAndNothingIsSaved() = runTest {
        server.enqueue(MockResponse.Builder().code(404).body("""{"error":"No vote with that ID"}""").build())
        val model = VoteModel(api(), "senate-119-2-999")
        model.load()
        assertEquals(VoteScreenState.Phase.Failed("No vote with that ID"), model.state.phase)
    }

    @Test
    fun foldsTheExplainerAndPicksARollParty() {
        val model = VoteModel(api(), "senate-119-2-253")
        model.toggleExplainer()
        model.selectRollParty("R")
        assertEquals(false, model.state.explainerOpen)
        assertEquals("R", model.state.rollParty)
    }

    @Test
    fun kindsOfVoteLoadFreshThenFallBackToSaved() = runTest {
        server.enqueue(ok(Fixtures.text("vote-kinds")))
        val url = server.url("/").toString()
        val fresh = VoteKindsModel(api(url))
        fresh.load()
        assertEquals(42, (fresh.state as VoteKindsState.Loaded).kinds.size)
        assertEquals("/v1/vote-kinds", server.takeRequest().url.encodedPath)

        server.close()
        val offline = VoteKindsModel(api(url))
        offline.load()
        assertEquals(42, (offline.state as VoteKindsState.Loaded).kinds.size)
    }

    @Test
    fun kindsOfVoteFailWithNothingSaved() = runTest {
        val url = server.url("/").toString()
        server.close()
        val model = VoteKindsModel(api(url))
        model.load()
        assertEquals(VoteKindsState.Failed, model.state)
    }
}
