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
import app.floor.android.local.CitiesScreen
import app.floor.android.local.LocalScreen
import app.floor.android.local.LocalState
import app.floor.android.member.Load
import app.floor.android.member.MemberRecord
import app.floor.android.member.MemberScreen
import app.floor.android.member.MemberSection
import app.floor.android.member.MemberState
import app.floor.android.model.District
import app.floor.android.model.LocalHub
import app.floor.android.model.LocalRegistry
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberNews
import app.floor.android.model.MemberVotes
import app.floor.android.model.Place
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
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/**
 * v0.2.60, against the locked mock (floor-local.html: News & sentiment B, State & city A): the News
 * page (Schumer with a story and three polls; Gillibrand with no story and no poll), the member
 * page's News section, the Local tab's New York State and New York City hubs, the Cities screen,
 * and the five-tab bar; light, dark and at 200%. Headlines are real; their tones are hand-labelled
 * in the fixtures, standing in for the AI read.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h2600dp-xhdpi")
class LocalNewsSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val eastern = ZoneId.of("America/New_York")
    private val today = Instant.parse("2026-11-17T23:00:00Z")

    enum class Look(val suffix: String, val appearance: Appearance, val fontScale: Float) {
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

    // MARK: - News

    private fun member(id: String, detail: String, votes: String, news: String, page: MemberSection? = MemberSection.NEWS) = MemberState(
        record = Load.Loaded(MemberRecord(Fixtures.decode(detail, MemberDetail.serializer()), Fixtures.decode(votes, MemberVotes.serializer()).votes)),
        news = Load.Loaded(Fixtures.decode(news, MemberNews.serializer())),
        page = page,
    )

    private val schumer get() = member("S000148", "arena-schumer-detail", "arena-schumer-votes-40", "news-schumer")
    private val gillibrand get() = member("G000555", "member-detail-gillibrand", "member-votes-gillibrand-40", "news-gillibrand")

    @Composable
    private fun Member(state: MemberState) = MemberScreen(state, "Finals", eastern, Locale.US, {}, {}, {}, {}, {}, {}, {}, {}, now = today)

    @Test
    fun newsSchumerLight() = snap("newsSchumer", Look.LIGHT) { Member(schumer) }

    @Test
    fun newsSchumerDark() = snap("newsSchumer", Look.DARK) { Member(schumer) }

    @Test
    @Config(qualifiers = "w402dp-h6400dp-xhdpi")
    fun newsSchumerLarge() = snap("newsSchumer", Look.LARGE) { Member(schumer) }

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun newsGillibrandLight() = snap("newsGillibrand", Look.LIGHT) { Member(gillibrand) }

    @Test
    @Config(qualifiers = "w402dp-h1600dp-xhdpi")
    fun newsGillibrandDark() = snap("newsGillibrand", Look.DARK) { Member(gillibrand) }

    @Test
    @Config(qualifiers = "w402dp-h3600dp-xhdpi")
    fun newsGillibrandLarge() = snap("newsGillibrand", Look.LARGE) { Member(gillibrand) }

    // MARK: - Local

    private val registry = Fixtures.decode("local-registry", LocalRegistry.serializer())

    /** NY-12, with City Hall's place but no state districts yet: the dashed "look up again" card. */
    private fun local(selected: String) = LocalState(
        district = District(119, "NY", 12, place = Place("3651000", "New York city")),
        registry = Load.Loaded(registry),
        selected = selected,
        hubs = mapOf(
            "ny" to Load.Loaded(Fixtures.decode("local-ny", LocalHub.serializer())),
            "nyc" to Load.Loaded(Fixtures.decode("local-nyc", LocalHub.serializer())),
        ),
    )

    @Composable
    private fun Local(state: LocalState) = LocalScreen(state, eastern, Locale.US, {}, {}, {}, {})

    @Test
    fun localNewYorkLight() = snap("localNewYork", Look.LIGHT) { Local(local("ny")) }

    @Test
    fun localNewYorkDark() = snap("localNewYork", Look.DARK) { Local(local("ny")) }

    @Test
    @Config(qualifiers = "w402dp-h5200dp-xhdpi")
    fun localNewYorkLarge() = snap("localNewYork", Look.LARGE) { Local(local("ny")) }

    @Test
    fun localNewYorkCityLight() = snap("localNewYorkCity", Look.LIGHT) { Local(local("nyc")) }

    @Test
    fun localNewYorkCityDark() = snap("localNewYorkCity", Look.DARK) { Local(local("nyc")) }

    @Test
    @Config(qualifiers = "w402dp-h5200dp-xhdpi")
    fun localNewYorkCityLarge() = snap("localNewYorkCity", Look.LARGE) { Local(local("nyc")) }

    /** Seattle added by hand, New York City from the place. */
    private val cities get() = local("ny").copy(saved = listOf("nyc", "seattle"))

    @Test
    @Config(qualifiers = "w402dp-h1100dp-xhdpi")
    fun citiesLight() = snap("localCities", Look.LIGHT) { CitiesScreen(cities, "Local", {}, {}, {}) }

    @Test
    @Config(qualifiers = "w402dp-h1100dp-xhdpi")
    fun citiesDark() = snap("localCities", Look.DARK) { CitiesScreen(cities, "Local", {}, {}, {}) }

    @Test
    @Config(qualifiers = "w402dp-h2400dp-xhdpi")
    fun citiesLarge() = snap("localCities", Look.LARGE) { CitiesScreen(cities, "Local", {}, {}, {}) }

    /** The five-tab bar, Local chosen, over the New York State hub. */
    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun shellLocalDark() = snap("shellLocal", Look.DARK) {
        FloorShell(FloorScreens(local = { Local(local("ny")) }), initialTab = Tab.LOCAL)
    }
}
