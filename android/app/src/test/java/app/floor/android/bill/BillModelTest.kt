package app.floor.android.bill

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.bills.BillsModel
import app.floor.android.bills.BillsState
import app.floor.android.bills.TopicModel
import app.floor.android.bills.TopicState
import app.floor.android.model.SavedCopy
import app.floor.android.model.TopicFilter
import kotlinx.coroutines.test.runTest
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The bill screen, the Bills tab and a topic's page against a local server answering each route
 * with its recorded response. Robolectric for ICU, which the banner's week is formatted with.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class BillModelTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val server = MockWebServer()
    private val savedAt = Instant.parse("2026-11-16T10:00:00Z")

    /** Path (with query) to response; anything else is a 404 with the API's error body. */
    private val routes = mutableMapOf<String, MockResponse>()
    private val paths = CopyOnWriteArrayList<String>()

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val target = request.target
                paths += target
                return routes[target] ?: routes[target.substringBefore('?')]
                    ?: MockResponse.Builder().code(404).body("""{"error":"Not found"}""").build()
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private fun api(url: String = server.url("/").toString()) =
        FloorApi(url, cache = FileResponseCache(folder.root), now = { savedAt })

    private fun ok(fixture: String) = MockResponse.Builder().code(200).body(Fixtures.text(fixture)).build()

    private fun hr5267Routes() {
        routes["/v1/bills/119-hr-5267"] = ok("bill-hr5267")
        routes["/v1/schedule"] = ok("schedule-2026-11-16")
        routes["/v1/bills/119-hr-5267/share"] = ok("bill-share-hr5267")
        // No analysis route: its 404 means "none yet".
    }

    @Test
    fun loadsABillWithItsBannerAndShareLine() = runTest {
        hr5267Routes()
        val model = BillModel(api(), "119-hr-5267")
        model.load()
        val bill = (model.state.phase as BillScreenState.Phase.Loaded).bill
        assertEquals("H.R. 5267", bill.citation)
        assertNull(model.state.saved)
        // It has a CRS summary, so no analysis yet hides the section rather than promising one.
        assertEquals(AnalysisPhase.Hidden, model.state.analysis)
        assertEquals("Scheduled for House consideration under a rule, week of Nov 16.", model.state.listing?.bannerLine)
        assertEquals("https://floor-web-seven.vercel.app/bill/119/hr/5267", model.state.share?.url)
        assertTrue(paths.contains("/v1/bills/119-hr-5267/analysis"))
    }

    @Test
    fun anAnalysisIsShownLabelledAndCited() = runTest {
        hr5267Routes()
        routes["/v1/bills/119-hr-5267/analysis"] = ok("bill-analysis")
        val model = BillModel(api(), "119-hr-5267")
        model.load()
        val shown = (model.state.analysis as AnalysisPhase.Loaded).analysis
        assertEquals(3, shown.groups.size)
        val chip = shown.citations.first().id
        model.toggleCitation(chip)
        assertEquals(chip, model.state.openCitation)
        model.toggleCitation(chip)
        assertNull(model.state.openCitation)
    }

    @Test
    fun anAnalysisThatFailsWithNothingSavedOffersTryAgain() = runTest {
        hr5267Routes()
        routes["/v1/bills/119-hr-5267/analysis"] = MockResponse.Builder().code(500).build()
        val model = BillModel(api(), "119-hr-5267")
        model.load()
        assertEquals(AnalysisPhase.Failed, model.state.analysis)
    }

    @Test
    fun offlineTheSavedBillAndItsExtrasStayUp() = runTest {
        hr5267Routes()
        routes["/v1/bills/119-hr-5267/analysis"] = ok("bill-analysis")
        val url = server.url("/").toString()
        BillModel(api(url), "119-hr-5267").load()
        server.close()
        val model = BillModel(api(url), "119-hr-5267")
        model.load()
        assertEquals("H.R. 5267", (model.state.phase as BillScreenState.Phase.Loaded).bill.citation)
        assertEquals(SavedCopy(savedAt, SavedCopy.Status.OFFLINE), model.state.saved)
        assertTrue(model.state.analysis is AnalysisPhase.Loaded)
        assertTrue(model.state.listing != null)
        assertTrue(model.state.share != null)
    }

    @Test
    fun saysWhyWhenTheBillIsUnknown() = runTest {
        val model = BillModel(api(), "119-hr-99999")
        model.load()
        assertEquals(BillScreenState.Phase.Failed("Not found"), model.state.phase)
    }

    @Test
    fun theBillsTabListsTheThirtyTwoTopics() = runTest {
        routes["/v1/topics"] = ok("topics")
        val model = BillsModel(api())
        model.loadTopics()
        assertEquals(32, (model.state.topics as BillsState.Phase.Loaded).topics.size)
    }

    @Test
    fun searchSendsTheTrimmedQueryAndIsNeverSaved() = runTest {
        routes["/v1/search?q=hr%201013"] = ok("search-hr1013")
        val model = BillsModel(api())
        model.type("  hr 1013 ")
        model.searchNow()
        val search = model.state.search
        assertEquals("hr 1013", search.searched)
        assertEquals(listOf("H.R. 1013"), search.bills.map { it.citation })
        assertTrue(search.topics.isEmpty())
        assertTrue(paths.contains("/v1/search?q=hr%201013"))
        assertTrue(folder.root.listFiles().isNullOrEmpty())
    }

    @Test
    fun aOneLetterQuerySearchesNothing() = runTest {
        val model = BillsModel(api())
        model.type("h")
        model.searchNow()
        assertNull(model.state.search.searched)
        assertTrue(paths.isEmpty())
    }

    @Test
    fun nothingMatchesSaysSo() = runTest {
        routes["/v1/search?q=pending%20sample"] = ok("search-pending-sample")
        val model = BillsModel(api())
        model.type("pending sample")
        model.searchNow()
        assertTrue(model.state.search.foundNothing)
    }

    @Test
    fun aTopicPagesThroughItsBills() = runTest {
        routes["/v1/topics/Health/bills?filter=all"] = ok("topic-bills-health")
        val model = TopicModel(api(), "Health")
        model.load()
        assertEquals(TopicState.Phase.Loaded, model.state.phase)
        assertEquals(25, model.state.bills.size)
        assertEquals("Health", model.state.topic?.name)
        // The next page fails: the list stays, with a reason to try again.
        model.more()
        assertEquals(25, model.state.bills.size)
        assertEquals("Not found", model.state.moreError)
        assertTrue(paths.last().contains("cursor=WyIyMDI2LTEwLTI2IiwiMTE5LWhyLTEwOTA4Il0"))
    }

    @Test
    fun anEmptyFilterSaysWhatItLooksFor() {
        assertEquals("No Health bills have become law this Congress yet.", TopicState.emptyMessage("Health", TopicFilter.LAW))
        assertEquals("No Health bills have gone 90 days without an action.", TopicState.emptyMessage("Health", TopicFilter.STALLED))
    }
}
