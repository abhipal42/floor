package app.floor.android.home

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.model.Chamber
import app.floor.android.model.Delegation
import app.floor.android.onboarding.Coordinate
import app.floor.android.onboarding.LocationAccess
import app.floor.android.onboarding.OnboardingModel
import app.floor.android.onboarding.OnboardingState
import app.floor.android.store.FollowKind
import app.floor.android.store.InMemoryDelegationStore
import app.floor.android.store.InMemoryFollowStore
import app.floor.android.store.Session
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

/**
 * Finals' Following feed and onboarding against a local server answering with the recorded
 * responses: Austin's three (Doggett, Cornyn, Cruz), their records, and `/v1/reps`.
 */
class FollowingFeedTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val server = MockWebServer()
    private val austin = Fixtures.decode("reps-location-austin", Delegation.serializer())
    private val routes = mapOf(
        "/v1/votes" to "votes-recent",
        "/v1/reps" to "reps-location-austin",
        "/v1/members/D000399/votes" to "member-votes-doggett-40",
        "/v1/members/C001056/votes" to "member-votes-cornyn-40",
        "/v1/members/C001098/votes" to "member-votes-cruz-40",
        "/v1/members/D000399" to "member-detail-doggett",
        "/v1/members/C001056" to "member-detail-cornyn",
        "/v1/members/C001098" to "member-detail-cruz",
        "/v1/bills/119-hr-1013" to "bill-hr1013",
    )
    private val asked = mutableListOf<String>()

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                synchronized(asked) { asked += request.url.toString() }
                val name = routes[path] ?: return MockResponse.Builder().code(404).body("""{"error":"Not found"}""").build()
                return MockResponse.Builder().code(200).body(Fixtures.text(name)).build()
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private fun api() = FloorApi(server.url("/").toString(), cache = FileResponseCache(folder.root))

    @Test
    fun yourThreesVotesAreOneCardPerVote() = runTest {
        val session = Session(InMemoryDelegationStore(austin), InMemoryFollowStore())
        session.follows.update { it.follow(FollowKind.BILL, "119-hr-1013") }
        val model = HomeModel(api(), session)
        assertEquals(HomeState.Scope.YOURS, model.state.scope)
        model.load()
        val state = model.state
        assertEquals(HomeState.Phase.Loaded, state.phase)
        assertTrue(state.followsAnything)
        assertEquals(listOf("Doggett", "Cornyn", "Cruz"), state.strip.map { it.lastName })
        assertEquals(3, model.records.size)
        // A Senate roll call both senators voted on is one card with both chips.
        val senate = state.yours.first { it.vote.chamber == Chamber.SENATE }
        assertEquals(setOf("Cornyn", "Cruz"), senate.positions.map { it.member.lastName }.toSet())
        assertEquals(state.yours.distinctBy { it.id }.size, state.yours.size)
        // The followed bill's vote says so on its card.
        val onTheBill = state.yours.first { it.measure?.id == "119-hr-1013" }
        assertEquals(listOf("H.R. 1013"), state.matches(onTheBill).map { it.shown })
        assertEquals(3, state.loyalty.size)
        assertNull(state.unavailableNote)
        // Members-elect: the route 404s here, which reads as none.
        assertTrue(state.seats.elect.isEmpty())
        // The followed bill's saved row now names it.
        assertEquals("H.R. 1013", session.follows.state.followedBills.single().citation)
    }

    @Test
    fun aMemberWhoseVotesFailIsNamedAndTheRestStillShow() = runTest {
        val jeffries = app.floor.android.model.Member("J000294", "Hakeem", "Jeffries", "D", "NY", 8, Chamber.HOUSE)
        val session = Session(InMemoryDelegationStore(austin), InMemoryFollowStore())
        session.follows.toggle(jeffries)
        val model = HomeModel(api(), session)
        model.load()
        assertEquals(HomeState.Phase.Loaded, model.state.phase)
        assertEquals("Couldn't load Jeffries's votes.", model.state.unavailableNote)
    }

    @Test
    fun onboardingByAddressDealsTheThreeAndKeepsNoAddress() = runTest {
        val model = OnboardingModel(api(), { null }, now = { 7 })
        model.type("1100 Congress Ave, Austin, TX")
        model.lookUpNow()
        val found = model.state.phase as OnboardingState.Phase.Found
        assertEquals("TX-37", found.reps.district.name)
        assertEquals(austin.copy(resolvedAt = 7), model.confirm())
        // The address went to /v1/reps once and was never saved.
        assertTrue(folder.root.listFiles().orEmpty().isEmpty())
        // Typing again takes the result back.
        model.type("1100 Congress Ave, Austin, TX 78701")
        assertEquals(OnboardingState.Phase.Editing, model.state.phase)
        model.type("abc")
        model.lookUpNow()
        assertEquals(OnboardingState.Phase.Failed("Enter a street address, city and state."), model.state.phase)
    }

    @Test
    fun onboardingByLocationRoundsThePointAndSaysWhatWentWrong() = runTest {
        val model = OnboardingModel(api(), { Coordinate(30.274_712_9, -97.740_35) })
        model.useLocationNow(LocationAccess.APPROXIMATE)
        assertTrue(model.state.phase is OnboardingState.Phase.Found)
        assertEquals(OnboardingState.Notice.APPROXIMATE, model.state.notice)
        val sent = asked.single { it.contains("/v1/reps") }
        assertTrue(sent, sent.endsWith("lat=30.2747&lng=-97.7404"))
        model.typeAddressInstead()
        assertTrue(model.state.showsAddressField)

        val denied = OnboardingModel(api(), { null })
        denied.useLocationNow(LocationAccess.DENIED)
        assertEquals(OnboardingState.Notice.LOCATION_OFF, denied.state.notice)
        val noFix = OnboardingModel(api(), { null })
        noFix.useLocationNow(LocationAccess.PRECISE)
        assertEquals(OnboardingState.Notice.UNAVAILABLE, noFix.state.notice)
        assertTrue(noFix.state.offersLocation)
    }
}
