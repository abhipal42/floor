package app.floor.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS `FloorLinkTests`, case for case: the same links in, the same answers out. */
class FloorLinkTest {
    @Test
    fun aVoteLinkRoundTrips() {
        val link = FloorLink.Vote("house-119-2-321")
        assertEquals("floor://vote/house-119-2-321", link.url)
        assertEquals(link, FloorLink.parse(link.url))
        assertEquals(FloorLink.Vote("senate-119-2-258"), FloorLink.parse(FloorLink.Vote("senate-119-2-258").url))
    }

    @Test
    fun theOpenLinkRoundTrips() {
        assertEquals("floor://open", FloorLink.Open.url)
        assertEquals(FloorLink.Open, FloorLink.parse(FloorLink.Open.url))
    }

    /** Any app can send the activity a link, so only the roll call id shape gets through. */
    @Test
    fun onlyRollCallIdsAreAccepted() {
        for (url in listOf(
            "floor://vote/house-119-2-321%2F..", "floor://vote/..%2Fstatus", "floor://vote/house-119-2",
            "floor://vote/house-119-2-321-1", "floor://vote/Senate-119-2-258", "floor://vote/house-119-2-x",
            "floor://vote/house-%D9%A1%D9%A1%D9%A9-2-321", // Arabic-Indic digits
            "floor://vote/house-119-2-321%20", "floor://vote/joint-119-2-1", "floor://vote/house--2-321",
        )) {
            assertNull(url, FloorLink.parse(url))
        }
        assertFalse(FloorLink.isVoteId("house-١١٩-2-321"))
        assertTrue(FloorLink.isVoteId("house-119-2-321"))
        // An invalid id never builds a link that opens a vote.
        assertNull(FloorLink.parse(FloorLink.Vote("../status").url))
    }

    @Test
    fun rejectsLinksThatAreNotOurs() {
        for (url in listOf(
            "https://floor-web-seven.vercel.app/vote/house-119-2-321", "floor://vote", "floor://vote/", "floor://bill/119-pn-1013",
            "floor://vote/a/b", "floor://vote/house-119-2-321/", "floor://vote//house-119-2-321",
        )) {
            assertNull(url, FloorLink.parse(url))
        }
    }

    @Test
    fun aBillLinkRoundTrips() {
        val link = FloorLink.Bill("119-hr-1013")
        assertEquals("floor://bill/119-hr-1013", link.url)
        assertEquals(link, FloorLink.parse(link.url))
        assertEquals(FloorLink.Bill("119-sconres-7"), FloorLink.parse(FloorLink.Bill("119-sconres-7").url))
    }

    /** The share page's link opens the bill screen when Android hands it to the app. */
    @Test
    fun theShareLinkOpensTheBill() {
        assertEquals(FloorLink.Bill("119-hr-5267"), FloorLink.parse("https://floor-web-seven.vercel.app/bill/119/hr/5267"))
        assertEquals(FloorLink.Bill("119-s-2"), FloorLink.parse("https://${FloorLink.SHARE_HOST}/bill/119/s/2"))
        for (url in listOf(
            "https://floor-web-seven.vercel.app/bill/119/hr/5267/card.png", "https://floor-web-seven.vercel.app/bill/119/HR/5267",
            "https://floor-web-seven.vercel.app/bill/119/hr", "https://evil.example/bill/119/hr/5267", "https://floor.app/bill/119/hr/5267",
            "http://floor-web-seven.vercel.app/bill/119/hr/5267", "https://floor-web-seven.vercel.app/bill/119/hr/05267",
            "https://floor-web-seven.vercel.app/bill/119/hr/5267%2F..", "floor://bill/119-hr-", "floor://bill/1-hr-1", "floor://bill/119-hr-1/x",
        )) {
            assertNull(url, FloorLink.parse(url))
        }
        assertNull(FloorLink.parse(FloorLink.Bill("../status").url))
    }

    @Test
    fun theSchemeIsCaseInsensitive() {
        assertEquals(FloorLink.Vote("house-119-2-321"), FloorLink.parse("FLOOR://vote/house-119-2-321"))
    }

    /** Not a URL at all is no link, rather than a crash. */
    @Test
    fun aMalformedUrlIsRefused() {
        assertNull(FloorLink.parse("floor://vote/house 119"))
        assertNull(FloorLink.parse("floor://vote/%ZZ"))
    }
}
