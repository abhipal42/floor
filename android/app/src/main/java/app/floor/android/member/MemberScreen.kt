package app.floor.android.member

import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
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
import app.floor.android.design.glass
import app.floor.android.design.dashedPanel
import app.floor.android.design.Palette
import app.floor.android.design.Ring
import app.floor.android.design.panel
import app.floor.android.design.position
import app.floor.android.model.Formats
import app.floor.android.model.Member
import app.floor.android.model.MemberContact
import app.floor.android.model.MemberVote
import app.floor.android.model.PartyLoyalty
import app.floor.android.model.Position
import app.floor.android.model.RecordStats
import app.floor.android.model.VoteKind
import app.floor.android.model.dayIn
import app.floor.android.model.fullName
import app.floor.android.model.questionKind
import app.floor.android.model.shortLabel
import java.time.ZoneId
import java.util.Locale

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

private fun percent(share: Double?): String = share?.let { String.format(Locale.US, "%.1f%%", it * 100) } ?: "—"

@Composable
internal fun Rings(loyalty: PartyLoyalty, stats: RecordStats, member: Member) {
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
internal fun Grid(stats: RecordStats, selectedCall: Int?, zone: ZoneId, onSelect: (Int) -> Unit, onOpenVote: (String) -> Unit) {
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

/** Where Write goes: the office's form; else the House's find-your-representative form; else the website. */
private const val HOUSE_FIND_YOUR_REP = "https://www.house.gov/representatives/find-your-representative"

/**
 * One office's contact (iOS `ContactRows`, Arena's `.callbtn`): the big call button in yea green
 * with the number and the office, then the contact form, the website and the mailing address as
 * rows, and the line under them.
 */
@Composable
fun ContactRows(member: Member, contact: MemberContact?) {
    val colors = Palette
    val context = LocalContext.current
    val house = member.chamber == app.floor.android.model.Chamber.HOUSE
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        if (contact != null && (contact.phone != null || contact.website != null || contact.contactForm != null || house)) {
            val digits = contact.phone?.filter { it.isDigit() }.orEmpty()
            if (contact.phone != null && digits.isNotEmpty()) {
                val shape = RoundedCornerShape(16.dp)
                Column(
                    Modifier.fillMaxWidth().clip(shape).background(colors.yea, shape)
                        .clickable(role = Role.Button) { open(context, "tel:$digits", Intent.ACTION_DIAL) }
                        .clearAndSetSemantics { contentDescription = "Call ${member.lastName}'s Washington office, ${contact.phone}" }
                        .padding(14.dp),
                ) {
                    Text(contact.phone, style = FloorType.display(22f, FloorType.Face.BLACK_ITALIC).copy(fontFeatureSettings = "tnum"), color = colors.callInk)
                    Text(contact.office?.let { "Washington office · $it" } ?: "Washington office", style = FloorType.text(12f), color = colors.callInk)
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
            contact.address?.takeIf { it.isNotBlank() }?.let { address ->
                ContactRow("✉", address, "Mailing address", "${member.lastName}'s mailing address, $address") {
                    open(context, "geo:0,0?q=" + android.net.Uri.encode(address))
                }
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
internal fun ContactRow(glyph: String, title: String, caption: String, spoken: String, onClick: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .glass(colors, shape)
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
