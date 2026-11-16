package app.floor.android.home

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.Chamber
import app.floor.android.model.RecentVotes
import app.floor.android.model.SavedCopy
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant

/** The Finals feed against a local server answering with the recorded `GET /v1/votes`. */
class HomeModelTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val server = MockWebServer()
    private val recent = Fixtures.text("votes-recent")
    private val savedAt = Instant.parse("2026-11-16T10:00:00Z")

    @Before
    fun start() = server.start()

    @After
    fun stop() = server.close()

    private fun api(url: String = server.url("/").toString(), now: Instant = savedAt) =
        FloorApi(url, cache = FileResponseCache(folder.root), now = { now })

    private fun ok(body: String) = MockResponse.Builder().code(200).body(body).build()

    @Test
    fun loadsTheLatestFinals() = runTest {
        server.enqueue(ok(recent))
        val model = HomeModel(api())
        model.load()
        val state = model.state
        assertEquals(HomeState.Phase.Loaded, state.phase)
        assertEquals(10, state.items.size)
        assertNull(state.saved)
        assertEquals(state.items.first(), state.latestFinal)
        val request = server.takeRequest()
        assertEquals("/v1/votes", request.url.encodedPath)
        assertEquals("40", request.url.queryParameter("limit"))
        assertNull(request.url.queryParameter("chamber"))
    }

    @Test
    fun asksForOneChamberWhenFiltered() = runTest {
        server.enqueue(ok(recent))
        api().recentVotes(Chamber.SENATE)
        assertEquals("senate", server.takeRequest().url.queryParameter("chamber"))
        val all = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes
        val senate = HomeState(phase = HomeState.Phase.Loaded, filter = HomeState.Filter.SENATE, items = all).visibleItems
        assertEquals(5, senate.size)
        assertTrue(senate.all { it.vote.chamber == Chamber.SENATE })
    }

    @Test
    fun failsWithAMessageWhenNothingIsSaved() = runTest {
        val url = server.url("/").toString()
        server.close()
        val model = HomeModel(api(url))
        model.load()
        assertEquals(HomeState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."), model.state.phase)
    }

    @Test
    fun showsTheSavedFeedOfflineAndSaysSo() = runTest {
        server.enqueue(ok(recent))
        val url = server.url("/").toString()
        api(url).recentVotes()
        server.close()
        val model = HomeModel(api(url, now = savedAt.plusSeconds(7200)))
        model.load()
        val state = model.state
        assertEquals(HomeState.Phase.Loaded, state.phase)
        assertEquals(10, state.items.size)
        assertEquals(SavedCopy(savedAt, SavedCopy.Status.OFFLINE), state.saved)
    }

    @Test
    fun aServerErrorKeepsTheSavedFeed() = runTest {
        server.enqueue(ok(recent))
        server.enqueue(MockResponse.Builder().code(500).body("<html>").build())
        api().recentVotes()
        val model = HomeModel(api())
        model.load()
        assertEquals(SavedCopy.Status.REFRESH_FAILED, model.state.saved?.status)
        assertEquals(10, model.state.items.size)
    }

    @Test
    fun anApiErrorIsWorded() = runTest {
        server.enqueue(MockResponse.Builder().code(400).body("""{"error":"limit must be 1 to 100"}""").build())
        try {
            api().recentVotes()
            fail("expected an error")
        } catch (e: FloorApiError.Http) {
            assertEquals(400, e.status)
            assertEquals("limit must be 1 to 100", e.message)
        }
        server.enqueue(MockResponse.Builder().code(200).body("""{"votes":[{"vote":{}}]}""").build())
        try {
            api().recentVotes()
            fail("expected an error")
        } catch (e: FloorApiError.Decoding) {
            assertEquals("Floor sent something this version of the app doesn't understand.", e.message)
        }
    }

    @Test
    fun anEmptyFeedSaysSo() = runTest {
        server.enqueue(ok("""{"votes":[]}"""))
        val model = HomeModel(api())
        model.load()
        assertEquals(HomeState.Phase.Loaded, model.state.phase)
        assertTrue(model.state.visibleItems.isEmpty())
        assertNull(model.state.latestFinal)
        assertEquals("No recent votes in this chamber.", model.state.emptyFeedMessage)
    }
}
