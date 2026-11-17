package app.floor.android.member

import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.FloorType
import app.floor.android.design.dashedPanel
import app.floor.android.design.FollowButton
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Palette
import app.floor.android.design.Ring
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SectionSwitch
import app.floor.android.design.SkewChip
import app.floor.android.design.panel
import app.floor.android.design.position
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Formats
import app.floor.android.model.Member
import app.floor.android.model.MemberContact
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberVote
import app.floor.android.model.PartyLoyalty
import app.floor.android.model.Position
import app.floor.android.model.RecordFacts
import app.floor.android.model.RecordStats
import app.floor.android.model.Tier
import app.floor.android.model.VoteKind
import app.floor.android.model.dayIn
import app.floor.android.model.fullName
import app.floor.android.model.questionKind
import app.floor.android.model.seatBadge
import app.floor.android.model.seatLine
import app.floor.android.model.shortLabel
import app.floor.android.vote.TopBar
import java.time.ZoneId
import java.util.Locale

/** Follow on a member's header: whether you follow them, whether they are your own rep, and the toggle. */
data class MemberFollow(val following: Boolean, val isRep: Boolean, val onToggle: () -> Unit)

/**
 * One member's record (iOS `RepScreenView`): the player card, Votes · Money · Contact, the three
 * rings, the last-40 grid with its readout, and the computed "did you know". Follow sits above,
 * your own rep reading "Your rep" instead. Money is Funding (FEC, employers and PACs only, never an
 * individual donor) and Disclosures (ranges as filed); Contact dials, writes and links.
 */
@Composable
fun MemberScreen(
    state: MemberState,
    back: String,
    zone: ZoneId,
    locale: Locale,
    onBack: () -> Unit,
    onSection: (MemberSection) -> Unit,
    onMoneySegment: (MoneySegment) -> Unit,
    onSelectCall: (Int) -> Unit,
    onRetry: () -> Unit,
    onRetryMoney: () -> Unit,
    onRetryDisclosures: () -> Unit,
    onOpenVote: (String) -> Unit,
    follow: MemberFollow? = null,
    onPromise: (Int) -> Unit = {},
    onOpenTopic: (String) -> Unit = {},
    onRetryPromises: () -> Unit = {},
    onRetryPosts: () -> Unit = {},
) {
    val colors = Palette
    Column(Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = back, onBack = onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val member = state.member
            if (follow != null && member != null) {
                FollowButton(member, follow.following, follow.isRep, compact = false, onToggle = follow.onToggle)
            }
            val switch: @Composable () -> Unit = {
                SectionSwitch(MemberSection.entries, state.section, { it.title }, onSection)
            }
            when (state.section) {
                MemberSection.RECORD -> RecordContent(state, zone, switch, onSelectCall, onRetry, onOpenVote)
                else -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (member != null) MemberHeader(member)
                    switch()
                    val accounts = state.record.loaded?.detail?.accounts.orEmpty()
                    when (state.section) {
                        MemberSection.MONEY -> {
                            SectionSwitch(MoneySegment.entries, state.moneySegment, { it.title }, onMoneySegment)
                            if (state.moneySegment == MoneySegment.FUNDING) {
                                MoneyContent(state.money, member, onRetryMoney)
                            } else {
                                DisclosuresContent(state.disclosures, member, onRetryDisclosures)
                            }
                        }
                        MemberSection.SAID -> SaidContent(state.promises, member, state.promise, locale, onPromise, onOpenTopic, onRetryPromises)
                        MemberSection.POSTS -> PostsContent(state.posts, member, accounts, zone, locale, onRetryPosts)
                        else -> ContactContent(state.record, onRetry)
                    }
                }
            }
        }
    }
}

@Composable
internal fun Spinner(description: String, top: Int = 44) {
    Box(Modifier.fillMaxWidth().padding(top = top.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = Palette.accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp).semantics { contentDescription = description },
        )
    }
}

@Composable
internal fun TryAgain(onRetry: () -> Unit) {
    Text(
        "Try again",
        style = FloorType.text(15f, FontWeight.SemiBold),
        color = Palette.accent,
        modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onRetry).padding(vertical = 4.dp),
    )
}

/** The compact header Money and Contact put where the player card was. */
@Composable
private fun MemberHeader(member: Member) {
    Row(
        Modifier.semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        MemberPortrait(member, Modifier.size(36.dp))
        Text(member.fullName.uppercase(), style = FloorType.label(24f), color = Palette.text, maxLines = 2)
    }
}

// MARK: - Votes

@Composable
private fun RecordContent(
    state: MemberState,
    zone: ZoneId,
    switch: @Composable () -> Unit,
    onSelectCall: (Int) -> Unit,
    onRetry: () -> Unit,
    onOpenVote: (String) -> Unit,
) {
    val colors = Palette
    when (val record = state.record) {
        Load.Loading -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            switch()
            Spinner("Loading this member")
        }
        is Load.Failed -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            switch()
            Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(record.message, style = FloorType.body(), color = colors.textSecondary)
                TryAgain(onRetry)
            }
        }
        is Load.Loaded -> {
            val detail = record.value.detail
            val votes = record.value.votes
            val stats = RecordStats(votes)
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                record.saved?.let { SavedDataNote(it) }
                PlayerCard(detail)
                switch()
                Rings(detail.partyLoyalty, stats, detail.member)
                Grid(stats, state.selectedCall, zone, onSelectCall, onOpenVote)
                RecordFacts.didYouKnow(detail.member, votes, zone)?.let { text ->
                    val label: @Composable () -> Unit = {
                        Text("DID YOU KNOW", style = FloorType.display(15f, FloorType.Face.BLACK_ITALIC), color = colors.threshold, maxLines = 1)
                    }
                    if (androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.5f) {
                        Column(Modifier.panel(colors).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            label()
                            Text(text, style = FloorType.text(13f), color = colors.textSecondary)
                        }
                    } else {
                        Row(Modifier.panel(colors).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            label()
                            Text(text, style = FloorType.text(13f), color = colors.textSecondary, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

private fun percent(share: Double?): String = share?.let { String.format(Locale.US, "%.1f%%", it * 100) } ?: "—"

@Composable
private fun PlayerCard(detail: MemberDetail) {
    val colors = Palette
    val member = detail.member
    val loyalty = detail.partyLoyalty
    val unity = percent(loyalty.withPartyShare)
    val tier = Tier.of(loyalty.againstParty)
    val spoken = "${member.fullName}, ${member.seatLine}. ${tier.name.lowercase().replaceFirstChar { it.uppercase() }}. " +
        (if (loyalty.withPartyShare == null) "No party-loyalty figure. " else "$unity with party. ") + "${loyalty.againstParty} crossovers."
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Brush.linearGradient(colors.silver))
            .padding(5.dp)
            .clearAndSetSemantics { contentDescription = spoken },
    ) {
        // At the largest sizes the card grows with its text rather than cutting it off.
        val large = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.5f
        Row(
            Modifier.fillMaxWidth()
                .then(if (large) Modifier.heightIn(min = 170.dp) else Modifier.height(170.dp))
                .clip(RoundedCornerShape(14.dp)).background(colors.panel),
        ) {
            MemberPortrait(member, Modifier.width(130.dp).height(170.dp), cornerRadius = 0.dp)
            Column(Modifier.weight(1f).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SkewChip("${tier.name} · ${member.seatBadge}", foreground = colors.silverInk, background = colors.silver[2], size = 11f)
                Text(member.fullName.uppercase(), style = FloorType.label(26f), color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(member.seatLine, style = FloorType.text(11f), color = colors.textMuted, maxLines = 1)
                if (!large) Spacer(Modifier.weight(1f))
                Box(Modifier.fillMaxWidth().height(1.dp).background(colors.panelBorder))
                Row {
                    Column {
                        Text(unity, style = FloorType.label(22f), color = colors.text)
                        Text("W/ PARTY", style = FloorType.text(9f, scales = false), color = colors.textMuted, maxLines = 1)
                    }
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.End) {
                        Text("${loyalty.againstParty}", style = FloorType.label(22f), color = colors.threshold)
                        Text("CROSSOVERS", style = FloorType.text(9f, scales = false), color = colors.textMuted, maxLines = 1)
                    }
                }
            }
        }
    }
}

@Composable
private fun Rings(loyalty: PartyLoyalty, stats: RecordStats, member: Member) {
    val colors = Palette
    val withParty = loyalty.withPartyShare
    val showedSub = when {
        stats.present > 0 -> "${stats.present} present"
        stats.missed > 0 -> "${stats.missed} missed"
        else -> "last ${stats.calls.size}"
    }
    Column(Modifier.panel(colors, padding = 0.dp).padding(vertical = 14.dp, horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth()) {
            RingFigure(
                withParty, colors.yea, percent(withParty), "With party",
                if (withParty == null) "party of one" else "${Formats.count(loyalty.withParty)} of ${Formats.count(loyalty.votes)}",
            )
            RingFigure(stats.showedUpShare, colors.text, "${stats.showedUp}/${stats.calls.size}", "Showed up", showedSub)
            RingFigure(stats.winningShare, colors.nay, "${stats.sidedWithOutcome}/${stats.decided}", "Winning side", "last ${stats.calls.size}")
        }
        // The denominator spelled out (lesson 15): votes where their party had a clear majority.
        Text(
            if (withParty == null) "${member.fullName} sits outside the two parties, so there is no party majority to measure against."
            else "With party counts votes where ${member.party} had a clear majority, not every vote cast.",
            style = FloorType.text(11f),
            color = colors.textMuted,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.RingFigure(share: Double?, color: Color, big: String, label: String, sub: String) {
    val colors = Palette
    Column(
        Modifier.weight(1f).clearAndSetSemantics { contentDescription = "$label: ${if (big == "—") "no figure" else big}, $sub" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Ring(share, color, 6.5.dp, Modifier.size(78.dp)) {
            // Shrinks to fit the ring rather than clipping, as iOS's minimumScaleFactor does.
            val style = FloorType.label(20f).copy(color = colors.text)
            androidx.compose.foundation.text.BasicText(
                big, style = style, maxLines = 1, modifier = Modifier.padding(horizontal = 8.dp),
                autoSize = androidx.compose.foundation.text.TextAutoSize.StepBased(minFontSize = style.fontSize * 0.4f, maxFontSize = style.fontSize),
            )
        }
        Text(label, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.text)
        Text(sub, style = FloorType.text(10f), color = colors.textMuted)
    }
}

@Composable
private fun Grid(stats: RecordStats, selectedCall: Int?, zone: ZoneId, onSelect: (Int) -> Unit, onOpenVote: (String) -> Unit) {
    val colors = Palette
    val calls = stats.calls
    val selected = if (calls.isEmpty()) null else minOf(selectedCall ?: (calls.size - 1), calls.size - 1)
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("LAST ${calls.size} CALLS", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        if (calls.isEmpty()) Text("No votes on record yet.", style = FloorType.text(13f), color = colors.textMuted)
        calls.chunked(10).forEachIndexed { rowIndex, row ->
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                row.forEachIndexed { i, call ->
                    val index = rowIndex * 10 + i
                    Square(call, index == selected, zone, Modifier.weight(1f)) { onSelect(index) }
                }
                repeat(10 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        if (selected != null) Readout(calls[selected], zone) { onOpenVote(calls[selected].vote.id) }
    }
}

/** `Nov 11, H.R. 1013, Nay`, for TalkBack on a grid square. */
private fun spokenSummary(call: MemberVote, zone: ZoneId): String {
    val position = if (call.position == Position.CANDIDATE) call.choice ?: "a candidate"
    else call.position.shortLabel.lowercase().replaceFirstChar { it.uppercase() }
    return listOfNotNull(call.vote.dayIn(zone), call.cite, position).joinToString(", ")
}

@Composable
private fun Square(call: MemberVote, on: Boolean, zone: ZoneId, modifier: Modifier, onClick: () -> Unit) {
    val colors = Palette
    val fill = when (call.position) {
        Position.YEA -> colors.yea
        Position.NAY -> colors.nay
        Position.PRESENT -> colors.textMuted
        Position.CANDIDATE -> colors.textSecondary
        Position.NOT_VOTING -> Color.Transparent
    }
    val dashed = colors.textMuted
    val ring = colors.text
    Canvas(
        modifier
            .aspectRatio(1f)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = spokenSummary(call, zone)
                selected = on
            },
    ) {
        val inset = 1.dp.toPx()
        val r = CornerRadius(4.dp.toPx())
        val inner = androidx.compose.ui.geometry.Size(size.width - inset * 2, size.height - inset * 2)
        val origin = androidx.compose.ui.geometry.Offset(inset, inset)
        drawRoundRect(fill, origin, inner, r)
        if (call.position == Position.NOT_VOTING) {
            val w = 1.5.dp.toPx()
            drawRoundRect(
                dashed, androidx.compose.ui.geometry.Offset(inset + w / 2, inset + w / 2),
                androidx.compose.ui.geometry.Size(inner.width - w, inner.height - w), r,
                style = Stroke(w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))),
            )
        }
        if (on) {
            val w = 2.dp.toPx()
            drawRoundRect(ring, androidx.compose.ui.geometry.Offset(w / 2 - inset, w / 2 - inset),
                androidx.compose.ui.geometry.Size(size.width - w + inset * 2, size.height - w + inset * 2), CornerRadius(5.dp.toPx()), style = Stroke(w))
        }
    }
}

@Composable
private fun Readout(call: MemberVote, zone: ZoneId, onOpen: () -> Unit) {
    val colors = Palette
    val tone = colors.position(call.position)
    val label = if (call.position == Position.CANDIDATE) (call.choice ?: "BALLOT").uppercase() else call.position.shortLabel
    val sided = call.position == Position.YEA || call.position == Position.NAY
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.ground)
            .clickable(role = Role.Button, onClickLabel = "Open the vote", onClick = onOpen)
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            label,
            style = FloorType.label(15f),
            color = if (call.position == Position.NOT_VOTING) colors.textMuted else tone,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(if (sided) tone.copy(alpha = 0.16f) else colors.panelBorder)
                .padding(horizontal = 8.dp, vertical = 2.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text("${call.cite} · ${call.vote.questionKind}", style = FloorType.text(13f, FontWeight.SemiBold), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                listOfNotNull(call.vote.dayIn(zone), call.vote.result).joinToString(" · "),
                style = FloorType.text(11f), color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (call.vote.kind == VoteKind.QUESTION) {
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = colors.yea)) { append("${call.vote.totals.yea}") }
                    withStyle(SpanStyle(color = colors.text)) { append("–") }
                    withStyle(SpanStyle(color = colors.nay)) { append("${call.vote.totals.nay}") }
                },
                style = FloorType.label(20f).copy(fontFeatureSettings = "tnum"),
            )
        }
    }
}

// MARK: - Contact

@Composable
private fun ContactContent(record: Load<MemberRecord>, onRetry: () -> Unit) {
    val colors = Palette
    when (record) {
        Load.Loading -> Spinner("Loading the office's contact", top = 40)
        is Load.Failed -> Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(record.message, style = FloorType.text(13f), color = colors.textSecondary)
            TryAgain(onRetry)
        }
        is Load.Loaded -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            ContactRows(record.value.detail.member, record.value.detail.contact)
            OfficialAccounts(record.value.detail.member, record.value.detail.accounts)
        }
    }
}

/** Where Write goes: the office's form; else the House's find-your-representative form; else the website. */
private const val HOUSE_FIND_YOUR_REP = "https://www.house.gov/representatives/find-your-representative"

/** Phone, write and website for one office (iOS `ContactRows`), and the line under them. */
@Composable
fun ContactRows(member: Member, contact: MemberContact?) {
    val colors = Palette
    val context = LocalContext.current
    val house = member.chamber == app.floor.android.model.Chamber.HOUSE
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        if (contact != null && (contact.phone != null || contact.website != null || contact.contactForm != null || house)) {
            val digits = contact.phone?.filter { it.isDigit() }.orEmpty()
            if (contact.phone != null && digits.isNotEmpty()) {
                ContactRow("☎", contact.phone, contact.office?.let { "Washington office · $it" } ?: "Washington office",
                    "Call ${member.lastName}'s Washington office, ${contact.phone}") {
                    open(context, "tel:$digits", Intent.ACTION_DIAL)
                }
            }
            val write = contact.contactForm ?: if (house) HOUSE_FIND_YOUR_REP else contact.website
            if (write != null) {
                val caption = when {
                    contact.contactForm != null -> "The office's contact form"
                    house -> "House \"Write Your Representative\" form, checks your ZIP"
                    else -> "No form listed, so the official website"
                }
                ContactRow("✎", "Write to the office", caption, "Write to ${member.lastName}'s office") { open(context, write) }
            }
            contact.website?.let { site ->
                val host = runCatching { java.net.URI(site).host }.getOrNull()?.removePrefix("www.") ?: site
                ContactRow("↗", host, "Official website", "${member.lastName}'s official website") { open(context, site) }
            }
        } else {
            Column(
                Modifier.dashedPanel(colors.raised, Color.Transparent, 12.dp).padding(12.dp).semantics(mergeDescendants = true) {},
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("NO CONTACT DETAILS YET", style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.textMuted)
                Text("congress-legislators lists no phone, form or website for ${member.fullName} yet.", style = FloorType.text(12.5f), color = colors.textSecondary)
            }
        }
        Text(
            "Offices count calls and letters from constituents. Contact details from congress-legislators, updated daily.",
            style = FloorType.text(10.5f, FontWeight.Medium),
            color = colors.textMuted,
            modifier = Modifier.padding(start = 2.dp, end = 2.dp, top = 4.dp),
        )
    }
}

@Composable
private fun ContactRow(glyph: String, title: String, caption: String, spoken: String, onClick: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel, shape)
            .border(1.dp, colors.panelBorder, shape)
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = spoken }
            .padding(horizontal = 11.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(28.dp).clip(RoundedCornerShape(8.dp)).background(colors.chip), contentAlignment = Alignment.Center) {
            Text(glyph, style = FloorType.text(13f, FontWeight.SemiBold, scales = false), color = colors.threshold)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, style = FloorType.text(13f, FontWeight.Bold), color = colors.text)
            Text(caption, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted)
        }
    }
}
