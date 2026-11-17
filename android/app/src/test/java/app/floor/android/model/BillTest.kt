package app.floor.android.model

import app.floor.android.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The Bills routes decode the real recorded responses in `ios/FloorKit/Tests/ModelsTests/Fixtures`,
 * and their words read as iOS's do. Robolectric for ICU, which formats the days.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class BillTest {
    private fun bill(name: String) = Fixtures.decode(name, Bill.serializer())

    @Test
    fun decodesEveryBillFixture() {
        for (name in listOf("bill", "bill-hr1013", "bill-hr5267", "bill-enacted", "bill-stuck-senate", "bill-no-short-title")) {
            val bill = bill(name)
            assertTrue(name, bill.citation.isNotEmpty())
        }
    }

    @Test
    fun hr5267IsTheAmericanFranchiseAct() {
        val bill = bill("bill-hr5267")
        assertEquals("119-hr-5267", bill.id)
        assertEquals("H.R. 5267", bill.citation)
        assertEquals(BillStage.INTRODUCED, bill.stage)
        assertEquals("American Franchise Act", bill.label)
        assertEquals("Labor and Employment", bill.policyArea)
        assertEquals("Rep. Kevin Hern (R-OK-1)", bill.sponsor?.sponsorLine)
        assertEquals(1, bill.cboEstimates.size)
        assertTrue(bill.votes.isEmpty())
        assertEquals("Sep 10, 2025", bill.introducedOn?.let { Formats.dayText(it) })
    }

    @Test
    fun hr1013HasItsHousePassage() {
        val bill = bill("bill-hr1013")
        assertEquals("Retirement Fairness for Charities and Educational Institutions Act of 2025", bill.displayTitle)
        assertNull(bill.stage)
        assertEquals(1, bill.votes.size)
        assertEquals(Chamber.HOUSE, bill.votes[0].chamber)
    }

    @Test
    fun anUnknownStageReadsAsNoStage() {
        val text = Fixtures.text("bill-hr5267").replace(Regex("\"stage\":\\s*\"introduced\""), "\"stage\": \"something_new\"")
        assertTrue(text.contains("something_new"))
        val bill = app.floor.android.api.FloorApi.json.decodeFromString(Bill.serializer(), text)
        assertNull(bill.stage)
    }

    @Test
    fun theShareLine() {
        val share = Fixtures.decode("bill-share-hr5267", BillShare.serializer())
        assertEquals("https://floor-web-seven.vercel.app/bill/119/hr/5267", share.url)
        assertTrue(share.text.startsWith("H.R. 5267 is up for a House vote"))
    }

    @Test
    fun theTopicsAreTheThirtyTwoInOrder() {
        val list = Fixtures.decode("topics", TopicList.serializer())
        assertEquals(Topic.names, list.topics.map { it.name })
        val agriculture = list.topics.first()
        assertEquals("195 bills · 4 with a floor vote · latest Oct 29", TopicText.detail(agriculture))
        assertEquals("Health", Topic.canonical("  health "))
        assertNull(Topic.canonical("Healthcare"))
    }

    @Test
    fun aTopicPage() {
        val page = Fixtures.decode("topic-bills-health", TopicBills.serializer())
        assertEquals("Health", page.topic.name)
        assertEquals(25, page.bills.size)
        assertNotNull(page.nextCursor)
        assertEquals("724 bills · 9 with a floor vote · latest Nov 12", TopicText.detail(page.topic))
        // Every row with a stage gets a chip, and its road matches its stage.
        for (bill in page.bills) {
            if (bill.stage != null) assertNotNull(bill.citation, bill.chip)
            assertEquals(bill.stage?.roadSteps, bill.roadSteps)
        }
        val law = page.bills.first { it.citation == "H.R. 1703" }
        assertEquals(StageChip("LAW", StageChip.Tone.LAW), law.chip)
        assertEquals("Became Public Law No: 119-140. · Nov 10", law.latestStep)
        assertEquals(StageChip("IN COMMITTEE", StageChip.Tone.NEUTRAL), page.bills.first().chip)
        assertEquals(StageChip("ADOPTED", StageChip.Tone.LAW), page.bills.first { it.citation == "S.Res. 951" }.chip)
    }

    @Test
    fun searchByNumberAndByWords() {
        val number = Fixtures.decode("search-hr1013", SearchResults.serializer())
        assertTrue(number.billNumber)
        assertEquals(listOf("H.R. 1013"), number.bills.map { it.citation })
        val words = Fixtures.decode("search-rural-health", SearchResults.serializer())
        assertFalse(words.billNumber)
        assertEquals(20, words.bills.size)
        val members = Fixtures.decode("search-michigan-senate", SearchResults.serializer())
        assertEquals(2, members.members.size)
        val none = Fixtures.decode("search-pending-sample", SearchResults.serializer())
        assertTrue(none.bills.isEmpty() && none.topics.isEmpty())
    }

    @Test
    fun theAnalysisFixture() {
        val analysis = Fixtures.decode("bill-analysis", BillAnalysis.serializer())
        assertEquals("118-hr-6363", analysis.billId)
        assertEquals("Public Law", analysis.source.stage)
        assertEquals("The act continues FY2024 funding for federal agencies.", analysis.purpose?.text)
        assertEquals(2, analysis.provisions.size)
        assertTrue(analysis.disclaimer.contains("may contain errors"))
    }

    @Test
    fun theScheduleListsHr5267UnderARule() {
        val schedule = Fixtures.decode("schedule-2026-11-16", Schedule.serializer())
        assertEquals("2026-11-16", schedule.week)
        val (chamber, item) = schedule.listing("119-hr-5267")!!
        assertEquals(Chamber.HOUSE, chamber)
        assertEquals(ScheduleCategory.RULE, item.category)
        assertEquals(Chamber.SENATE, schedule.listing("119-hr-2347")?.first)
        assertNull(schedule.listing("119-hr-1013"))
    }

    @Test
    fun aDistrictAndItsMembers() {
        val austin = Fixtures.decode("reps-location-austin", Delegation.serializer())
        assertEquals(District(119, "TX", 37), austin.district)
        assertEquals(listOf("Doggett", "Cornyn", "Cruz"), austin.members.map { it.lastName })
        val doggett = austin.members[0]
        assertEquals("Representative", doggett.title)
        assertEquals("Rep. Doggett", doggett.shortName)
        assertEquals("Texas' 37th District", StateName.districtName("TX", 37))
        assertEquals("the District of Columbia", StateName.inSentence("DC"))
        assertEquals("119th", StateName.ordinal(119))
        assertEquals("21st", StateName.ordinal(21))
        assertEquals("112th", StateName.ordinal(112))
    }

    @Test
    fun anOfficeContact() {
        val doggett = Fixtures.decode("member-detail-doggett", MemberDetail.serializer())
        assertEquals("202-225-4865", doggett.contact?.phone)
        assertNull(doggett.contact?.contactForm)
        val cornyn = Fixtures.decode("member-detail-cornyn", MemberDetail.serializer())
        assertEquals("https://www.cornyn.senate.gov/contact", cornyn.contact?.contactForm)
    }

    @Test
    fun stageChipsFromTheLatestAction() {
        fun chip(stage: BillStage?, action: String) = StageChip.of(stage, LatestAction("2026-11-12", action))
        assertEquals(
            "VOTE FAILED",
            chip(null, "Cloture on the motion to proceed to the measure not invoked in Senate by Yea-Nay Vote. 51 - 48.")?.text,
        )
        // A failed motion to recommit is the bill surviving, not failing.
        assertEquals("IN COMMITTEE", chip(BillStage.INTRODUCED, "Motion to recommit failed; referred to the Committee on Ways and Means.")?.text)
        assertEquals("SENATE CALENDAR", chip(BillStage.PASSED_HOUSE, "Placed on Senate Legislative Calendar under General Orders.")?.text)
        assertNull(StageChip.of(null, null))
    }
}
