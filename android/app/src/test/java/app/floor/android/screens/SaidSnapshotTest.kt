package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import app.floor.android.Fixtures
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalLoadsPortraits
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.following.FollowingActions
import app.floor.android.following.FollowingScreen
import app.floor.android.following.FollowingSegment
import app.floor.android.following.FollowingState
import app.floor.android.member.Load
import app.floor.android.member.MemberRecord
import app.floor.android.member.MemberScreen
import app.floor.android.member.MemberSection
import app.floor.android.member.MemberState
import app.floor.android.model.Delegation
import app.floor.android.model.District
import app.floor.android.model.Member
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberSearch
import app.floor.android.model.PostsWall
import app.floor.android.model.Promises
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.ZoneId
import java.util.Locale

/**
 * Round 13 against the locked mock (`floor-said.html`): Said's swipe deck (Slotkin, card 2 of 3), the
 * no-platform browser frame (Gillibrand), the three dashed placeholders, Posts and Contact's official
 * accounts (Schumer), and the Following wall (Schumer's posts, Nadler on X and Facebook only). Light,
 * dark and 200% as the other member snapshots; the fixtures are hand-built from real content.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h874dp-xhdpi")
class SaidSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val eastern = ZoneId.of("America/New_York")

    enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
        LIGHT("light", Appearance.LIGHT, 1f),
        DARK("dark", Appearance.DARK, 1f),
        LARGE("large", Appearance.LIGHT, 2f),
    }

    private fun show(look: Look, content: @Composable () -> Unit) {
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
    }

    private fun snap(name: String, look: Look, content: @Composable () -> Unit) {
        show(look, content)
        compose.onRoot().captureRoboImage("src/test/snapshots/$name.${look.suffix}.png")
    }

    private val newYork = Fixtures.decode("members-search-new-york", MemberSearch.serializer()).members
    private val michigan = Fixtures.decode("members-search-michigan-senate", MemberSearch.serializer()).members
    private fun member(id: String) = (newYork + michigan).first { it.bioguideId == id }

    private fun record(member: Member) = Load.Loaded(MemberRecord(MemberDetail(member), emptyList()))

    private val slotkin get() = MemberState(
        record = record(member("S001208")),
        promises = Load.Loaded(Fixtures.decode("promises-slotkin", Promises.serializer())),
        promise = 1,
        section = MemberSection.SAID,
    )

    private val schumer get() = MemberState(
        record = Load.Loaded(MemberRecord(Fixtures.decode("member-detail-schumer", MemberDetail.serializer()), emptyList())),
        posts = Load.Loaded(Fixtures.decode("posts-schumer", MemberPosts.serializer())),
        section = MemberSection.POSTS,
    )

    private fun said(id: String, promises: Promises) =
        MemberState(record = record(member(id)), promises = Load.Loaded(promises), section = MemberSection.SAID)

    @Composable
    private fun Member(state: MemberState) = MemberScreen(state, "Following", eastern, Locale.US, {}, {}, {}, {}, {}, {}, {}, {})

    // MARK: Said

    @Test fun deckLight() = snap("saidDeck", Look.LIGHT) { Member(slotkin) }

    @Test fun deckDark() = snap("saidDeck", Look.DARK) { Member(slotkin) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun deckLarge() = snap("saidDeck", Look.LARGE) { Member(slotkin) }

    /** TalkBack reads the card on top whole, and can move through the deck without swiping. */
    @Test
    fun deckReadsAsOneCardWithActions() {
        show(Look.LIGHT) { Member(slotkin) }
        compose.onNodeWithContentDescription("Promise 2 of 3", substring = true)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsActions.CustomActions))
            .assert(
                SemanticsMatcher("next, previous, archive, topic") { node ->
                    node.config[SemanticsActions.CustomActions].map { it.label } ==
                        listOf("Next promise", "Previous promise", "Open the archived page", "Open the topic Health")
                },
            )
        val spoken = compose.onNodeWithContentDescription("Promise 2 of 3", substring = true).fetchSemanticsNode()
            .config[SemanticsProperties.ContentDescription].single()
        assertEquals(
            "Promise 2 of 3, under Defending and Expanding Michigan’s Middle Class. “Elissa believes all Americans should have " +
                "access to healthcare they can afford, regardless of pre-existing conditions.” Archived Oct 12, 2024.",
            spoken,
        )
    }

    private val gillibrand get() = said("G000555", Fixtures.decode("promises-gillibrand", Promises.serializer()))

    @Test fun noPlatformLight() = snap("saidNoPlatform", Look.LIGHT) { Member(gillibrand) }

    @Test fun noPlatformDark() = snap("saidNoPlatform", Look.DARK) { Member(gillibrand) }

    // Hand-built states (no recorded member has them yet): the placeholder says exactly which.
    @Test fun uncheckedLight() = snap("saidUnchecked", Look.LIGHT) { Member(said("S000148", Promises())) }

    @Test fun noSiteLight() = snap("saidNoSite", Look.LIGHT) { Member(said("S000148", Promises(status = "no_site", electionYear = 2022))) }

    @Test
    fun noSnapshotDark() = snap("saidNoSnapshot", Look.DARK) {
        Member(said("S001208", Promises(status = "no_snapshot", electionYear = 2024, siteUrl = "https://elissaslotkin.org")))
    }

    // MARK: Posts and accounts

    @Test fun postsLight() = snap("memberPosts", Look.LIGHT) { Member(schumer) }

    @Test fun postsDark() = snap("memberPosts", Look.DARK) { Member(schumer) }

    @Test
    @Config(qualifiers = "w402dp-h2600dp-xhdpi")
    fun postsLarge() = snap("memberPosts", Look.LARGE) { Member(schumer) }

    @Test fun accountsLight() = snap("memberAccounts", Look.LIGHT) { Member(schumer.copy(section = MemberSection.CONTACT)) }

    @Test fun accountsDark() = snap("memberAccounts", Look.DARK) { Member(schumer.copy(section = MemberSection.CONTACT)) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun accountsLarge() = snap("memberAccounts", Look.LARGE) { Member(schumer.copy(section = MemberSection.CONTACT)) }

    // MARK: The wall

    /** NY-12's three: Nadler, Schumer and Gillibrand. */
    private val wall get() = FollowingState(
        delegation = Delegation(District(119, "NY", 12), listOf(member("N000002"), member("S000148"), member("G000555"))),
        segment = FollowingSegment.POSTS,
        wall = Load.Loaded(Fixtures.decode("posts-wall-ny", PostsWall.serializer())),
    )

    @Composable
    private fun Following(state: FollowingState) = FollowingScreen(state, FollowingActions(), eastern, Locale.US)

    @Test fun wallLight() = snap("followingPosts", Look.LIGHT) { Following(wall) }

    @Test fun wallDark() = snap("followingPosts", Look.DARK) { Following(wall) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun wallLarge() = snap("followingPosts", Look.LARGE) { Following(wall) }
}
