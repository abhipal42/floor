package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import app.floor.android.onboarding.OnboardingState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.ZoneId
import java.util.Locale

/**
 * The members half of the contract, decoded from the recorded responses the iOS tests use, and the
 * arithmetic and words the member, elect and onboarding screens print (ported from iOS
 * `RecordStatsTests`, `FundingTests`, `DisclosuresTests`, `MembersElectTests`). Robolectric for ICU's dates.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class MembersTest {
    private val eastern = ZoneId.of("America/New_York")
    private val us = Locale.US

    private fun votes(name: String) = Fixtures.decode(name, MemberVotes.serializer()).votes

    private val doggett = Member("D000399", "Lloyd", "Doggett", "D", "TX", 37, Chamber.HOUSE)

    // MARK: Members

    @Test
    fun readsEveryMemberDetail() {
        for (name in listOf("member-detail", "member-detail-cornyn", "member-detail-cruz", "member-detail-doggett", "member-detail-nadler")) {
            val detail = Fixtures.decode(name, MemberDetail.serializer())
            assertTrue(name, detail.partyLoyalty.votes >= 0)
        }
        val cruz = Fixtures.decode("member-detail-cruz", MemberDetail.serializer())
        assertEquals(1433.0 / 1501, cruz.partyLoyalty.withPartyShare!!, 1e-9)
        assertEquals(Tier.STARTER, Tier.of(cruz.partyLoyalty.againstParty))
        assertNull(PartyLoyalty(0, 0, 0).withPartyShare)
        val doggett = Fixtures.decode("member-detail-doggett", MemberDetail.serializer())
        assertEquals("202-225-4865", doggett.contact?.phone)
        assertNull(doggett.contact?.contactForm)
        assertEquals("House · Texas 37th · D", doggett.member.seatLine)
        assertEquals("U.S. Representative · D-TX-37", doggett.member.roleLine)
        assertEquals("House · TX-37", doggett.member.seatCaption)
    }

    @Test
    fun tiersFromCrossovers() {
        assertEquals(Tier.STARTER, Tier.of(299))
        assertEquals(Tier.SWING, Tier.of(300))
        assertEquals(Tier.SWING, Tier.of(399))
        assertEquals(Tier.MAVERICK, Tier.of(400))
    }

    @Test
    fun theLastFortyCalls() {
        val stats = RecordStats(votes("member-votes-doggett-40"))
        assertEquals(40, stats.calls.size)
        assertEquals(2, stats.missed)
        assertEquals(0, stats.present)
        assertEquals(38, stats.showedUp)
        assertEquals(38, stats.decided)
        assertEquals(19, stats.sidedWithOutcome)
        assertEquals("H.R. 1013", stats.calls.last().measure?.citation)
        assertEquals("H.Con.Res. 89", stats.calls.first().measure?.citation)
        val cruz = RecordStats(votes("member-votes-cruz-40"))
        assertEquals(0, cruz.missed)
        assertEquals(40, cruz.decided)
        assertEquals(36, cruz.sidedWithOutcome)
        assertEquals(40, votes("member-votes-cornyn-40").size)
        assertTrue(votes("member-votes").isNotEmpty())
    }

    @Test
    fun didYouKnow() {
        assertEquals(
            "16 of Doggett's last 40 calls came up under suspension, the two-thirds fast lane. Doggett voted yea on 13, nay on 1, and missed 2.",
            RecordFacts.didYouKnow(doggett, votes("member-votes-doggett-40"), eastern),
        )
        val cornyn = Member("C001056", "John", "Cornyn", "R", "TX", null, Chamber.SENATE)
        assertEquals("Cornyn missed 4 of their last 40 calls.", RecordFacts.didYouKnow(cornyn, votes("member-votes-cornyn-40"), eastern))
        val cruz = Member("C001098", "Ted", "Cruz", "R", "TX", null, Chamber.SENATE)
        assertEquals("Cruz cast a vote on every one of their last 40 calls.", RecordFacts.didYouKnow(cruz, votes("member-votes-cruz-40"), eastern))
    }

    // MARK: Money

    @Test
    fun readsEveryFunding() {
        for (id in listOf("A000383", "C001056", "C001098", "D000399", "J000294")) {
            val body = Fixtures.decode("funding-$id", MemberFunding.serializer())
            assertEquals(id, body.member.bioguideId)
        }
        val doggett = Fixtures.decode("funding-D000399", MemberFunding.serializer()).funding!!
        assertEquals("2026 campaign · Jan 2025 – Sep 30, 2026", doggett.period)
        assertTrue(doggett.pacChecks().all { it.direct > 0 })
        // Every PAC is a committee; no individual donor's name is in the response at all.
        assertTrue(doggett.committees.all { it.committeeId.startsWith("C") })
    }

    @Test
    fun moneyAsTheLandingPagePrintsIt() {
        assertEquals("$17.9M", MoneyFormat.total(17_893_352.0))
        assertEquals("$4.23M", MoneyFormat.total(4_234_848.0))
        assertEquals("$884K", MoneyFormat.total(884_398.0))
        assertEquals("$1.00M", MoneyFormat.total(999_500.0))
        assertEquals("$999K", MoneyFormat.total(999_499.0))
        assertEquals("$10.0M", MoneyFormat.total(9_996_000.0))
        assertEquals("$9.96M", MoneyFormat.total(9_960_000.0))
        assertEquals("−$12K", MoneyFormat.total(-12_000.0))
        assertEquals("−$1.23M", MoneyFormat.total(-1_234_567.0))
        assertEquals("17.9 million dollars", MoneyFormat.spoken(17_893_352.0))
        assertEquals("minus 12 thousand dollars", MoneyFormat.spoken(-12_000.0))
        assertEquals("$10K", MoneyFormat.check(10_000.0))
        assertEquals("$2.5K", MoneyFormat.check(2_500.0))
        assertEquals("$750", MoneyFormat.check(750.0))
        assertEquals("2025–26", FundingDates.cycleYears(2026))
    }

    @Test
    fun committeeNamesInTitleCase() {
        listOf(
            "MOTOROLA SOLUTIONS, INC. POLITICAL ACTION COMMITTEE" to "Motorola Solutions, Inc. PAC",
            "EXXON MOBIL CORPORATION POLITICAL ACTION COMMITTEE (EXXONMOBIL PAC)" to "Exxon Mobil Corporation PAC",
            "AMERICAN FEDERATION OF STATE COUNTY & MUNICIPAL EMPLOYEES  P E O P L E" to "American Federation of State County & Municipal Employees PEOPLE",
            "AMERICAN FEDERATION OF TEACHERS, AFL-CIO COMMITTEE ON POLITICAL EDUCATION" to "American Federation of Teachers, AFL-CIO Committee on Political Education",
            "SOUTHERN GLAZER'S WINE AND SPIRITS PAC" to "Southern Glazer's Wine and Spirits PAC",
            "TRANSPORTATION INTERMEDIARIES ASSOCIATION'S TIAPAC" to "Transportation Intermediaries Association's TIAPAC",
            "L3HARRIS TECHNOLOGIES, INC. PAC" to "L3HARRIS Technologies, Inc. PAC",
            "PERATON CORP. POLITICAL ACTION COMMITTEE (A.K.A. 'PERATON PAC')" to "Peraton Corp. PAC",
            "FRIENDS OF JOHN O'BRIEN" to "Friends of John O'Brien",
            "D'AMATO FOR SENATE" to "D'Amato for Senate",
            "LYNN FOR CONGRESS" to "Lynn for Congress",
        ).forEach { (raw, want) -> assertEquals(want, CommitteeName.display(raw)) }
    }

    // MARK: Disclosures

    @Test
    fun readsTheDisclosuresOnOffAndTranscribed() {
        val doggett = Fixtures.decode("disclosures-doggett", Disclosures.serializer())
        assertTrue(doggett.enabled)
        assertEquals(75, doggett.annual?.assets?.size)
        assertEquals(11, doggett.trades.size)
        assertEquals(5, doggett.paperFilings.size)
        assertFalse(doggett.annual!!.transcribed)
        assertEquals(45, doggett.deadline)
        assertTrue(Fixtures.decode("disclosures-nadler", Disclosures.serializer()).annual!!.transcribed)
        val off = Fixtures.decode("disclosures-off", Disclosures.serializer())
        assertFalse(off.enabled)
        assertTrue(off.reason!!.contains("13107"))
        // An API without the route reads as off with no reason.
        val missing = FloorApi.json.decodeFromString(Disclosures.serializer(), Disclosures.UNAVAILABLE_BODY)
        assertFalse(missing.enabled)
        assertNull(missing.reason)
    }

    @Test
    fun aTradeRowThisBuildCannotReadIsDroppedAlone() {
        val body = """{"enabled":true,"trades":[{"asset":"Coca-Cola Company (KO)","type":"buy"},{"type":"sell"}],"paperFilings":"nonsense"}"""
        val read = FloorApi.json.decodeFromString(Disclosures.serializer(), body)
        assertEquals(1, read.trades.size)
        assertEquals("Bought", read.trades[0].verb)
        assertTrue(read.paperFilings.isEmpty())
    }

    // MARK: Members-elect

    @Test
    fun readsTheElects() {
        val profile = Fixtures.decode("member-elect-mi-sen", ElectProfile.serializer())
        assertEquals("El-Sayed", profile.elect.lastName)
        assertEquals("Senator-elect", profile.elect.title)
        assertEquals(53_830_872.0, profile.funding?.receipts)
        assertNull(profile.disclosure)
        val mi = Fixtures.decode("members-elect-mi", MembersElect.serializer())
        assertEquals(1, mi.elect.size)
        assertTrue(mi.seats("MI", 12).elect.isNotEmpty())
        assertTrue(mi.seats("OH", 1).elect.isEmpty())
        val search = Fixtures.decode("members-search-michigan-senate", MemberSearch.serializer())
        assertEquals("2027-01-03", search.members.first { it.lastName == "Peters" }.leavingOn)
        val pending = Fixtures.decode("members-search-pending-sample", MemberSearch.serializer())
        assertEquals(listOf(true, false), pending.pending.map { it.isRunoff })
        for (name in listOf("search-michigan-senate", "search-pending-sample")) Fixtures.decode(name, SearchResults.serializer())
    }

    @Test
    fun theElectSitsUnderTheMemberLeaving() {
        val search = Fixtures.decode("members-search-michigan-senate", MemberSearch.serializer())
        val rows = SeatRow.rows(search.members, search.elect, search.pending)
        val peters = rows.indexOfFirst { it is SeatRow.Sitting && it.member.lastName == "Peters" }
        assertTrue(rows[peters + 1] is SeatRow.Elect)
        assertTrue(SeatRow.changing(rows))
        assertFalse(SeatRow.changing(listOf(SeatRow.Sitting(doggett, null))))
    }

    @Test
    fun electWords() {
        assertEquals("Jan 3, 2027", ElectText.day("2027-01-03", us))
        assertEquals("3 Jan 2027", ElectText.day("2027-01-03", Locale.UK))
        assertEquals("2026-11-03", ElectText.electionDay(2026))
        assertEquals("2024-11-05", ElectText.electionDay(2024))
        assertEquals("2022-11-08", ElectText.electionDay(2022))
        assertEquals(120, ElectText.congress("2027-01-03"))
        val elect = Fixtures.decode("member-elect-mi-sen", ElectProfile.serializer()).elect
        assertEquals("Race called by AP on Nov 4. Floor shows the call, it doesn't make one.", ElectText.callLine(elect.call, us))
        assertEquals("Listed by the House Clerk. Floor shows the list, it doesn't make one.", ElectText.callLine(ElectCall("House Clerk"), us))
        assertEquals("Senator-elect · takes office Jan 3", ElectText.electCaption(elect, us))
        assertEquals("Michigan's Senate seat", ElectText.seatName("MI", null, Chamber.SENATE))
        val runoff = Fixtures.decode("members-search-pending-sample", MemberSearch.serializer()).pending[0]
        assertEquals("Runoff Dec 12" to "Louisiana's 5th District: no winner yet. This seat fills in when the race is decided.", ElectText.pending(runoff, us))
    }

    // MARK: Your district

    @Test
    fun readsEveryRepsLookup() {
        val austin = Fixtures.decode("reps-location-austin", Reps.serializer())
        assertEquals("TX-37", austin.district.name)
        assertEquals(2, austin.senators.size)
        val dc = Fixtures.decode("reps-location-dc", Reps.serializer())
        assertEquals("DC", dc.district.name)
        assertEquals(
            "One, not three: D.C. has a delegate in the House and no senators. A delegate can’t vote to pass a bill, so Norton’s record is amendment votes.",
            OnboardingState.singleMemberNote(dc),
        )
        assertNull(OnboardingState.singleMemberNote(austin))
        Fixtures.decode("reps-location-cheyenne", Reps.serializer())
        // The delegation kept on the phone is the district and its members, never the address.
        val kept = Delegation.of(austin, 42)
        val json = FloorApi.json.encodeToString(Delegation.serializer(), kept)
        assertFalse(json.contains("address"))
        assertEquals(kept, FloorApi.json.decodeFromString(Delegation.serializer(), json))
    }

    @Test
    fun coordinatesAreRoundedToFourPlaces() {
        assertEquals("30.2747", FloorApi.coordinate(30.274_712_9))
        assertEquals("-97.7404", FloorApi.coordinate(-97.740_35))
    }
}
