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
import app.floor.android.design.LocalLoadsPortraits
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.model.Bill
import app.floor.android.model.VoteDetail
import app.floor.android.model.VoteKindList
import app.floor.android.vote.VoteKindsScreen
import app.floor.android.vote.VoteKindsState
import app.floor.android.vote.VoteScreen
import app.floor.android.vote.VoteScreenState
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
 * The vote screen and the kinds-of-vote list, light, dark and at the largest font scale Android
 * offers (200%, standing in for iOS's ax5), at the iOS references' 402-point width, 2x. Compare with
 * `ios/FloorKit/Tests/SnapshotTests/__Snapshots__/{Round11,Screen}SnapshotTests/vote*.png`.
 *
 * The vote's time is printed in America/New_York and en-US, passed in, as the iOS tests pin them.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1100dp-xhdpi")
class VoteSnapshotTest {
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

    @Composable
    private fun Vote(state: VoteScreenState) = VoteScreen(
        state = state, zone = eastern, locale = Locale.US, onBack = {}, onRetry = {}, onToggleExplainer = {},
        onOpenKinds = {}, onSelectRollParty = {}, onOpenMeasure = {},
    )

    private fun loaded(fixture: String) =
        VoteScreenState(phase = VoteScreenState.Phase.Loaded(Fixtures.decode(fixture, VoteDetail.serializer())))

    /** H.R. 7008's cloture vote: the one iOS's voteExplainer snapshot draws. */
    private val explained get() = loaded("vote-cloture-explained")

    /** H.R. 1013's House passage, with the bill loaded: the card's "level 3 of 6". */
    private val passage get() = loaded("vote-passage-hr1013").copy(bill = Fixtures.decode("bill-hr1013", Bill.serializer()))

    private val failed = VoteScreenState(phase = VoteScreenState.Phase.Failed("Couldn't reach Floor. Check your connection and try again."))

    private val kinds get() = VoteKindsState.Loaded(Fixtures.decode("vote-kinds", VoteKindList.serializer()).kinds)

    @Test fun explainerLight() = snap("voteExplainer", Look.LIGHT) { Vote(explained) }

    @Test fun explainerDark() = snap("voteExplainer", Look.DARK) { Vote(explained) }

    @Test
    @Config(qualifiers = "w402dp-h2100dp-xhdpi")
    fun explainerLarge() = snap("voteExplainer", Look.LARGE) { Vote(explained) }

    @Test fun explainerFolded() = snap("voteExplainerFolded", Look.LIGHT) { Vote(explained.copy(explainerOpen = false)) }

    @Test fun passageLight() = snap("votePassage", Look.LIGHT) { Vote(passage) }

    @Test fun passageDark() = snap("votePassage", Look.DARK) { Vote(passage) }

    @Test
    @Config(qualifiers = "w402dp-h2100dp-xhdpi")
    fun passageLarge() = snap("votePassage", Look.LARGE) { Vote(passage) }

    @Test fun speakerElectionLight() = snap("voteSpeakerElection", Look.LIGHT) { Vote(loaded("vote-election")) }

    @Test fun speakerElectionDark() = snap("voteSpeakerElection", Look.DARK) { Vote(loaded("vote-election")) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun loadingLight() = snap("voteLoading", Look.LIGHT) { Vote(VoteScreenState()) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun loadingDark() = snap("voteLoading", Look.DARK) { Vote(VoteScreenState()) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun failedLight() = snap("voteFailed", Look.LIGHT) { Vote(failed) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun failedDark() = snap("voteFailed", Look.DARK) { Vote(failed) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun failedLarge() = snap("voteFailed", Look.LARGE) { Vote(failed) }

    @Test
    @Config(qualifiers = "w402dp-h5200dp-xhdpi")
    fun kindsLight() = snap("voteKinds", Look.LIGHT) { VoteKindsScreen(kinds, onBack = {}) }

    @Test
    @Config(qualifiers = "w402dp-h5200dp-xhdpi")
    fun kindsDark() = snap("voteKinds", Look.DARK) { VoteKindsScreen(kinds, onBack = {}) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun kindsFailedLight() = snap("voteKindsFailed", Look.LIGHT) { VoteKindsScreen(VoteKindsState.Failed, onBack = {}) }
}
