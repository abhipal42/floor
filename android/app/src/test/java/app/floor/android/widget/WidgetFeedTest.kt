package app.floor.android.widget

import app.floor.android.Fixtures
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.model.Delegation
import app.floor.android.model.District
import app.floor.android.model.Member
import app.floor.android.model.MemberVote
import app.floor.android.model.MemberVotes
import app.floor.android.model.Chamber
import app.floor.android.model.VoteState
import app.floor.android.store.FollowKind
import app.floor.android.store.FollowState
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.CopyOnWriteArrayList

/** iOS `WidgetFeedTests` on the same recorded TX-37 records: what the two widgets show and say. */
class WidgetFeedTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val eastern = ZoneId.of("America/New_York")
    private val fetched = Instant.ofEpochSecond(1_794_528_000) // Nov 12, 7 PM in New York

    private val austin get() = Fixtures.decode("reps-location-austin", Delegation.serializer())

    private fun votes(name: String) = Fixtures.decode("member-votes-$name-40", MemberVotes.serializer()).votes

    private fun records(): MutableMap<String, List<MemberVote>> =
        mutableMapOf("D000399" to votes("doggett"), "C001056" to votes("cornyn"), "C001098" to votes("cruz"))

    private fun tx37(records: Map<String, List<MemberVote>> = records()) = WidgetSnapshot.make(WidgetMembers.of(austin), records, fetched)

    @Test
    fun smallShowsTheNewestFinalWithYourRepresentativesChip() {
        val final = tx37().latestFinal!!
        // House roll 321 closed at 19:43 UTC on Nov 11, after the Senate's 00:37 that morning.
        assertEquals("house-119-2-321", final.vote.id)
        assertEquals("H.R. 1013", final.measure?.citation)
        assertEquals("Doggett", final.call.member.lastName)
        assertEquals("NAY", WidgetText.chip(final.call.position, final.call.choice))
        assertEquals("PASSED", WidgetText.resultWord(final.vote))
        assertEquals(295, WidgetText.score(final.vote).first.value)
        assertEquals(128, WidgetText.score(final.vote).second?.value)
        assertEquals("Final · House", WidgetText.smallHeader(final.vote))
    }

    @Test
    fun aSharedSenateVoteGoesToTheFirstSenatorBySurname() {
        val only = records().apply { this["D000399"] = emptyList() }
        val final = tx37(only).latestFinal!!
        assertEquals("senate-119-2-258", final.vote.id)
        assertEquals("Cornyn", final.call.member.lastName)
        assertEquals("DNV", WidgetText.chip(final.call.position, null))
    }

    @Test
    fun mediumHasOneRowPerMemberRepresentativeFirst() {
        val snapshot = tx37()
        assertEquals(listOf("Doggett", "Cornyn", "Cruz"), snapshot.mediumRows.map { it.member.lastName })
        assertEquals("Your members · TX-37", WidgetText.header(snapshot))
        val lines = snapshot.mediumRows.map { row ->
            val latest = row.latest!!
            "${WidgetText.chip(latest.position, latest.choice)} ${row.member.lastName} ${WidgetText.detail(row)}"
        }
        // The mock's three rows, word for word.
        assertEquals(
            listOf("NAY Doggett H.R. 1013 · Passed 295–128", "DNV Cornyn H.R. 2347 · Agreed 62–21", "YEA Cruz H.R. 2347 · Agreed 62–21"),
            lines,
        )
    }

    @Test
    fun anOpenVoteIsAMembersLatestButNotTheLatestFinal() {
        val rows = records()
        val first = rows.getValue("D000399")[0]
        val open = first.copy(vote = first.vote.copy(id = "house-119-2-322", state = VoteState.OPEN, result = null, occurredAt = "2026-11-12T15:00:00.000Z"))
        rows["D000399"] = listOf(open) + rows.getValue("D000399")
        val snapshot = tx37(rows)
        assertEquals("house-119-2-321", snapshot.latestFinal?.vote?.id)
        assertEquals("house-119-2-322", snapshot.rows[0].latest?.vote?.id)
        assertEquals("Voting now", WidgetText.resultLine(snapshot.rows[0].latest!!.vote))
    }

    @Test
    fun aMemberWithNoVotesAndOneThatDidNotLoad() {
        val rows = records().apply {
            this["C001098"] = emptyList()
            remove("C001056")
        }
        val snapshot = tx37(rows)
        assertEquals("Cruz has no recorded votes yet.", WidgetText.rowLabel(snapshot.rows.first { it.member.lastName == "Cruz" }))
        val cornyn = snapshot.rows.first { it.member.lastName == "Cornyn" }
        assertTrue(cornyn.unavailable)
        assertEquals("Couldn't load their votes", WidgetText.detail(cornyn))
    }

    @Test
    fun nothingFinalMeansNoSmallVote() {
        val snapshot = tx37(emptyMap())
        assertNull(snapshot.latestFinal)
        assertTrue(snapshot.rows.all { it.latest == null })
    }

    @Test
    fun aSnapshotSaysHowOldItIsOnlyPastTwoHours() {
        assertNull(WidgetText.asOf(fetched, fetched.plusSeconds(60 * 60), eastern))
        assertNull(WidgetText.asOf(fetched, fetched.plusSeconds(2 * 60 * 60), eastern))
        assertEquals("As of 7:00 PM", WidgetText.asOf(fetched, fetched.plusSeconds(3 * 60 * 60 + 60), eastern))
        assertEquals("As of Nov 12", WidgetText.asOf(fetched, fetched.plusSeconds(30 * 60 * 60), eastern))
    }

    @Test
    fun headersForEveryShapeOfDelegation() {
        val tx = austin
        assertEquals("Your members · TX-37", WidgetText.header(tx.members, tx.district))
        val dc = Fixtures.decode("reps-location-dc", Delegation.serializer())
        assertEquals("Your delegate · DC", WidgetText.header(dc.members, dc.district))
        val pr = Member("H001103", "Pablo José", "Hernández", "D", "PR", 0, Chamber.HOUSE)
        assertEquals("Your resident commissioner · PR", WidgetText.header(listOf(pr), District(119, "PR", 0)))
        val wy = Fixtures.decode("reps-location-cheyenne", Delegation.serializer())
        assertEquals("Your members · WY-AL", WidgetText.header(wy.members, wy.district))
    }

    @Test
    fun aLoneDelegateSaysWhy() {
        val dc = Fixtures.decode("reps-location-dc", Delegation.serializer())
        val snapshot = WidgetSnapshot.make(WidgetMembers.of(dc), emptyMap(), fetched)
        assertEquals("District of Columbia has no senators. Delegates vote on amendments, not on passage.", WidgetText.loneMemberNote(snapshot))
        assertNull(WidgetText.loneMemberNote(tx37()))
    }

    @Test
    fun theSpokenLinesReadTheWholeCard() {
        val snapshot = tx37()
        assertEquals("Latest final, House. H.R. 1013. Passed, 295 to 128. Doggett voted nay.", WidgetText.smallLabel(snapshot.latestFinal!!))
        assertTrue(WidgetText.rowLabel(snapshot.rows[1], eastern).startsWith("Cornyn did not vote on H.R. 2347, Agreed 62 to 21, "))
    }

    @Test
    fun yourMembersAreYourRepsThenWhoYouFollowWithoutRepeatsAndHiddenWins() {
        val tx = austin
        val nadler = Member("N000002", "Jerrold", "Nadler", "D", "NY", 12, Chamber.HOUSE)
        val follows = FollowState()
            .follow(FollowKind.MEMBER, nadler.bioguideId, member = nadler)
            .follow(FollowKind.MEMBER, "C001098", member = tx.members.first { it.bioguideId == "C001098" })
            .setHidden("C001056", true)
        val who = WidgetMembers.of(tx, follows)
        assertEquals(listOf("Doggett", "Cruz"), who.reps.map { it.lastName })
        assertEquals(listOf("Doggett", "Cruz", "Nadler"), who.all.map { it.lastName })
        assertNull(who.district?.countyFips)
        // No district: the medium widget shows the first three you follow.
        val followedOnly = WidgetSnapshot.make(WidgetMembers.of(null, follows), emptyMap(), fetched)
        assertEquals(listOf("Cruz", "Nadler"), followedOnly.mediumRows.map { it.member.lastName })
        assertEquals("Your members", WidgetText.header(followedOnly))
    }

    // MARK: - Loading through the app's route and cache

    private val server = MockWebServer()
    private val paths = CopyOnWriteArrayList<String>()
    private var failing = setOf<String>()

    @Before
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                paths += request.target
                val id = request.target.removePrefix("/v1/members/").substringBefore('/')
                val name = mapOf("D000399" to "doggett", "C001056" to "cornyn", "C001098" to "cruz")[id]
                if (name == null || id in failing) return MockResponse.Builder().code(503).body("""{"error":"Down"}""").build()
                return MockResponse.Builder().code(200).body(Fixtures.text("member-votes-$name-40")).build()
            }
        }
        server.start()
    }

    @After
    fun stop() = server.close()

    private fun api() = FloorApi(server.url("/").toString(), cache = FileResponseCache(folder.root), now = { fetched })

    @Test
    fun asksEachMemberThroughTheAppsRouteAndCache() = runBlocking {
        val content = WidgetFeed.load(api(), WidgetMembers.of(austin), now = fetched) as WidgetContent.Loaded
        assertEquals("house-119-2-321", content.snapshot.latestFinal?.vote?.id)
        // The feed's own limit, so the widget and Finals read one saved response.
        assertEquals(
            setOf("/v1/members/D000399/votes?limit=25", "/v1/members/C001056/votes?limit=25", "/v1/members/C001098/votes?limit=25"),
            paths.toSet(),
        )
        // The API down, the same cache answers: the snapshot is what was saved, stamped when it was.
        failing = setOf("D000399", "C001056", "C001098")
        val offline = WidgetFeed.load(api(), WidgetMembers.of(austin), now = fetched.plusSeconds(4 * 3600))
        assertEquals(fetched, (offline as WidgetContent.Loaded).snapshot.fetchedAt)
    }

    @Test
    fun oneMemberFailingMarksTheirRowOnlyAndEveryoneFailingFails() = runBlocking {
        failing = setOf("C001056")
        val content = WidgetFeed.load(api(), WidgetMembers.of(austin), now = fetched) as WidgetContent.Loaded
        assertTrue(content.snapshot.rows.first { it.member.bioguideId == "C001056" }.unavailable)
        assertFalse(content.snapshot.rows.first { it.member.bioguideId == "D000399" }.unavailable)
        // Every member failing, with nothing saved: the load fails. (With the copies saved above, it wouldn't.)
        failing = setOf("D000399", "C001056", "C001098")
        val empty = FloorApi(server.url("/").toString(), cache = FileResponseCache(folder.newFolder()))
        assertEquals(WidgetContent.Failed, WidgetFeed.load(empty, WidgetMembers.of(austin), now = fetched))
        assertTrue(WidgetFeed.load(api(), WidgetMembers.of(austin), now = fetched) is WidgetContent.Loaded)
        assertEquals(WidgetContent.NoMembers, WidgetFeed.load(api(), WidgetMembers.of(null), now = fetched))
    }
}
