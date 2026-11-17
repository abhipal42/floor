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
import app.floor.android.model.Chamber
import app.floor.android.model.Schedule
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

/**
 * The Week tab from the recorded weeks of Nov 16 and Nov 23, as iOS `Round11SnapshotTests` draws it
 * (`weekHouse`, `weekSenate`, `weekNothingPosted`, `weekNothingPostedSenate`): you follow H.R. 9640
 * and the Labor and Employment topic, which takes in both bills under a rule.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1400dp-xhdpi")
class WeekSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
        LIGHT("light", Appearance.LIGHT, 1f),
        DARK("dark", Appearance.DARK, 1f),
        LARGE("large", Appearance.LIGHT, 2f),
    }

    private val follows = FollowState().follow(FollowKind.BILL, "119-hr-9640").follow(FollowKind.TOPIC, "Labor and Employment")

    private fun week(fixture: String, chamber: Chamber = Chamber.HOUSE): WeekState {
        val schedule = Fixtures.decode(fixture, Schedule.serializer())
        return WeekState(phase = WeekState.Phase.Loaded(schedule), week = schedule.week, chamber = chamber)
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
    private fun Screen(state: WeekState) = WeekScreen(state, follows, onWeek = {}, onChamber = {}, onExpand = {}, onRetry = {}, onOpenBill = {})

    @Test
    fun weekHouseLight() = snap("weekHouse", Look.LIGHT, week("schedule-2026-11-16"))

    @Test
    fun weekHouseDark() = snap("weekHouse", Look.DARK, week("schedule-2026-11-16"))

    @Test
    @Config(qualifiers = "w402dp-h2400dp-xhdpi")
    fun weekHouseLarge() = snap("weekHouse", Look.LARGE, week("schedule-2026-11-16"))

    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun weekSenateLight() = snap("weekSenate", Look.LIGHT, week("schedule-2026-11-16", Chamber.SENATE))

    @Test
    @Config(qualifiers = "w402dp-h900dp-xhdpi")
    fun weekSenateDark() = snap("weekSenate", Look.DARK, week("schedule-2026-11-16", Chamber.SENATE))

    /** The week of Nov 23: no list posted, no Senate meeting named. Says why, never "recess". */
    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun weekNothingPostedLight() = snap("weekNothingPosted", Look.LIGHT, week("schedule-2026-11-23").copy(offset = 1))

    @Test
    @Config(qualifiers = "w402dp-h500dp-xhdpi")
    fun weekNothingPostedSenateDark() = snap("weekNothingPostedSenate", Look.DARK, week("schedule-2026-11-23", Chamber.SENATE).copy(offset = 1))

    @Test
    @Config(qualifiers = "w402dp-h600dp-xhdpi")
    fun weekFailedLight() = snap("weekFailed", Look.LIGHT, WeekState(phase = WeekState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."), week = "2026-11-16"))
}
