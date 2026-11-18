package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import app.floor.android.Fixtures
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.model.RecentVotes
import app.floor.android.model.Schedule
import app.floor.android.model.TopicGroup
import app.floor.android.store.FollowKind
import app.floor.android.store.FollowState
import app.floor.android.week.WeekScreen
import app.floor.android.week.WeekState
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
 * The Week tab (v0.2.59 headliners) from the live schedule for the week of Nov 16 (`schedule-three-
 * 2026-11-16`, with the H.Res. 1665 rule) and the latest finals (`votes-three`), drawn on Tuesday
 * Nov 17 at 10 a.m. in Washington; and the empty week of Nov 23. You follow H.R. 9640 and the
 * Labor and Employment topic, which takes in both bills under the rule.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1900dp-xhdpi")
class WeekSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
        LIGHT("light", Appearance.LIGHT, 1f),
        DARK("dark", Appearance.DARK, 1f),
        LARGE("large", Appearance.LIGHT, 2f),
    }

    private val follows = FollowState().follow(FollowKind.BILL, "119-hr-9640").follow(FollowKind.TOPIC, "Labor and Employment")
    private val votes = Fixtures.decode("votes-three", RecentVotes.serializer()).votes
    private val tuesday = Instant.parse("2026-11-17T15:00:00Z")

    private fun week(fixture: String, detail: WeekState.Detail? = null): WeekState {
        val schedule = Fixtures.decode(fixture, Schedule.serializer())
        return WeekState(phase = WeekState.Phase.Loaded(schedule), week = schedule.week, detail = detail)
    }

    private fun snap(name: String, look: Look, state: WeekState) {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalPlaysArrivalAnimations provides false,
                LocalDensity provides Density(density.density, look.fontScale),
            ) {
                FloorTheme(look.appearance) { Screen(state) }
            }
        }
        compose.onRoot().captureRoboImage("src/test/snapshots/$name.${look.suffix}.png")
    }

    @Composable
    private fun Screen(state: WeekState) = WeekScreen(
        state, follows, votes, ZoneId.of("America/New_York"), Locale.US,
        onWeek = {}, onOpen = {}, onRetry = {}, onOpenBill = {}, now = tuesday,
    )

    @Test
    fun weekHeadlinersLight() = snap("weekHeadliners", Look.LIGHT, week("schedule-three-2026-11-16"))

    @Test
    fun weekHeadlinersDark() = snap("weekHeadliners", Look.DARK, week("schedule-three-2026-11-16"))

    @Test
    @Config(qualifiers = "w402dp-h3600dp-xhdpi")
    fun weekHeadlinersLarge() = snap("weekHeadliners", Look.LARGE, week("schedule-three-2026-11-16"))

    /** "Program ›": the Senate's two meetings of the week, their programs and the measure they name. */
    @Test
    @Config(qualifiers = "w402dp-h1000dp-xhdpi")
    fun weekSenateProgramDark() = snap("weekSenateProgram", Look.DARK, week("schedule-three-2026-11-16", WeekState.Detail.Senate))

    /** The Land tile: its six suspensions on their own screen. */
    @Test
    @Config(qualifiers = "w402dp-h1100dp-xhdpi")
    fun weekFastTrackLandLight() = snap("weekFastTrackLand", Look.LIGHT, week("schedule-three-2026-11-16", WeekState.Detail.FastTrack(TopicGroup.LAND)))

    /** The week of Nov 23: no list posted, no Senate meeting named. Says why, never "recess". */
    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun weekNothingPostedLight() = snap("weekNothingPosted", Look.LIGHT, week("schedule-2026-11-23").copy(offset = 1))

    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun weekNothingPostedDark() = snap("weekNothingPosted", Look.DARK, week("schedule-2026-11-23").copy(offset = 1))

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun weekFailedLight() = snap("weekFailed", Look.LIGHT, WeekState(phase = WeekState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."), week = "2026-11-16"))
}
