package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import app.floor.android.Fixtures
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalLoadsPortraits
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.home.CatchUpScreen
import app.floor.android.home.FeedItem
import app.floor.android.home.HomeState
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberVotes
import app.floor.android.model.RecentVotes
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
 * The catch-up deck (v0.2.59) from the live finals of Nov 17 (`votes-three`), with three senators'
 * recorded votes on them: Gillibrand and Schumer (New York) and Blackburn. The top card is the
 * Ratepayer Protection Act's cloture vote, 57–43 against the 60 it needed.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1200dp-xhdpi")
class CatchUpSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
        LIGHT("light", Appearance.LIGHT, 1f),
        DARK("dark", Appearance.DARK, 1f),
        LARGE("large", Appearance.LIGHT, 2f),
    }

    private val deck: List<FeedItem>
        get() {
            val members = listOf("member-detail-gillibrand", "member-detail-schumer-2026-11-17", "member-detail-blackburn")
                .map { Fixtures.decode(it, MemberDetail.serializer()).member }
            val records = listOf("member-votes-gillibrand-40", "member-votes-schumer-40-2026-11-17", "member-votes-blackburn-three")
                .map { Fixtures.decode(it, MemberVotes.serializer()).votes }
            val yours = HomeState.merge(members.zip(records), members.map { it.bioguideId })
            val items = Fixtures.decode("votes-three", RecentVotes.serializer()).votes
            return HomeState(phase = HomeState.Phase.Loaded, items = items, yours = yours).deck
        }

    private fun snap(name: String, look: Look, front: Int = 0) {
        val cards = deck
        assertEquals("senate-119-2-254", cards.first().vote.id)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalPlaysArrivalAnimations provides false,
                LocalLoadsPortraits provides false,
                LocalDensity provides Density(density.density, look.fontScale),
            ) {
                FloorTheme(look.appearance) {
                    CatchUpScreen(cards, front, ZoneId.of("America/New_York"), Locale.US, onFront = {}, onClose = {}, onOpen = {})
                }
            }
        }
        compose.onRoot().captureRoboImage("src/test/snapshots/$name.${look.suffix}.png")
    }

    @Test
    fun catchUpRatepayerLight() = snap("catchUpRatepayer", Look.LIGHT)

    @Test
    fun catchUpRatepayerDark() = snap("catchUpRatepayer", Look.DARK)

    @Test
    @Config(qualifiers = "w402dp-h2600dp-xhdpi")
    fun catchUpRatepayerLarge() = snap("catchUpRatepayer", Look.LARGE)

    /** The last card: no ghosts behind it, "Last one". */
    @Test
    fun catchUpLastCardDark() = snap("catchUpLastCard", Look.DARK, front = 4)

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun catchUpCaughtUpDark() = snap("catchUpCaughtUp", Look.DARK, front = 5)
}
