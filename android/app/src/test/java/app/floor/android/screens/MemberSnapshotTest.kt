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
import app.floor.android.member.ElectScreen
import app.floor.android.member.ElectState
import app.floor.android.member.Load
import app.floor.android.member.MemberFollow
import app.floor.android.member.MemberRecord
import app.floor.android.member.MemberScreen
import app.floor.android.member.MemberSection
import app.floor.android.member.MemberState
import app.floor.android.member.MoneySegment
import app.floor.android.model.Delegation
import app.floor.android.model.Disclosures
import app.floor.android.model.ElectProfile
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberFunding
import app.floor.android.model.MemberPosts
import app.floor.android.model.Promises
import app.floor.android.model.MemberVotes
import app.floor.android.model.VoteDetail
import app.floor.android.vote.VoteScreen
import app.floor.android.vote.VoteScreenState
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
 * The one-scroll member page (Arena, v0.2.58: Schumer with everything, recorded from the live API on
 * Nov 17, 2026), its sections on their own screens (all 40 votes, Money's Funding and Disclosures),
 * the member-elect page and the vote screen's "Your members", light, dark and at 200%, at the iOS
 * references' width. Compare with `ios/FloorKit/Tests/SnapshotTests/__Snapshots__/`: `memberOneScroll`,
 * `repWithUnity`, `disclosuresOn`, `disclosuresTranscribed`, `disclosuresOff`, `electOneScroll`,
 * `voteWithYourRep`. Portraits are drawn as initials, as iOS's `NoPortraits` draws them.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h1400dp-xhdpi")
class MemberSnapshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val eastern = ZoneId.of("America/New_York")

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

    private fun record(id: String, detail: String) = Load.Loaded(
        MemberRecord(Fixtures.decode(detail, MemberDetail.serializer()), Fixtures.decode("member-votes-$id-40", MemberVotes.serializer()).votes),
    )

    /** The evening the Arena mock was locked: Schumer's posts of the day print their time alone. */
    private val today = Instant.parse("2026-11-17T23:00:00Z")

    @Composable
    private fun Member(state: MemberState, follow: MemberFollow? = null) = MemberScreen(
        state, "Finals", eastern, Locale.US, {}, {}, {}, {}, {}, {}, {}, {}, follow, now = today,
    )

    /** Schumer with everything: his record, promises, posts and funding, as the API served them. */
    private val schumer get() = MemberState(
        record = Load.Loaded(
            MemberRecord(
                Fixtures.decode("arena-schumer-detail", MemberDetail.serializer()),
                Fixtures.decode("arena-schumer-votes-40", MemberVotes.serializer()).votes,
            ),
        ),
        promises = Load.Loaded(Fixtures.decode("arena-schumer-promises", Promises.serializer())),
        posts = Load.Loaded(Fixtures.decode("arena-schumer-posts", MemberPosts.serializer())),
        money = Load.Loaded(Fixtures.decode("arena-schumer-funding", MemberFunding.serializer())),
        // v0.2.60: the week's news (real headlines, tones hand-labelled), between Posts and Money.
        news = Load.Loaded(Fixtures.decode("news-schumer", app.floor.android.model.MemberNews.serializer())),
    )

    /** New York's senator, read from NY-12: "YOUR SENATOR · NEW YORK", no Follow on the hero. */
    private val yourSenator = MemberFollow(following = false, isRep = true) {}

    @Test
    @Config(qualifiers = "w402dp-h3000dp-xhdpi")
    fun oneScrollLight() = snap("memberOneScroll", Look.LIGHT) { Member(schumer, yourSenator) }

    @Test
    @Config(qualifiers = "w402dp-h3000dp-xhdpi")
    fun oneScrollDark() = snap("memberOneScroll", Look.DARK) { Member(schumer, yourSenator) }

    @Test
    @Config(qualifiers = "w402dp-h6400dp-xhdpi")
    fun oneScrollLarge() = snap("memberOneScroll", Look.LARGE) { Member(schumer, yourSenator) }

    /** Followed, not yours: the hero's Follow pill reads "Following ✓" and the eyebrow "FOLLOWING". */
    @Test
    fun oneScrollFollowedDark() = snap("memberOneScrollFollowed", Look.DARK) {
        Member(schumer, MemberFollow(following = true, isRep = false) {})
    }

    /** Cruz's record, "All 40 ›" on its own screen: iOS's `repWithUnity`. */
    private val cruz get() = MemberState(record = record("cruz", "member-detail-cruz"), page = MemberSection.RECORD)

    /** Doggett: Contact (no form, so Write goes to the House's), Funding, and disclosures on. */
    private val doggett get() = MemberState(
        record = record("doggett", "member-detail-doggett"),
        money = Load.Loaded(Fixtures.decode("funding-D000399", MemberFunding.serializer())),
        disclosures = Load.Loaded(Fixtures.decode("disclosures-doggett", Disclosures.serializer())),
    )

    /** Nadler's handwritten report, transcribed by Floor's AI. */
    private val nadler get() = MemberState(
        record = Load.Loaded(MemberRecord(Fixtures.decode("member-detail-nadler", MemberDetail.serializer()), emptyList())),
        disclosures = Load.Loaded(Fixtures.decode("disclosures-nadler", Disclosures.serializer())),
        page = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES,
    )

    /** Cornyn: disclosures off, with the API's reason. */
    private val cornynOff get() = MemberState(
        record = record("cornyn", "member-detail-cornyn"),
        disclosures = Load.Loaded(Fixtures.decode("disclosures-off", Disclosures.serializer())),
        page = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES,
    )

    private val follow = MemberFollow(following = false, isRep = false) {}

    @Test fun repLight() = snap("repWithUnity", Look.LIGHT) { Member(cruz, follow) }

    @Test fun repDark() = snap("repWithUnity", Look.DARK) { Member(cruz, follow) }

    @Test
    @Config(qualifiers = "w402dp-h2600dp-xhdpi")
    fun repLarge() = snap("repWithUnity", Look.LARGE) { Member(cruz, follow) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun fundingLight() = snap("memberFunding", Look.LIGHT) { Member(doggett.copy(page = MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun fundingDark() = snap("memberFunding", Look.DARK) { Member(doggett.copy(page = MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h3600dp-xhdpi")
    fun fundingLarge() = snap("memberFunding", Look.LARGE) { Member(doggett.copy(page = MemberSection.MONEY)) }

    private val disclosuresOn get() = doggett.copy(page = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES)

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun disclosuresOnLight() = snap("disclosuresOn", Look.LIGHT) { Member(disclosuresOn) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun disclosuresOnDark() = snap("disclosuresOn", Look.DARK) { Member(disclosuresOn) }

    @Test
    @Config(qualifiers = "w402dp-h5200dp-xhdpi")
    fun disclosuresOnLarge() = snap("disclosuresOn", Look.LARGE) { Member(disclosuresOn) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun disclosuresTranscribedLight() = snap("disclosuresTranscribed", Look.LIGHT) { Member(nadler) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun disclosuresTranscribedDark() = snap("disclosuresTranscribed", Look.DARK) { Member(nadler) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun disclosuresOffLight() = snap("disclosuresOff", Look.LIGHT) { Member(cornynOff) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun disclosuresOffDark() = snap("disclosuresOff", Look.DARK) { Member(cornynOff) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun memberFailedLight() = snap("memberFailed", Look.LIGHT) {
        Member(MemberState(record = Load.Failed("Couldn't reach Floor. Check your connection and try again.")))
    }

    // MARK: - Members-elect

    private val elSayed get() = Load.Loaded(Fixtures.decode("member-elect-mi-sen", ElectProfile.serializer()))

    @Composable
    private fun Elect(state: ElectState) = ElectScreen(state, "Finals", Locale.US, {}, {})

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun electLight() = snap("electOneScroll", Look.LIGHT) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h1400dp-xhdpi")
    fun electDark() = snap("electOneScroll", Look.DARK) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h3000dp-xhdpi")
    fun electLarge() = snap("electOneScroll", Look.LARGE) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electNoLongerListedLight() = snap("electNoLongerListed", Look.LIGHT) { Elect(ElectState(Load.Loaded(null))) }

    // MARK: - The vote screen's "Your members"

    private val austin get() = Fixtures.decode("reps-location-austin", Delegation.serializer())

    /** Cloture on H.R. 7008 with Austin's senators: both yea, Doggett in the other chamber. */
    private val withYourMembers
        get() = VoteScreenState(
            phase = VoteScreenState.Phase.Loaded(Fixtures.decode("vote-cloture-explained", VoteDetail.serializer())),
            members = austin.members,
            explainerOpen = false,
        )

    @Composable
    private fun Vote(state: VoteScreenState) = VoteScreen(state, eastern, Locale.US, {}, {}, {}, {}, {}, {})

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun voteYourMembersLight() = snap("voteWithYourRep", Look.LIGHT) { Vote(withYourMembers) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun voteYourMembersDark() = snap("voteWithYourRep", Look.DARK) { Vote(withYourMembers) }

    @Test
    @Config(qualifiers = "w402dp-h4000dp-xhdpi")
    fun voteYourMembersLarge() = snap("voteWithYourRep", Look.LARGE) { Vote(withYourMembers) }
}
