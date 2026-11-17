package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import okhttp3.HttpUrl.Companion.toHttpUrl
import app.floor.android.member.Load
import app.floor.android.member.MemberModel
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
import java.time.ZoneId
import java.util.Locale

/**
 * Round 13's half of the contract: promises, posts, the wall and the member's social handles,
 * decoded from the hand-built fixtures (real content; see each `_note`) and leniently, and the
 * routes and their 404s against a local server.
 */
class SaidTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val eastern = ZoneId.of("America/New_York")
    private val server = MockWebServer()
    private val asked = mutableListOf<String>()
    private val routes = mapOf(
        "/v1/members/S001208/promises" to "promises-slotkin",
        "/v1/members/S000148/posts" to "posts-schumer",
        "/v1/posts" to "posts-wall-ny",
    )

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                synchronized(asked) { asked += request.url.toString() }
                val name = routes[request.url.encodedPath] ?: return MockResponse.Builder().code(404).body("""{"error":"Not found"}""").build()
                return MockResponse.Builder().code(200).body(Fixtures.text(name)).build()
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private fun api() = FloorApi(server.url("/").toString(), cache = FileResponseCache(folder.root))

    // MARK: Promises

    @Test
    fun slotkinsThreePromisesQuotedExactly() {
        val said = Fixtures.decode("promises-slotkin", Promises.serializer())
        assertEquals(Promises.Status.PROMISES, said.state)
        assertEquals(2024, said.electionYear)
        assertEquals(3, said.promises.size)
        // Each headline is the quote's own words, cut at a clause: the contract's verbatim rule.
        said.promises.forEach { assertTrue(it.headline, it.quote.contains(it.headline)) }
        assertEquals(listOf("Commerce", "Health", "Crime and Law Enforcement"), said.promises.map { it.floorTopic })
        assertEquals("Defending and Expanding Michigan’s Middle Class", said.promises[1].heading)
        assertEquals("Oct 12, 2024", said.archivedDay(Locale.US))
        assertEquals("elissaslotkin.org", said.siteHost)
    }

    @Test
    fun gillibrandListedNoIssues() {
        val said = Fixtures.decode("promises-gillibrand", Promises.serializer())
        assertEquals(Promises.Status.NO_PLATFORM, said.state)
        assertEquals("kirstengillibrand.com", said.siteHost)
        assertEquals("Oct 16, 2024", said.archivedDay(Locale.US))
    }

    @Test
    fun promisesDecodeLeniently() {
        fun state(json: String) = FloorApi.json.decodeFromString(Promises.serializer(), json).state
        assertEquals(Promises.Status.UNCHECKED, state(Promises.UNCHECKED_BODY))
        assertEquals(Promises.Status.UNCHECKED, state("""{"status":"failed"}"""))
        assertEquals(Promises.Status.UNCHECKED, state("{}"))
        assertEquals(Promises.Status.NO_SITE, state("""{"status":"no_site","electionYear":2024}"""))
        assertEquals(Promises.Status.NO_SNAPSHOT, state("""{"status":"no_snapshot","siteUrl":null}"""))
        // A site with promises but none this build can read is drawn as one that listed none.
        assertEquals(Promises.Status.NO_PLATFORM, state("""{"status":"promises","promises":[{"heading":"x"}]}"""))
        val one = FloorApi.json.decodeFromString(
            Promises.serializer(),
            """{"status":"promises","promises":[{"quote":"q a","headline":"a","topic":"Not a topic"},{"oops":1}],"snapshotAt":"not a date"}""",
        )
        assertEquals(1, one.promises.size)
        assertNull(one.promises[0].floorTopic)
        assertNull(one.archivedDay(Locale.US))
    }

    // MARK: Social

    @Test
    fun schumersAccountsAndWhereEachOpens() {
        val detail = Fixtures.decode("member-detail-schumer", MemberDetail.serializer())
        val accounts = detail.accounts
        assertEquals(
            listOf(SocialNetwork.X, SocialNetwork.FACEBOOK, SocialNetwork.INSTAGRAM, SocialNetwork.YOUTUBE, SocialNetwork.BLUESKY),
            accounts.map { it.network },
        )
        assertEquals("@SenSchumer", accounts[0].handle)
        assertEquals("https://x.com/SenSchumer", accounts[0].url)
        assertEquals("https://www.facebook.com/senschumer", accounts[1].url)
        assertEquals("https://www.instagram.com/senschumer", accounts[2].url)
        assertEquals("https://www.youtube.com/SenatorSchumer", accounts[3].url)
        // Only a channel ID: the channel's page.
        assertEquals(
            "https://www.youtube.com/channel/UC-ABttxh8uQv_10qmwGaidw",
            MemberSocial(youtubeId = "UC-ABttxh8uQv_10qmwGaidw").accounts.single().url,
        )
        assertEquals("https://bsky.app/profile/schumer.senate.gov", accounts[4].url)
        assertEquals("https://mastodon.social/@user", SocialNetwork.MASTODON.url("@user@mastodon.social"))
        // An older API sends no social: no accounts, not a failure.
        assertTrue(Fixtures.decode("member-detail-nadler", MemberDetail.serializer()).accounts.isEmpty())
    }

    // MARK: Posts

    @Test
    fun schumersPostsNewestFirstInTheReadersZone() {
        val posts = Fixtures.decode("posts-schumer", MemberPosts.serializer())
        val shown = posts.shown
        assertEquals(listOf(SocialNetwork.BLUESKY, SocialNetwork.YOUTUBE, SocialNetwork.YOUTUBE), shown.map { it.socialNetwork })
        assertEquals("Nov 16 · 5:01 PM", shown[0].whenLabel(eastern, Locale.US))
        assertEquals("Nov 10 · 12:24 PM", shown[2].whenLabel(eastern, Locale.US))
        // Text as posted: the triple space stays.
        assertTrue(shown[0].text!!.contains("response?   Kick"))
        assertEquals("Open on Bluesky ›", shown[0].openLabel)
        assertEquals("Watch on YouTube ›", shown[1].openLabel)
        assertEquals(listOf("@SenSchumer", "senschumer", "senschumer"), posts.links.accounts.map { it.handle })
        assertEquals("https://x.com/SenSchumer", posts.links.accounts[0].url)
        assertEquals("https://x.com/SenSchumer", PostLinks(x = "https://x.com/SenSchumer").accounts[0].url)
    }

    @Test
    fun postsDecodeLeniently() {
        val wall = FloorApi.json.decodeFromString(
            PostsWall.serializer(),
            """{"posts":[{"id":"t:1","network":"tiktok","url":"u"},{"id":"b:1"},{"id":"m:1","network":"mastodon","url":"u","postedAt":"x"}]}""",
        )
        assertEquals(listOf("m:1"), wall.shown.map { it.id })
        assertTrue(wall.unreadable.isEmpty())
        assertNull(wall.shown[0].whenLabel(eastern, Locale.US))
        val ny = Fixtures.decode("posts-wall-ny", PostsWall.serializer())
        assertEquals(3, ny.shown.size)
        assertTrue(ny.shown.all { it.memberId == "S000148" })
        assertEquals(listOf("N000002"), ny.unreadable)
    }

    // MARK: The routes

    @Test
    fun theRoutesAndWhatTheir404sMean() = runTest {
        val api = api()
        assertEquals(3, api.promises("S001208").promises.size)
        assertEquals(3, api.savedPromises("S001208")!!.value.promises.size)
        // An API without the routes yet: not checked, no posts, an empty wall.
        assertEquals(Promises.Status.UNCHECKED, api.promises("G000555").state)
        assertTrue(api.memberPosts("G000555").shown.isEmpty())
        assertEquals(3, api.memberPosts("S000148").shown.size)
        val ids = (1..14).map { "M%06d".format(it) }
        api.posts(ids + ids.first())
        // The API's cap: the first twelve, each once.
        val wall = asked.last { "/v1/posts" in it }.toHttpUrl()
        assertEquals(ids.take(12).joinToString(","), wall.queryParameter("members"))
        val before = asked.size
        assertTrue(api.posts(emptyList()).shown.isEmpty())
        assertEquals(before, asked.size)
    }

    @Test
    fun theMemberScreenLoadsSaidAndPostsOnTheirOwn() = runTest {
        val model = MemberModel(api(), "S001208")
        model.loadPromises()
        assertEquals(3, (model.state.promises as Load.Loaded).value.promises.size)
        model.loadPosts()
        assertTrue((model.state.posts as Load.Loaded).value.shown.isEmpty())
        model.selectPromise(2)
        assertEquals(2, model.state.promise)
    }

    @Test
    fun theWallLoadsForYourMembers() = runTest {
        val api = api()
        assertEquals(3, api.posts(listOf("S000148", "N000002")).shown.size)
        // Saved for offline under the same members.
        assertEquals(listOf("N000002"), api.savedPosts(listOf("S000148", "N000002"))!!.value.unreadable)
        assertNull(api.savedPosts(listOf("C001098")))
    }
}
