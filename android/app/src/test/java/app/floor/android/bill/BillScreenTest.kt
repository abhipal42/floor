package app.floor.android.bill

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import app.floor.android.model.Bill
import app.floor.android.model.BillAnalysis
import app.floor.android.model.BillShare
import app.floor.android.model.Delegation
import app.floor.android.model.MemberContact
import app.floor.android.model.Schedule
import app.floor.android.model.VoteThreshold
import kotlinx.serialization.builtins.nullable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The bill screen's words, from the real fixtures: iOS's `LawLevelsTests`, `SpeakUpTests` and the analysis rules. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class BillScreenTest {
    private fun bill(name: String) = Fixtures.decode(name, Bill.serializer())

    // MARK: - Six levels to law

    /** H.R. 9340: 417–3 in the House under suspension, then a Senate cloture three short of sixty. */
    @Test
    fun stopsAtTheSixty() {
        val levels = LawLevels(bill("bill-stuck-senate"))
        assertEquals(LawLevels.NAMES, levels.levels.map { it.name })
        assertEquals(
            listOf(LawLevels.State.DONE, LawLevels.State.DONE, LawLevels.State.DONE, LawLevels.State.STUCK, LawLevels.State.PENDING, LawLevels.State.PENDING),
            levels.levels.map { it.state },
        )
        assertEquals(listOf(false, false, true, true, false, true), levels.levels.map { it.boss })
        assertEquals(3, levels.reached)
        assertEquals("STOPPED AT THE 60", levels.status)
        assertEquals("H.R. 9340 is stuck in the Senate.", levels.sentence)
        assertEquals("senate-119-2-254", levels.stoppedBy?.id)
    }

    @Test
    fun climbsAllSixToLaw() {
        val levels = LawLevels(bill("bill-enacted"))
        assertTrue(levels.levels.all { it.state == LawLevels.State.DONE })
        assertEquals(listOf(false, false, false, true, false, true), levels.levels.map { it.boss })
        assertEquals(6, levels.reached)
        assertEquals("LAW", levels.status)
    }

    @Test
    fun adoptsAConcurrentResolutionWithNoSignature() {
        val levels = LawLevels(bill("bill"))
        assertEquals(LawLevels.State.NOT_APPLICABLE, levels.levels[5].state)
        assertTrue(levels.levels.take(5).all { it.state == LawLevels.State.DONE })
        assertEquals("ADOPTED", levels.status)
        assertEquals("H.Con.Res. 14 was adopted.", levels.sentence)
    }

    @Test
    fun marksTheChamberThatRejectedIt() {
        val levels = LawLevels(bill("bill-no-short-title"))
        assertEquals(LawLevels.State.FAILED, levels.levels[2].state)
        assertEquals("FAILED IN THE HOUSE", levels.status)
        assertEquals("H.Con.Res. 21 failed in the House.", levels.sentence)
    }

    @Test
    fun saysWhatIsNextForABillHalfwayThere() {
        val stuck = bill("bill-stuck-senate")
        val halfway = stuck.copy(votes = stuck.votes.filter { it.chamber != app.floor.android.model.Chamber.SENATE })
        val levels = LawLevels(halfway)
        assertEquals(LawLevels.State.PENDING, levels.levels[3].state)
        assertEquals("LEVEL 3 OF 6", levels.status)
        assertEquals("H.R. 9340 passed the House. Next: the Senate.", levels.sentence)
    }

    @Test
    fun aFailedAmendmentDoesNotStickTheBill() {
        val stuck = bill("bill-stuck-senate")
        val pending = stuck.copy(
            votes = stuck.votes.map {
                if (it.chamber == app.floor.android.model.Chamber.SENATE) it.copy(question = "On the Amendment", threshold = VoteThreshold.MAJORITY) else it
            },
        )
        assertEquals(LawLevels.State.PENDING, LawLevels(pending).levels[3].state)
    }

    /** The two bills the screenshots draw: H.R. 5267 waits in committee, H.R. 1013 passed the House. */
    @Test
    fun theScreenshotBills() {
        assertEquals("LEVEL 2 OF 6", LawLevels(bill("bill-hr5267")).status)
        val hr1013 = LawLevels(bill("bill-hr1013"))
        assertEquals("LEVEL 3 OF 6", hr1013.status)
        assertEquals("H.R. 1013 passed the House. Next: the Senate.", hr1013.sentence)
    }

    @Test
    fun describesEachKeyPlay() {
        val plays = bill("bill-stuck-senate").votes.map { it.playDescription }
        assertTrue(plays.toString(), plays.any { it.startsWith("Senate cloture, 60 needed — 3 short") })
    }

    // MARK: - AI analysis

    @Test
    fun everyShownLineIsCitedToAParagraphThatHoldsItsQuote() {
        val response = Fixtures.decode("bill-analysis", BillAnalysis.serializer())
        val shown = AIAnalysis.of(response)
        assertEquals(listOf("What it does", "What it changes", "Who it touches"), shown.groups.map { it.heading })
        for (citation in shown.citations) {
            assertEquals(response.source.paragraphs[citation.paragraph - 1], citation.source)
        }
        val sec101 = shown.citations.first { it.section != null }
        assertEquals("CRS ¶5 · Sec. 101", sec101.label)
        assertEquals("CRS SUMMARY · ¶5 · PUBLIC LAW", shown.sourceLabel(sec101))
        assertEquals(response.disclaimer, shown.disclaimer)
        assertEquals(
            "AI-written: The act continues FY2024 funding for federal agencies, cited from CRS paragraph 2",
            shown.groups[0].lines[0].spoken,
        )
    }

    @Test
    fun aLineWhoseQuoteIsNotInItsParagraphIsCut() {
        val response = Fixtures.decode("bill-analysis", BillAnalysis.serializer())
        val purpose = response.purpose!!
        val forged = response.copy(purpose = purpose.copy(citations = purpose.citations.map { it.copy(quote = "words CRS never wrote") }))
        assertFalse(AIAnalysis.of(forged).groups.any { it.id == "purpose" })
        // Out of range is cut too.
        val outOfRange = response.copy(purpose = purpose.copy(citations = purpose.citations.map { it.copy(paragraph = 999) }))
        assertFalse(AIAnalysis.of(outOfRange).groups.any { it.id == "purpose" })
    }

    @Test
    fun quotesCompareAsTheWorkerNormalizes() {
        assertTrue(AIAnalysis.quoteIsIn("…continuing  FY2024 appropriations.", "This section provides continuing FY2024 appropriations for agencies."))
        assertTrue(AIAnalysis.quoteIsIn("the “act” — now", "The \"Act\" - now in force"))
        assertFalse(AIAnalysis.quoteIsIn("...", "Anything"))
    }

    @Test
    fun noAnalysisIsHiddenWithASummaryAndSaysSoWithout() {
        val hr5267 = bill("bill-hr5267")
        assertEquals(AnalysisPhase.Hidden, AnalysisPhase.of(hr5267, null))
        assertEquals(AnalysisPhase.NoSummary, AnalysisPhase.of(hr5267.copy(summary = " "), null))
    }

    // MARK: - Speak up and Share

    private val austin get() = Fixtures.decode("reps-location-austin", Delegation.serializer())

    private fun scheduledFacts(): BillFacts {
        val bill = bill("bill-hr5267")
        val schedule = Fixtures.decode("schedule-2026-11-16", Schedule.serializer())
        return BillFacts.of(bill, FloorListing.of(schedule, bill.id)!!)
    }

    @Test
    fun theMockMessageForDoggett() {
        val doggett = austin.members.first { it.lastName == "Doggett" }
        val text = SpeakUpTemplate.message(doggett, austin.district, scheduledFacts(), Stance.HOW_WILL_YOU_VOTE)
        assertEquals(
            """
            Dear Representative Doggett,

            I live in Texas' 37th District. H.R. 5267, the American Franchise Act, is scheduled for a House vote the week of November 16. How do you plan to vote, and why?

            [Add your own words (optional)]

            [Your name and address go in the office's form]
            """.trimIndent(),
            text,
        )
    }

    @Test
    fun aSenatorIsWrittenToAsOneAndLivesInTheState() {
        val cornyn = austin.members.first { it.lastName == "Cornyn" }
        val text = SpeakUpTemplate.message(cornyn, austin.district, scheduledFacts(), Stance.SUPPORT)
        assertTrue(text.startsWith("Dear Senator Cornyn,\n\nI live in Texas. H.R. 5267"))
        assertTrue(text.contains("I support it."))
        assertFalse(text.contains("District"))
    }

    @Test
    fun changingTheStanceKeepsTheEdits() {
        val doggett = austin.members.first()
        val original = SpeakUpTemplate.message(doggett, austin.district, scheduledFacts(), Stance.SUPPORT)
        val edited = original.replace(SpeakUpTemplate.OWN_WORDS, "My family runs a franchise.")
        val swapped = SpeakUpTemplate.restanced(edited, Stance.SUPPORT, Stance.OPPOSE)!!
        assertTrue(swapped.contains("I oppose it."))
        assertFalse(swapped.contains("I support it."))
        assertTrue(swapped.contains("My family runs a franchise."))
        assertNull(SpeakUpTemplate.restanced("Dear Rep, hello", Stance.SUPPORT, Stance.OPPOSE))
    }

    @Test
    fun aDescriptiveTitleIsNotReadAsAName() {
        val bill = bill("bill-hr5267").copy(
            id = "119-hr-7254", number = 7254, citation = "H.R. 7254", shortTitle = null,
            title = "To amend the National Trails System Act to direct the Secretary of the Interior to conduct a study",
        )
        val facts = BillFacts.of(bill, null)
        assertNull(facts.name)
        assertEquals("H.R. 7254 was introduced in the House.", facts.sentence)
    }

    @Test
    fun theCallScriptReadsTheSameFacts() {
        val cornyn = austin.members.first { it.lastName == "Cornyn" }
        val none = SpeakUpTemplate.callScript(cornyn, austin.district, scheduledFacts(), null)
        assertEquals(4, none.size)
        assertEquals("\"Hi, I'm a constituent from [your city], Texas.\"", none[0])
        assertEquals(
            "\"I'm calling about H.R. 5267, the American Franchise Act. It is scheduled for a House vote the week of November 16.\"",
            none[1],
        )
        assertTrue(none[2].contains("(you pick)"))
        val chosen = SpeakUpTemplate.callScript(cornyn, austin.district, scheduledFacts(), Stance.HOW_WILL_YOU_VOTE)
        assertEquals("\"I'd like to know how the Senator plans to vote.\"", chosen[2])
    }

    @Test
    fun writeGoesToTheFormElseTheHouseFormElseTheWebsite() {
        val doggett = austin.members.first { it.lastName == "Doggett" }
        val cornyn = austin.members.first { it.lastName == "Cornyn" }
        val none = MemberContact(phone = "202-225-4865", website = "https://doggett.house.gov")
        assertEquals(SpeakUpTemplate.HOUSE_FIND_YOUR_REP, SpeakUpTemplate.formUrl(doggett, none))
        assertEquals("https://doggett.house.gov", SpeakUpTemplate.formUrl(cornyn, none))
        val form = MemberContact(contactForm = "https://www.cornyn.senate.gov/contact")
        assertEquals("https://www.cornyn.senate.gov/contact", SpeakUpTemplate.formUrl(cornyn, form))
        assertEquals("tel:2022254865", SpeakUpTemplate.telUrl("202-225-4865"))
        assertNull(SpeakUpTemplate.telUrl(null))
    }

    @Test
    fun theShareFallbackMatchesTheApi() {
        val bill = bill("bill-hr5267")
        val served = Fixtures.decode("bill-share-hr5267", BillShare.serializer())
        assertEquals(served.url, ShareFallback.url(bill))
        assertTrue(ShareFallback.text(scheduledFacts()).endsWith("What it does and how our members vote:"))
        assertTrue(ShareFallback.text(BillFacts.of(bill, null)).endsWith("What it does and where it stands:"))
        // Share sends the API's line and link when it has them.
        val state = BillScreenState(phase = BillScreenState.Phase.Loaded(bill), share = served)
        assertEquals("${served.text} ${served.url}", state.shareText(bill))
    }

    @Test
    fun theBannerSaysHowTheHouseWillTakeItUp() {
        val schedule = Fixtures.decode("schedule-2026-11-16", Schedule.serializer())
        assertEquals("Scheduled for House consideration under a rule, week of Nov 16.", FloorListing.of(schedule, "119-hr-5267")?.bannerLine)
        assertEquals(
            "Scheduled for the House's fast track, needing two-thirds, week of Nov 16.",
            FloorListing.of(schedule, "119-hr-5490")?.bannerLine,
        )
        assertEquals(app.floor.android.model.Chamber.SENATE, FloorListing.of(schedule, "119-hr-2347")?.chamber)
        assertNull(FloorListing.of(schedule, "119-hr-1013"))
    }

    @Test
    fun theSpeakUpRecipientsAreYourRepThenYourSenators() {
        assertEquals(listOf("Doggett", "Cornyn", "Cruz"), recipients(austin).map { it.lastName })
    }

    @Test
    fun theApiDecodesAnAnalysisNoneAsNull() {
        val none = FloorApi.json.decodeFromString(BillAnalysis.serializer().nullable, "null")
        assertNull(none)
    }
}
