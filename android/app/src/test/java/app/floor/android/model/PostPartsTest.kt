package app.floor.android.model

import app.floor.android.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/** The rebuilt post card's parts, on NY-12's real posts of Nov 13-17, 2026 (`arena-wall-ny`). */
class PostPartsTest {
    private val wall = Fixtures.decode("arena-wall-ny", PostsWall.serializer()).shown
    private val eastern = ZoneId.of("America/New_York")
    private val utc = ZoneId.of("UTC")
    private val now = Instant.parse("2026-11-17T23:00:00Z")

    private fun post(text: String?, media: String? = null, network: String = "bluesky", url: String = "https://bsky.app/profile/nadler.house.gov/post/x") =
        Post(id = "t", network = network, postedAt = "2026-11-13T20:34:16Z", text = text, url = url, mediaUrl = media)

    @Test
    fun aLinkCardNeedsAUrlInTheTextAndAnImage() {
        val ai = wall.first { it.text.orEmpty().contains("Stolen Intelligence") }
        val link = PostParts.link(ai)!!
        assertEquals("billboard.com", link.domain)
        assertEquals("billboard.com/pro/congress…", link.path)
        assertEquals("Trump calls Artificial Intelligence \"Super Intelligence\". In reality, a more accurate name would be \"Stolen Intelligence.\"", link.textWithout)
        // The same text with no image is just text; a photo with no URL is a photo.
        assertNull(PostParts.link(post(ai.text)))
        assertNull(PostParts.link(post("Proud to have voted to pass this monumental bill.", media = "https://cdn.bsky.app/x")))
        // "U.S." and "e.g." are not links.
        assertNull(PostParts.link(post("The U.S. Senate, e.g. today.", media = "https://cdn.bsky.app/x")))
        assertEquals("example.org", PostParts.link(post("Read https://www.example.org/a/b", media = "https://cdn.bsky.app/x"))!!.domain)
        // A YouTube video's title is never a link card.
        assertNull(PostParts.link(post("www.example.org/a", media = "https://i3.ytimg.com/vi/x/hqdefault.jpg", network = "youtube")))
    }

    @Test
    fun onlyTheLiteralThreadPatternsCount() {
        val education = wall.first { it.text.orEmpty().startsWith("We must invest in public education") }
        assertEquals("Thread · 2 posts", PostParts.thread(education))
        assertEquals("Thread", PostParts.thread(post("A long story 1/")))
        assertNull(PostParts.thread(post("Votes went 2/3 in favour (2/2)")))
        assertNull(PostParts.thread(post("Turnout was 1/3 of voters.")))
        assertNull(PostParts.thread(post(null)))
    }

    @Test
    fun theHandleIsTheAccountsElseWhatTheLinkNames() {
        val schumer = Fixtures.decode("arena-schumer-detail", MemberDetail.serializer()).accounts
        val yt = wall.first { it.socialNetwork == SocialNetwork.YOUTUBE && it.memberId == "S000148" }
        assertEquals("@SenatorSchumer", PostParts.handle(yt, schumer))
        val bluesky = wall.first { it.socialNetwork == SocialNetwork.BLUESKY && it.memberId == "N000002" }
        assertEquals("@nadler.house.gov", PostParts.handle(bluesky))
        // A YouTube watch link names no channel, so the wall shows no handle for it.
        assertNull(PostParts.handle(yt))
        assertEquals("@floor", PostParts.handle(post("x", network = "mastodon", url = "https://mastodon.social/@floor/1")))
    }

    @Test
    fun timesAndDaysAreTheReadersOwn() {
        val newest = wall.first()
        assertEquals("5:21 PM", PostParts.time(newest, now, eastern, Locale.US))
        // In UTC the same post is the next day's, and "now" is still the 17th there, so it is today too.
        assertEquals("10:21 PM", PostParts.time(newest, now, utc, Locale.US))
        val older = wall.last()
        assertEquals("Nov 13 · 12:12 PM", PostParts.time(older, now, eastern, Locale.US))
        val today = LocalDate.of(2026, 11, 17)
        assertEquals("Today", PostParts.day(today, today, Locale.US))
        assertEquals("Yesterday", PostParts.day(today.minusDays(1), today, Locale.US))
        assertEquals("Fri, Nov 13", PostParts.day(LocalDate.of(2026, 11, 13), today, Locale.US))
        assertEquals(listOf("Today", "Yesterday", "Sun, Nov 15", "Sat, Nov 14", "Fri, Nov 13"), PostParts.byDay(wall, now, eastern, Locale.US).map { it.first })
    }
}
