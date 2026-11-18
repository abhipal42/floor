package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import app.floor.android.Fixtures
import app.floor.android.bills.BillsScreen
import app.floor.android.bills.BillsState
import app.floor.android.bills.FollowActions
import app.floor.android.bills.SearchState
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalLoadsPortraits
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.following.FollowingActions
import app.floor.android.following.FollowingScreen
import app.floor.android.following.FollowingSegment
import app.floor.android.following.FollowingState
import app.floor.android.home.HomeScreen
import app.floor.android.home.HomeState
import app.floor.android.model.Chamber
import app.floor.android.model.Delegation
import app.floor.android.model.District
import app.floor.android.model.Member
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberSearch
import app.floor.android.model.MemberVotes
import app.floor.android.model.MembersElect
import app.floor.android.model.RecentVotes
import app.floor.android.model.Reps
import app.floor.android.model.SearchResults
import app.floor.android.model.TopicList
import app.floor.android.onboarding.OnboardingScreen
import app.floor.android.onboarding.OnboardingState
import app.floor.android.store.FollowKind
import app.floor.android.store.FollowState
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/**
 * Your district and what you follow: onboarding, Finals with your three (and while a seat changes
 * hands), the Following tab, and search with members-elect. Compare with iOS's `onboarding*`,
 * `homeLoaded`, `homeYourThreeChangingHands`, `following*`, `searchStateWithElect` and
 * `searchPendingSeatSample`. Every screen is drawn from the recorded responses.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1100dp-xhdpi")
class DistrictSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val eastern = ZoneId.of("America/New_York")

    private fun snap(name: String, look: MemberSnapshotTest.Look, content: @Composable () -> Unit) {
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

    private val light = MemberSnapshotTest.Look.LIGHT
    private val dark = MemberSnapshotTest.Look.DARK
    private val large = MemberSnapshotTest.Look.LARGE

    private val austinReps get() = Fixtures.decode("reps-location-austin", Reps.serializer())
    private val austin get() = Delegation.of(austinReps, 0)

    private fun votes(id: String) = Fixtures.decode("member-votes-$id-40", MemberVotes.serializer()).votes

    private val records get() = mapOf("D000399" to votes("doggett"), "C001056" to votes("cornyn"), "C001098" to votes("cruz"))

    private val loyalty
        get() = listOf("member-detail-doggett", "member-detail-cornyn", "member-detail-cruz").associate { name ->
            Fixtures.decode(name, MemberDetail.serializer()).let { it.member.bioguideId to it.partyLoyalty }
        }

    // MARK: - Onboarding

    @Composable
    private fun Onboarding(state: OnboardingState) = OnboardingScreen(state, {}, {}, {}, {}, {}, {}, onSkip = {})

    private val found get() = OnboardingState(address = "1100 Congress Ave, Austin, TX", phase = OnboardingState.Phase.Found(austinReps))

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun onboardingEditingLight() = snap("onboardingEditing", light) { Onboarding(OnboardingState()) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun onboardingEditingDark() = snap("onboardingEditing", dark) { Onboarding(OnboardingState()) }

    @Test fun onboardingFoundLight() = snap("onboardingFound", light) { Onboarding(found) }

    @Test fun onboardingFoundDark() = snap("onboardingFound", dark) { Onboarding(found) }

    @Test
    @Config(qualifiers = "w402dp-h2400dp-xhdpi")
    fun onboardingFoundLarge() = snap("onboardingFound", large) { Onboarding(found) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun onboardingFailedLight() = snap("onboardingFailed", light) {
        Onboarding(
            OnboardingState(
                address = "1100 Congress Ave, Austin, TX",
                phase = OnboardingState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."),
            ),
        )
    }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun onboardingLocationOffLight() = snap("onboardingLocationOff", light) {
        Onboarding(OnboardingState(triedLocation = true, notice = OnboardingState.Notice.LOCATION_OFF))
    }

    // MARK: - Finals with your three

    /** The day the stories fixtures were recorded: Nov 16 is "This week", Nov 11-12 "Last week". */
    private val today = Instant.parse("2026-11-17T15:00:00Z")

    @Composable
    private fun Home(state: HomeState) = HomeScreen(state, Appearance.SYSTEM, {}, {}, {}, {}, {}, zone = eastern, locale = Locale.US, now = today)

    /**
     * New York's 12th (Nadler, Schumer, Gillibrand) on the stories feed, as the locked v0.2.57 mock
     * draws it: H.R. 2102 with its discharge and rule, Domenico, Cook, H.R. 1013, St. John and the
     * unnamed cloture. Real rows, recorded the day the mock was locked.
     */
    private val newYork: HomeState
        get() {
            val details = listOf("nadler", "schumer", "gillibrand").map { Fixtures.decode("member-detail-$it", MemberDetail.serializer()) }
            val members = details.map { it.member }
            val records = listOf("nadler", "schumer", "gillibrand").map { Fixtures.decode("member-votes-$it-stories", MemberVotes.serializer()).votes }
            val ny = Delegation(District(119, "NY", 12), members)
            return HomeState(
                phase = HomeState.Phase.Loaded,
                items = Fixtures.decode("votes-stories", RecentVotes.serializer()).votes,
                scope = HomeState.Scope.ALL,
                yours = HomeState.merge(members.zip(records), members.map { it.bioguideId }),
                followsAnything = true,
                delegation = ny, strip = members,
                loyalty = details.associate { it.member.bioguideId to it.partyLoyalty },
            )
        }

    @Test
    @Config(qualifiers = "w402dp-h2200dp-xhdpi")
    fun homeStoriesLight() = snap("homeStories", light) { Home(newYork) }

    @Test
    @Config(qualifiers = "w402dp-h2200dp-xhdpi")
    fun homeStoriesDark() = snap("homeStories", dark) { Home(newYork) }

    @Test
    @Config(qualifiers = "w402dp-h4400dp-xhdpi")
    fun homeStoriesLarge() = snap("homeStories", large) { Home(newYork) }

    private val yourThree: HomeState
        get() {
            val members = austin.members
            val yours = HomeState.merge(members.map { it to records.getValue(it.bioguideId) }, members.map { it.bioguideId })
            return HomeState(
                phase = HomeState.Phase.Loaded,
                items = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes,
                scope = HomeState.Scope.YOURS, yours = yours, followsAnything = true,
                delegation = austin, strip = members, loyalty = loyalty,
            )
        }

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun homeYourThreeLight() = snap("homeYourThree", light) { Home(yourThree) }

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun homeYourThreeDark() = snap("homeYourThree", dark) { Home(yourThree) }

    @Test
    @Config(qualifiers = "w402dp-h3200dp-xhdpi")
    fun homeYourThreeLarge() = snap("homeYourThree", large) { Home(yourThree) }

    /** Michigan's 12th: Peters leaving, El-Sayed under him, drawn before the feed loads. */
    private val changingHands: HomeState
        get() {
            val tlaib = Member("T000481", "Rashida", "Tlaib", "D", "MI", 12, Chamber.HOUSE)
            val slotkin = Member("S001208", "Elissa", "Slotkin", "D", "MI", null, Chamber.SENATE)
            val peters = Member("P000595", "Gary", "Peters", "D", "MI", null, Chamber.SENATE)
            val mi = Delegation(District(119, "MI", 12), listOf(tlaib, slotkin, peters))
            val seats = Fixtures.decode("members-elect-mi", MembersElect.serializer()).seats("MI", 12)
            return HomeState(delegation = mi, strip = mi.members, seats = seats, followsAnything = true)
        }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun changingHandsLight() = snap("homeYourThreeChangingHands", light) { Home(changingHands) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun changingHandsDark() = snap("homeYourThreeChangingHands", dark) { Home(changingHands) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun changingHandsLarge() = snap("homeYourThreeChangingHands", large) { Home(changingHands) }

    // MARK: - Following

    private val adams get() = Fixtures.decode("member-detail", MemberDetail.serializer()).member

    private val follows: FollowState
        get() {
            val bill = Fixtures.decode("search-hr1013", SearchResults.serializer()).bills.first()
            return FollowState()
                .follow(FollowKind.MEMBER, adams.bioguideId, member = adams)
                .follow(FollowKind.BILL, bill.id, bill = bill)
                .follow(FollowKind.TOPIC, "Finance and Financial Sector")
        }

    private val topics get() = BillsState.Phase.Loaded(Fixtures.decode("topics", TopicList.serializer()).topics)

    private fun following(segment: FollowingSegment, editing: Boolean = false) = FollowingState(
        follows = follows, delegation = austin, segment = segment, editing = editing, loyalty = loyalty, records = records, topics = topics,
    )

    @Composable
    private fun Following(state: FollowingState) = FollowingScreen(state, FollowingActions(), eastern, Locale.US)

    @Test fun followingMembersLight() = snap("followingMembers", light) { Following(following(FollowingSegment.MEMBERS)) }

    @Test fun followingMembersDark() = snap("followingMembers", dark) { Following(following(FollowingSegment.MEMBERS)) }

    @Test
    @Config(qualifiers = "w402dp-h2400dp-xhdpi")
    fun followingMembersLarge() = snap("followingMembers", large) { Following(following(FollowingSegment.MEMBERS)) }

    @Test fun followingEditingLight() = snap("followingEditing", light) {
        Following(following(FollowingSegment.MEMBERS, editing = true).let { it.copy(follows = it.follows.setHidden("C001056", true)) })
    }

    @Test fun followingBillsLight() = snap("followingBills", light) { Following(following(FollowingSegment.BILLS)) }

    @Test fun followingBillsDark() = snap("followingBills", dark) { Following(following(FollowingSegment.BILLS)) }

    @Test fun followingTopicsLight() = snap("followingTopics", light) { Following(following(FollowingSegment.TOPICS)) }

    @Test fun followingTopicsDark() = snap("followingTopics", dark) { Following(following(FollowingSegment.TOPICS)) }

    @Test fun followingNothingYetLight() = snap("followingNothingYet", light) {
        Following(FollowingState(topics = topics))
    }

    // MARK: - Search with members-elect

    private fun search(results: String, members: String, query: String, chamber: Chamber): BillsState {
        val seats = Fixtures.decode(members, MemberSearch.serializer())
        return BillsState(
            search = SearchState(
                query = query, chamber = chamber, results = Fixtures.decode(results, SearchResults.serializer()),
                seats = MembersElect(seats.elect, seats.pending), searched = query,
            ),
        )
    }

    private val followActions get() = FollowActions(FollowState(), emptySet(), {}, {}, {})

    @Composable
    private fun Search(state: BillsState) =
        BillsScreen(state, app.floor.android.bills.LedgerState(), {}, {}, {}, {}, {}, java.time.ZoneId.of("America/New_York"), java.util.Locale.US, follow = followActions)

    private val michigan get() = search("search-michigan-senate", "members-search-michigan-senate", "michigan", Chamber.SENATE)

    private val pendingSample get() = search("search-pending-sample", "members-search-pending-sample", "pending sample", Chamber.HOUSE)

    @Test fun searchStateWithElectLight() = snap("searchStateWithElect", light) { Search(michigan) }

    @Test fun searchStateWithElectDark() = snap("searchStateWithElect", dark) { Search(michigan) }

    @Test
    @Config(qualifiers = "w402dp-h2200dp-xhdpi")
    fun searchStateWithElectLarge() = snap("searchStateWithElect", large) { Search(michigan) }

    @Test fun searchPendingSeatSampleLight() = snap("searchPendingSeatSample", light) { Search(pendingSample) }

    @Test fun searchPendingSeatSampleDark() = snap("searchPendingSeatSample", dark) { Search(pendingSample) }
}
