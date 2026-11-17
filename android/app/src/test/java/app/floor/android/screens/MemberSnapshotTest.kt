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
import java.time.ZoneId
import java.util.Locale

/**
 * The member screen (Votes, Money's Funding and Disclosures, Contact), the member-elect screen and
 * the vote screen's "Your members", light, dark and at 200%, at the iOS references' width. Compare
 * with `ios/FloorKit/Tests/SnapshotTests/__Snapshots__/{Screen,Round11,Round12}SnapshotTests/`:
 * `repWithUnity`, `memberContact`, `disclosuresOn`, `disclosuresTranscribed`, `disclosuresOff`,
 * `elect*`, `voteWithYourRep`. Portraits are drawn as initials, as iOS's `NoPortraits` draws them.
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

    @Composable
    private fun Member(state: MemberState, follow: MemberFollow? = null) = MemberScreen(
        state, "Finals", eastern, Locale.US, {}, {}, {}, {}, {}, {}, {}, {}, follow,
    )

    /** Cruz's record: iOS's `repWithUnity`. */
    private val cruz get() = MemberState(record = record("cruz", "member-detail-cruz"))

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
        section = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES,
    )

    /** Cornyn: disclosures off, with the API's reason. */
    private val cornynOff get() = MemberState(
        record = record("cornyn", "member-detail-cornyn"),
        disclosures = Load.Loaded(Fixtures.decode("disclosures-off", Disclosures.serializer())),
        section = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES,
    )

    private val follow = MemberFollow(following = false, isRep = false) {}

    @Test fun repLight() = snap("repWithUnity", Look.LIGHT) { Member(cruz, follow) }

    @Test fun repDark() = snap("repWithUnity", Look.DARK) { Member(cruz, follow) }

    @Test
    @Config(qualifiers = "w402dp-h2600dp-xhdpi")
    fun repLarge() = snap("repWithUnity", Look.LARGE) { Member(cruz, follow) }

    @Test fun yourRepLight() = snap("repYourRep", Look.LIGHT) { Member(doggett, MemberFollow(false, isRep = true) {}) }

    @Test fun contactLight() = snap("memberContact", Look.LIGHT) { Member(doggett.copy(section = MemberSection.CONTACT)) }

    @Test fun contactDark() = snap("memberContact", Look.DARK) { Member(doggett.copy(section = MemberSection.CONTACT)) }

    @Test fun contactLarge() = snap("memberContact", Look.LARGE) { Member(doggett.copy(section = MemberSection.CONTACT)) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun fundingLight() = snap("memberFunding", Look.LIGHT) { Member(doggett.copy(section = MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h2000dp-xhdpi")
    fun fundingDark() = snap("memberFunding", Look.DARK) { Member(doggett.copy(section = MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h3600dp-xhdpi")
    fun fundingLarge() = snap("memberFunding", Look.LARGE) { Member(doggett.copy(section = MemberSection.MONEY)) }

    private val disclosuresOn get() = doggett.copy(section = MemberSection.MONEY, moneySegment = MoneySegment.DISCLOSURES)

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
    private fun Elect(state: ElectState) = ElectScreen(state, "Finals", Locale.US, {}, {}, {}, {})

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electVotesLight() = snap("electVotes", Look.LIGHT) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electVotesDark() = snap("electVotes", Look.DARK) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun electVotesLarge() = snap("electVotes", Look.LARGE) { Elect(ElectState(elSayed)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electFundingLight() = snap("electMoneyFunding", Look.LIGHT) { Elect(ElectState(elSayed, MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electFundingDark() = snap("electMoneyFunding", Look.DARK) { Elect(ElectState(elSayed, MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h1800dp-xhdpi")
    fun electFundingLarge() = snap("electMoneyFunding", Look.LARGE) { Elect(ElectState(elSayed, MemberSection.MONEY)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electDisclosuresLight() = snap("electMoneyDisclosures", Look.LIGHT) {
        Elect(ElectState(elSayed, MemberSection.MONEY, MoneySegment.DISCLOSURES))
    }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electDisclosuresDark() = snap("electMoneyDisclosures", Look.DARK) {
        Elect(ElectState(elSayed, MemberSection.MONEY, MoneySegment.DISCLOSURES))
    }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electContactLight() = snap("electContact", Look.LIGHT) { Elect(ElectState(elSayed, MemberSection.CONTACT)) }

    @Test
    @Config(qualifiers = "w402dp-h874dp-xhdpi")
    fun electContactDark() = snap("electContact", Look.DARK) { Elect(ElectState(elSayed, MemberSection.CONTACT)) }

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
