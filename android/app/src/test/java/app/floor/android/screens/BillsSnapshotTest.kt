package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.floor.android.Fixtures
import app.floor.android.bill.AIAnalysis
import app.floor.android.bill.AIAnalysisSection
import app.floor.android.bill.AnalysisPhase
import app.floor.android.bill.BillFacts
import app.floor.android.bill.BillFollow
import app.floor.android.bill.MemberOnBill
import app.floor.android.bill.BillScreen
import app.floor.android.bill.BillScreenState
import app.floor.android.bill.FloorListing
import app.floor.android.bill.SpeakUpSheet
import app.floor.android.bill.Stance
import app.floor.android.bills.BillsScreen
import app.floor.android.bills.BillsState
import app.floor.android.bills.SearchState
import app.floor.android.bills.TopicScreen
import app.floor.android.bills.TopicState
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalLoadsPortraits
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.model.Bill
import app.floor.android.model.BillAnalysis
import app.floor.android.model.BillShare
import app.floor.android.model.Delegation
import app.floor.android.model.MemberContact
import app.floor.android.model.MemberDetail
import app.floor.android.model.Schedule
import app.floor.android.model.SearchResults
import app.floor.android.model.TopicBills
import app.floor.android.model.TopicList
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.ZoneId
import java.util.Locale

/**
 * The Bills tab, a topic's page, the bill screen, its AI section and Speak up, light, dark and at
 * the largest font scale (200%, standing in for iOS's ax5), at the iOS references' 402-point width,
 * 2x. Compare with `ios/FloorKit/Tests/SnapshotTests/__Snapshots__/{Follow,Round11,AIAnalysis,
 * Screen}SnapshotTests/`: `topicPage`, `searchWords`, `searchBillNumber`, `billOnTheFloor`,
 * `citationOpen`, `noSummaryYet`, `speakUp*`. Every screen is drawn from the recorded responses.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1100dp-xhdpi")
class BillsSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val eastern = ZoneId.of("America/New_York")

    private enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
        LIGHT("light", Appearance.LIGHT, 1f),
        DARK("dark", Appearance.DARK, 1f),
        LARGE("large", Appearance.LIGHT, 2f),
    }

    private fun snap(name: String, look: Look, content: @Composable () -> Unit) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalPlaysArrivalAnimations provides false,
                LocalLoadsPortraits provides false,
                LocalDensity provides Density(density.density, look.fontScale),
            ) {
                FloorTheme(look.appearance, content)
            }
        }
        compose.onRoot().captureRoboImage("src/test/snapshots/$name.${look.suffix}.png")
    }

    // MARK: - Fixtures

    private val topics get() = Fixtures.decode("topics", TopicList.serializer()).topics

    private fun bill(name: String) = Fixtures.decode(name, Bill.serializer())

    private val schedule get() = Fixtures.decode("schedule-2026-11-16", Schedule.serializer())

    private val austin get() = Fixtures.decode("reps-location-austin", Delegation.serializer())

    private val contacts: Map<String, MemberContact>
        get() = listOf("member-detail-doggett", "member-detail-cornyn", "member-detail-cruz").associate { name ->
            val detail = Fixtures.decode(name, MemberDetail.serializer())
            detail.member.bioguideId to detail.contact!!
        }

    /** H.R. 5267 on the week of Nov 16: the banner. The analysis route 404s, so the AI section is hidden. */
    private val onTheFloor: BillScreenState
        get() {
            val bill = bill("bill-hr5267")
            return BillScreenState(
                phase = BillScreenState.Phase.Loaded(bill),
                analysis = AnalysisPhase.of(bill, null),
                listing = FloorListing.of(schedule, bill.id),
                share = Fixtures.decode("bill-share-hr5267", BillShare.serializer()),
            )
        }

    /** H.R. 1013: passed the House, its roll call listed under the levels. */
    private val hr1013: BillScreenState
        get() {
            val bill = bill("bill-hr1013")
            return BillScreenState(phase = BillScreenState.Phase.Loaded(bill), analysis = AnalysisPhase.of(bill, null))
        }

    private val facts get() = bill("bill-hr5267").let { BillFacts.of(it, FloorListing.of(schedule, it.id)) }

    private fun search(fixture: String, query: String) = BillsState(
        topics = BillsState.Phase.Loaded(topics),
        search = SearchState(query = query, results = Fixtures.decode(fixture, SearchResults.serializer()), searched = query),
    )

    private val topicPage: TopicState
        get() {
            val page = Fixtures.decode("topic-bills-health", TopicBills.serializer())
            return TopicState("Health", phase = TopicState.Phase.Loaded, bills = page.bills, topic = page.topic, nextCursor = page.nextCursor)
        }

    // MARK: - Screens

    @Composable
    private fun Bills(state: BillsState) = BillsScreen(state, {}, {}, {}, {}, {})

    @Composable
    private fun Topic(state: TopicState) = TopicScreen(state, "Bills", {}, {}, {}, {}, {})

    @Composable
    private fun BillAt(state: BillScreenState, follow: BillFollow? = null) = BillScreen(
        state = state, back = "Bills", zone = eastern, locale = Locale.US, onBack = {}, onRetry = {},
        onToggleCitation = {}, onRetryAnalysis = {}, onOpenVote = {}, onOpenTopic = {}, onSpeakUp = {}, follow = follow,
    )

    /** As iOS draws it with a follow list: Follow bill above the title, and Austin's three on it. */
    private val withFollows: BillScreenState
        get() = onTheFloor.copy(yourMembers = austin.members.map { MemberOnBill(it, null, null, null) })

    private val follow = BillFollow(following = false, followingTopic = { false }) {}

    /** The AI section alone on the ground, as iOS's `AIAnalysisSnapshotTests` draw it. */
    @Composable
    private fun Section(phase: AnalysisPhase, open: String? = null) {
        Box(Modifier.fillMaxSize().background(Palette.ground).padding(16.dp)) {
            AIAnalysisSection(phase, open, {}, {})
        }
    }

    private val analysis get() = AIAnalysis.of(Fixtures.decode("bill-analysis", BillAnalysis.serializer()))

    // MARK: - Bills tab

    @Test fun topicsLight() = snap("billsTopics", Look.LIGHT) { Bills(BillsState(topics = BillsState.Phase.Loaded(topics))) }

    @Test fun topicsDark() = snap("billsTopics", Look.DARK) { Bills(BillsState(topics = BillsState.Phase.Loaded(topics))) }

    @Test fun topicsLarge() = snap("billsTopics", Look.LARGE) { Bills(BillsState(topics = BillsState.Phase.Loaded(topics))) }

    @Test fun searchWordsLight() = snap("billsSearchWords", Look.LIGHT) { Bills(search("search-rural-health", "rural health")) }

    @Test fun searchWordsDark() = snap("billsSearchWords", Look.DARK) { Bills(search("search-rural-health", "rural health")) }

    @Test fun searchWordsLarge() = snap("billsSearchWords", Look.LARGE) { Bills(search("search-rural-health", "rural health")) }

    @Test fun searchBillNumberLight() = snap("billsSearchBillNumber", Look.LIGHT) { Bills(search("search-hr1013", "hr 1013")) }

    @Test fun searchNothingLight() = snap("billsSearchNothing", Look.LIGHT) { Bills(search("search-pending-sample", "pending sample")) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun loadingLight() = snap("billsLoading", Look.LIGHT) { Bills(BillsState()) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun failedLight() = snap("billsFailed", Look.LIGHT) {
        Bills(BillsState(topics = BillsState.Phase.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun failedDark() = snap("billsFailed", Look.DARK) {
        Bills(BillsState(topics = BillsState.Phase.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    // MARK: - A topic

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun topicLight() = snap("topicPage", Look.LIGHT) { Topic(topicPage) }

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun topicDark() = snap("topicPage", Look.DARK) { Topic(topicPage) }

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun topicLarge() = snap("topicPage", Look.LARGE) { Topic(topicPage) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun topicFailedLight() = snap("topicPageFailed", Look.LIGHT) {
        Topic(TopicState("Health", phase = TopicState.Phase.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    // MARK: - The bill

    @Test
    @Config(qualifiers = "w402dp-h2500dp-xhdpi")
    fun onTheFloorLight() = snap("billOnTheFloor", Look.LIGHT) { BillAt(withFollows, follow) }

    @Test
    @Config(qualifiers = "w402dp-h2500dp-xhdpi")
    fun onTheFloorDark() = snap("billOnTheFloor", Look.DARK) { BillAt(withFollows, follow) }

    @Test
    @Config(qualifiers = "w402dp-h5000dp-xhdpi")
    fun onTheFloorLarge() = snap("billOnTheFloor", Look.LARGE) { BillAt(withFollows, follow) }

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun hr1013Light() = snap("billHr1013", Look.LIGHT) { BillAt(hr1013) }

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun hr1013Dark() = snap("billHr1013", Look.DARK) { BillAt(hr1013) }

    @Test
    @Config(qualifiers = "w402dp-h2800dp-xhdpi")
    fun hr1013Large() = snap("billHr1013", Look.LARGE) { BillAt(hr1013) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun billLoadingLight() = snap("billLoading", Look.LIGHT) { BillAt(BillScreenState()) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun billFailedLight() = snap("billFailed", Look.LIGHT) {
        BillAt(BillScreenState(phase = BillScreenState.Phase.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun billFailedDark() = snap("billFailed", Look.DARK) {
        BillAt(BillScreenState(phase = BillScreenState.Phase.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    // MARK: - The AI section

    /** Every heading, chip and the disclaimer, with the `Sec. 101` citation open. */
    private fun citationOpen(look: Look) = snap("aiCitationOpen", look) {
        val shown = analysis
        Section(AnalysisPhase.Loaded(shown), shown.citations.first { it.section != null }.id)
    }

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun aiCitationOpenLight() = citationOpen(Look.LIGHT)

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun aiCitationOpenDark() = citationOpen(Look.DARK)

    @Test
    @Config(qualifiers = "w402dp-h1200dp-xhdpi")
    fun aiCitationOpenLarge() = citationOpen(Look.LARGE)

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun aiStaleLight() = snap("aiStale", Look.LIGHT) { Section(AnalysisPhase.Loaded(analysis.copy(stale = true))) }

    @Test
    @Config(qualifiers = "w402dp-h300dp-xhdpi")
    fun aiNoSummaryLight() = snap("aiNoSummaryYet", Look.LIGHT) { Section(AnalysisPhase.NoSummary) }

    @Test
    @Config(qualifiers = "w402dp-h300dp-xhdpi")
    fun aiNoSummaryDark() = snap("aiNoSummaryYet", Look.DARK) { Section(AnalysisPhase.NoSummary) }

    @Test
    @Config(qualifiers = "w402dp-h300dp-xhdpi")
    fun aiFailedLight() = snap("aiFailed", Look.LIGHT) { Section(AnalysisPhase.Failed) }

    @Test
    @Config(qualifiers = "w402dp-h300dp-xhdpi")
    fun aiLoadingLight() = snap("aiLoading", Look.LIGHT) { Section(AnalysisPhase.Loading) }

    // MARK: - Speak up

    /** What the app shows today: Android has no district until phase 4. */
    @Test
    @Config(qualifiers = "w402dp-h500dp-xhdpi")
    fun speakUpNoDistrictLight() = snap("speakUpNoDistrict", Look.LIGHT) { SpeakUpSheet(facts, null, { null }, onSetDistrict = {}) }

    @Test
    @Config(qualifiers = "w402dp-h500dp-xhdpi")
    fun speakUpNoDistrictDark() = snap("speakUpNoDistrict", Look.DARK) { SpeakUpSheet(facts, null, { null }, onSetDistrict = {}) }

    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun speakUpNoDistrictLarge() = snap("speakUpNoDistrict", Look.LARGE) { SpeakUpSheet(facts, null, { null }, onSetDistrict = {}) }

    /** As it opens with a district: no view chosen, so no message yet. */
    @Test
    @Config(qualifiers = "w402dp-h700dp-xhdpi")
    fun speakUpNothingChosenLight() = snap("speakUpNothingChosen", Look.LIGHT) {
        SpeakUpSheet(facts, austin, { null }, contacts = contacts)
    }

    @Test
    @Config(qualifiers = "w402dp-h700dp-xhdpi")
    fun speakUpNothingChosenDark() = snap("speakUpNothingChosen", Look.DARK) {
        SpeakUpSheet(facts, austin, { null }, contacts = contacts)
    }

    /** The mock's state: Rep. Doggett, "How will you vote?". */
    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun speakUpChosenLight() = snap("speakUpChosen", Look.LIGHT) {
        SpeakUpSheet(facts, austin, { null }, initialStance = Stance.HOW_WILL_YOU_VOTE, contacts = contacts)
    }

    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun speakUpChosenDark() = snap("speakUpChosen", Look.DARK) {
        SpeakUpSheet(facts, austin, { null }, initialStance = Stance.HOW_WILL_YOU_VOTE, contacts = contacts)
    }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun speakUpChosenLarge() = snap("speakUpChosen", Look.LARGE) {
        SpeakUpSheet(facts, austin, { null }, initialStance = Stance.HOW_WILL_YOU_VOTE, contacts = contacts)
    }

    @Test
    @Config(qualifiers = "w402dp-h700dp-xhdpi")
    fun speakUpCallScriptLight() = snap("speakUpCallScript", Look.LIGHT) {
        SpeakUpSheet(facts, austin, { null }, recipientId = "C001056", startCalling = true, contacts = contacts)
    }

    @Test
    @Config(qualifiers = "w402dp-h700dp-xhdpi")
    fun speakUpCallScriptDark() = snap("speakUpCallScript", Look.DARK) {
        SpeakUpSheet(facts, austin, { null }, recipientId = "C001056", startCalling = true, contacts = contacts)
    }
}
