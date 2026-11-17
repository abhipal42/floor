package app.floor.android.screens

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import app.floor.android.Fixtures
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.home.HomeScreen
import app.floor.android.home.HomeState
import app.floor.android.model.RecentVotes
import app.floor.android.shell.FloorScreens
import app.floor.android.shell.FloorShell
import app.floor.android.shell.Tab
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Finals screen in each state, light and dark, at the iOS references' width (402 points, drawn
 * at 2x like the iPhone 17 Pro ones in `ios/FloorKit/Tests/SnapshotTests/__Snapshots__`).
 *
 * Record with `./gradlew recordRoborazziDebug`; CI runs `verifyRoborazziDebug` against the PNGs
 * committed under `src/test/snapshots`. SDK 36 because it is the newest Robolectric 4.17 runs;
 * the app targets 37.
 *
 * The loading state's spinner is drawn at its first frame: Compose tests stop infinite animations.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h874dp-xhdpi")
class ScreenSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val recent = Fixtures.decode("votes-recent", RecentVotes.serializer()).votes

    private fun snap(name: String, appearance: Appearance, content: @Composable () -> Unit) {
        compose.setContent {
            CompositionLocalProvider(LocalPlaysArrivalAnimations provides false) {
                FloorTheme(appearance, content)
            }
        }
        val suffix = if (appearance == Appearance.DARK) "dark" else "light"
        compose.onRoot().captureRoboImage("src/test/snapshots/$name.$suffix.png")
    }

    @Composable
    private fun Home(state: HomeState, appearance: Appearance) = HomeScreen(
        state = state, appearance = appearance, onAppearance = {}, onFilter = {}, onRetry = {}, onRefresh = {},
        onOpenVote = {},
    )

    private val loaded get() = HomeState(phase = HomeState.Phase.Loaded, items = recent)
    private val loading = HomeState(phase = HomeState.Phase.Loading)
    private val failed = HomeState(phase = HomeState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."))
    private val empty = HomeState(phase = HomeState.Phase.Loaded, filter = HomeState.Filter.HOUSE, items = emptyList())

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun homeLoadedLight() = snap("homeLoaded", Appearance.LIGHT) { Home(loaded, Appearance.LIGHT) }

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun homeLoadedDark() = snap("homeLoaded", Appearance.DARK) { Home(loaded, Appearance.DARK) }

    @Test
    fun homeLoadingLight() = snap("homeLoading", Appearance.LIGHT) { Home(loading, Appearance.LIGHT) }

    @Test
    fun homeLoadingDark() = snap("homeLoading", Appearance.DARK) { Home(loading, Appearance.DARK) }

    @Test
    fun homeFailedLight() = snap("homeFailed", Appearance.LIGHT) { Home(failed, Appearance.LIGHT) }

    @Test
    fun homeFailedDark() = snap("homeFailed", Appearance.DARK) { Home(failed, Appearance.DARK) }

    @Test
    fun homeEmptyLight() = snap("homeEmpty", Appearance.LIGHT) { Home(empty, Appearance.LIGHT) }

    @Test
    fun homeEmptyDark() = snap("homeEmpty", Appearance.DARK) { Home(empty, Appearance.DARK) }

    @Test
    fun shellFinalsLight() = snap("shellFinals", Appearance.LIGHT) {
        FloorShell(FloorScreens(finals = { Home(loaded, Appearance.LIGHT) }))
    }

    @Test
    fun shellFinalsDark() = snap("shellFinals", Appearance.DARK) {
        FloorShell(FloorScreens(finals = { Home(loaded, Appearance.DARK) }))
    }

    @Test
    fun shellComingSoonLight() = snap("shellWeekComingSoon", Appearance.LIGHT) {
        FloorShell(FloorScreens(finals = { Home(loaded, Appearance.LIGHT) }), initialTab = Tab.WEEK)
    }

    @Test
    fun shellComingSoonDark() = snap("shellWeekComingSoon", Appearance.DARK) {
        FloorShell(FloorScreens(finals = { Home(loaded, Appearance.DARK) }), initialTab = Tab.WEEK)
    }
}
