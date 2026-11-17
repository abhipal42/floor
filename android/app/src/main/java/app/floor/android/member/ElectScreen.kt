package app.floor.android.member

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.DashedPlaceholder
import app.floor.android.design.ElectAvatar
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SectionSwitch
import app.floor.android.design.Tones
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Chamber
import app.floor.android.model.ElectProfile
import app.floor.android.model.ElectText
import app.floor.android.model.MemberElect
import app.floor.android.model.MoneyFormat
import app.floor.android.model.PartyName
import app.floor.android.model.StateName
import app.floor.android.model.seatBadge
import app.floor.android.vote.TopBar
import java.util.Locale

/**
 * A member-elect before they take office (iOS `ElectScreenView`, the locked members-elect mock's
 * section B): the member screen's Votes · Money · Contact, each saying plainly what exists yet. As on
 * iOS there is no Follow (following is by Bioguide ID, which most senators-elect lack) and Money
 * shows only the campaign's FEC totals, the one figure the route serves.
 */
@Composable
fun ElectScreen(
    state: ElectState,
    back: String,
    locale: Locale,
    onBack: () -> Unit,
    onSection: (MemberSection) -> Unit,
    onMoneySegment: (MoneySegment) -> Unit,
    onRetry: () -> Unit,
) {
    val colors = Palette
    Column(Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = back, onBack = onBack)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val load = state.profile) {
                Load.Loading -> Spinner("Loading this member-elect", top = 60)
                is Load.Failed -> Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(load.message, style = FloorType.text(13f), color = colors.textSecondary)
                    TryAgain(onRetry)
                }
                is Load.Loaded -> {
                    val profile = load.value
                    if (profile == null) {
                        DashedPlaceholder(
                            "No longer listed",
                            "Floor lists members-elect only until they take office, and this one isn't on the list now. " +
                                "Once sworn in, they're found by name in search.",
                            Modifier.padding(top = 20.dp),
                        )
                    } else {
                        load.saved?.let { SavedDataNote(it) }
                        Hero(profile.elect)
                        SectionSwitch(MemberSection.elect, state.section, { it.title }, onSection)
                        when (state.section) {
                            MemberSection.RECORD -> Votes(profile.elect, locale)
                            MemberSection.MONEY -> {
                                SectionSwitch(MoneySegment.entries, state.moneySegment, { it.title }, onMoneySegment)
                                if (state.moneySegment == MoneySegment.FUNDING) ElectFundingView(profile, locale) else ElectDisclosureView(profile)
                            }
                            MemberSection.CONTACT -> ElectContact(profile.elect, locale)
                            MemberSection.SAID, MemberSection.POSTS -> {}
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Hero(elect: MemberElect) {
    val colors = Palette
    val seat = if (elect.chamber == Chamber.SENATE) StateName.full(elect.state) else elect.asMember.seatBadge
    Row(
        Modifier.padding(vertical = 4.dp).semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ElectAvatar(elect, 54.dp)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(elect.fullName.uppercase(), style = FloorType.headline(30f), color = colors.text, maxLines = 2)
            Text("${elect.title} · $seat · ${PartyName.singular(elect.party)}", style = FloorType.text(12f, FontWeight.Medium), color = colors.textMuted)
        }
    }
}

@Composable
private fun Votes(elect: MemberElect, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val elected = ElectText.electionDay(elect)?.let { ElectText.day(it, locale) }
    val seatName = ElectText.seatName(elect.state, elect.district, elect.chamber)
    val called = ElectText.calledBy(elect.call)
    val title: String
    val line: String
    if (elect.takesOfficeOnCertification) {
        title = "Takes office when ${StateName.full(elect.state)} certifies the result"
        val seat = elect.replaces?.let { "the seat ${it.fullName} holds" } ?: seatName
        line = "Won the special election${elected?.let { " on $it" } ?: ""} for $seat. $called."
    } else {
        title = "Takes office ${ElectText.day(elect.takesOffice, locale) ?: elect.takesOffice}"
        val seat = elect.replaces?.let { "the seat ${it.fullName} is leaving" } ?: seatName
        line = "${elected?.let { "Elected $it" } ?: "Elected"} to $seat. $called."
    }
    val congress = ElectText.congress(elect)?.let { " in the ${StateName.ordinal(it)} Congress" } ?: ""
    val shape = RoundedCornerShape(12.dp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(
            Modifier.fillMaxWidth().clip(shape).background(colors.elect.copy(alpha = Tones.ELECT_TINT), shape)
                .border(1.dp, colors.elect.copy(alpha = 0.35f), shape).padding(horizontal = 11.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title.uppercase(), style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.elect)
            Text(line, style = FloorType.text(11f, FontWeight.Medium), color = colors.textSecondary)
            elect.call.sourceUrl?.let { url ->
                val host = runCatching { java.net.URI(url).host }.getOrNull()?.removePrefix("www.") ?: "the call"
                Source("Source · $host") { open(context, url) }
            }
        }
        DashedPlaceholder("No votes yet", "The record starts with ${elect.lastName}'s first roll call$congress.")
    }
}

/** The FEC's page for them: their candidate id, else the filings link the totals came with. */
private fun fecLink(profile: ElectProfile): Pair<String, String>? {
    profile.elect.fecCandidateId?.let { return "https://www.fec.gov/data/candidate/$it/" to "FEC candidate $it" }
    return profile.funding?.sourceUrl?.let { it to "The FEC's filings" }
}

@Composable
private fun ElectFundingView(profile: ElectProfile, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val funding = profile.funding
    val raised = funding?.receipts
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        if (funding != null && raised != null) {
            ElectLabel("${funding.cycle?.let { "$it campaign" } ?: "Campaign"} · FEC")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Figure("Raised", MoneyFormat.total(raised), MoneyFormat.spoken(raised), Modifier.weight(1f))
                Figure(
                    "Spent", funding.disbursements?.let(MoneyFormat::total) ?: "—",
                    funding.disbursements?.let(MoneyFormat::spoken) ?: "not reported", Modifier.weight(1f),
                )
            }
            var line = "${MoneyFormat.dollars(raised, locale)} raised"
            funding.disbursements?.let { line += " and ${MoneyFormat.dollars(it, locale)} spent" }
            funding.coverageEnd?.let { ElectText.day(it, locale) }?.let { line += ", through $it" }
            line += ", as the campaign reported them to the FEC. Later reports update it."
            Text(line, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp))
        } else {
            DashedPlaceholder(
                "No FEC totals yet",
                "Floor has no campaign totals from the FEC for ${profile.elect.fullName} yet. They show here once it does.",
            )
        }
        fecLink(profile)?.let { (url, text) -> Source(text) { open(context, url) } }
    }
}

@Composable
private fun Figure(title: String, value: String, spoken: String, modifier: Modifier) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier.clip(shape).background(colors.panel, shape).border(1.dp, colors.panelBorder, shape)
            .padding(horizontal = 10.dp, vertical = 9.dp).clearAndSetSemantics { contentDescription = "$title: $spoken" },
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(title.uppercase(), style = FloorType.label(10.5f).copy(letterSpacing = 1.sp), color = colors.textMuted)
        Text(value, style = FloorType.display(21f, FloorType.Face.BLACK_ITALIC).copy(fontFeatureSettings = "tnum"), color = colors.text, maxLines = 1)
    }
}

@Composable
private fun ElectDisclosureView(profile: ElectProfile) {
    val colors = Palette
    val context = LocalContext.current
    val report = profile.disclosure
    if (report == null) {
        DashedPlaceholder(
            "No candidate report in Floor yet",
            "Candidates file a financial disclosure report before the election. When Floor has ${profile.elect.lastName}'s, " +
                "its ranges show here as filed, never a total.",
        )
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        ElectLabel("Assets · candidate report")
        if (report.assets.isEmpty()) {
            Text(
                if (report.paper) "Filed on paper, so Floor links the report rather than reading it." else "The report lists no assets.",
                style = FloorType.text(12f), color = colors.textSecondary, modifier = Modifier.padding(horizontal = 2.dp),
            )
        }
        report.assets.forEach { AssetRange(it) }
        Text(
            "Candidates file the same report members do, before the election. Ranges as filed; Floor doesn't estimate a total.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp),
        )
        report.sourceUrl?.let { url ->
            val filed = report.filedAt?.let(::day)?.let { "Filed $it · " } ?: ""
            Source("${filed}Open the report") { open(context, url) }
        }
    }
}

@Composable
private fun ElectContact(elect: MemberElect, locale: Locale) {
    val colors = Palette
    val certifies = elect.takesOfficeOnCertification
    val whenText = if (certifies) ", once ${StateName.full(elect.state)} certifies the result"
    else " on ${ElectText.day(elect.takesOffice, locale) ?: elect.takesOffice}"
    val holder = elect.replaces?.let { " ${it.fullName} holds the seat until ${if (certifies) "then" else ElectText.takesOffice(elect, locale)}." } ?: ""
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        DashedPlaceholder(
            if (elect.chamber == Chamber.SENATE) "No Senate office yet" else "No House office yet",
            "A Washington phone, contact form and website are assigned at the swearing-in$whenText. Floor adds them that day.",
        )
        Text(
            "Until then, Speak up doesn't offer ${elect.lastName}: offices count messages from constituents of sitting members.$holder",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp),
        )
    }
}

@Composable
private fun ElectLabel(text: String) {
    Text(text.uppercase(), style = FloorType.label(10.5f).copy(letterSpacing = 1.sp), color = Palette.textMuted,
        modifier = Modifier.padding(start = 2.dp, end = 2.dp, top = 2.dp).semantics { heading() })
}
