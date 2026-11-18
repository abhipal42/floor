package app.floor.android.member

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.FloorType
import app.floor.android.design.glass
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.dashedPanel
import app.floor.android.design.panel
import app.floor.android.model.DisclosedAsset
import app.floor.android.model.DisclosedTrade
import app.floor.android.model.Disclosures
import app.floor.android.model.Formats
import app.floor.android.model.Funding
import app.floor.android.model.Member
import app.floor.android.model.MemberFunding
import app.floor.android.model.MoneyFormat
import app.floor.android.model.PacCheck
import java.time.Instant
import java.time.ZoneOffset

// The member screen's Money: Funding (built to the locked AppRepMoney mock) and Disclosures (round
// 11, section G), as iOS `MoneyView.swift` and `ContactAndDisclosures.swift` draw them.


@Composable
fun MoneyContent(load: Load<MemberFunding>, member: Member?, onRetry: () -> Unit) {
    val colors = Palette
    val name = member?.lastName ?: "this member"
    when (load) {
        Load.Loading -> Column(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Spinner("Loading $name's FEC figures", top = 0)
            Text("Loading $name's FEC figures…", style = FloorType.text(12f), color = colors.textMuted)
        }
        is Load.Failed -> Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Couldn't load $name's FEC figures", style = FloorType.text(15f, FontWeight.SemiBold), color = colors.text)
            Text(load.message, style = FloorType.text(13f), color = colors.textSecondary)
            TryAgain(onRetry)
        }
        is Load.Loaded -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            load.saved?.let { SavedDataNote(it) }
            val funding = load.value.funding
            if (funding != null) {
                FundingFigures(funding)
            } else {
                val (title, body) = load.value.noFilings
                Column(Modifier.panel(colors).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(title, style = FloorType.label(20f), color = colors.text)
                    Text(body, style = FloorType.text(13f), color = colors.textSecondary)
                }
            }
        }
    }
}

/** The totals card, the context line, the PAC list and the explainer placeholder. */
@Composable
fun FundingFigures(funding: Funding) {
    val colors = Palette
    val large = largeText()
    val parts = listOf(
        Funding.Part.SMALL_DOLLAR to colors.yea, Funding.Part.ITEMIZED to colors.teal,
        Funding.Part.PAC to colors.threshold, Funding.Part.OTHER to colors.dim,
    )
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        // Totals
        Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val raised = MoneyFormat.total(funding.receipts)
            val cash = funding.cashOnHand?.let(MoneyFormat::total)
            val spoken = "${funding.period}. Raised ${MoneyFormat.spoken(funding.receipts)}." +
                (funding.cashOnHand?.let { " Cash on hand ${MoneyFormat.spoken(it)}." } ?: " No cash-on-hand figure.")
            Column(Modifier.clearAndSetSemantics { contentDescription = spoken }, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(funding.period, style = FloorType.text(11f), color = colors.textMuted)
                val big: @Composable () -> Unit = { Text(raised, style = FloorType.display(54f), color = colors.text, maxLines = 1) }
                val cashStack: @Composable () -> Unit = {
                    Column(horizontalAlignment = if (large) Alignment.Start else Alignment.End) {
                        Text("cash on hand", style = FloorType.text(11f), color = colors.textMuted)
                        Text(cash ?: "—", style = FloorType.label(20f), color = colors.text)
                    }
                }
                if (large) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { big(); cashStack() }
                } else {
                    Row(verticalAlignment = Alignment.Bottom) {
                        big()
                        Spacer(Modifier.weight(1f).width(8.dp))
                        cashStack()
                    }
                }
            }
            // The bar: decorative, the legend says the same.
            val base = funding.shareBase
            Canvas(Modifier.fillMaxWidth().height(18.dp).clip(RoundedCornerShape(6.dp)).background(colors.panelBorder)) {
                val gap = 2.dp.toPx()
                val usable = size.width - gap * (parts.size - 1)
                var x = 0f
                parts.forEach { (part, color) ->
                    val w = if (base > 0) (usable * funding.shown(part) / base).toFloat() else 0f
                    drawRect(color, androidx.compose.ui.geometry.Offset(x, 0f), androidx.compose.ui.geometry.Size(w, size.height))
                    x += w + gap
                }
            }
            // The legend, two columns (one at the largest sizes).
            val rows = if (large) parts.map { listOf(it) } else parts.chunked(2)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                rows.forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        row.forEach { (part, color) ->
                            Row(
                                Modifier.weight(1f).clearAndSetSemantics {
                                    contentDescription = "${part.label}: ${funding.percent(part)}, ${MoneyFormat.spoken(funding.shown(part))}"
                                },
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(Modifier.size(9.dp).clip(RoundedCornerShape(2.dp)).background(color))
                                Text(part.label, style = FloorType.text(12f), color = colors.text, modifier = Modifier.weight(1f))
                                Text(funding.percent(part), style = FloorType.text(12f, FontWeight.Bold).copy(fontFeatureSettings = "tnum"), color = colors.text)
                            }
                        }
                    }
                }
            }
            funding.adjustmentNote?.let { Text(it, style = FloorType.text(11f), color = colors.textMuted) }
        }
        // Context, not cause.
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = colors.threshold, fontFamily = FloorType.barlowCondensed, fontWeight = FontWeight.ExtraBold,
                    fontStyle = androidx.compose.ui.text.font.FontStyle.Italic, fontSize = 13.sp)) { append("CONTEXT, NOT CAUSE · ") }
                withStyle(SpanStyle(color = colors.textSecondary)) { append("who gave, shown beside the record. Never why.") }
            },
            style = FloorType.text(12f),
            modifier = Modifier.dashedPanel(colors.threshold, Color.Transparent, 10.dp).padding(horizontal = 10.dp, vertical = 8.dp),
        )
        PacList(funding)
        // The donor explainer: nothing in it is written by a model; it says what will be here and why not yet.
        Column(
            Modifier.dashedPanel(colors.ai, colors.panel, 16.dp, dash = 5f, gap = 4f).padding(14.dp).semantics(mergeDescendants = true) {},
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("✦ FLOOR EXPLAINS · AI", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 0.7.sp), color = colors.ai)
            Text("NOT LOADED YET", style = FloorType.label(22f), color = colors.text)
            Text(
                "Who each PAC is and what it lobbies on, beside any of this member's votes on the same topic. It needs Senate " +
                    "lobbying filings, which Floor doesn't read yet, and every line will be labelled as AI-written and cited to its filing.",
                style = FloorType.text(13f), color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun PacList(funding: Funding) {
    val colors = Palette
    val checks = funding.pacChecks()
    val shape = RoundedCornerShape(16.dp)
    Column(Modifier.fillMaxWidth().glass(colors, shape)) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("BIGGEST PAC CHECKS", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
            Text(funding.pacsNote, style = FloorType.text(11f), color = colors.textMuted)
        }
        if (checks.isEmpty()) {
            val (title, body) = funding.pacsNone
            Hairline()
            Column(Modifier.padding(horizontal = 14.dp, vertical = 11.dp).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = FloorType.text(13f, FontWeight.SemiBold), color = colors.text)
                Text(body, style = FloorType.text(12f), color = colors.textMuted)
            }
        }
        checks.forEach { PacRow(it) }
        Hairline()
        Text(
            "Totals are what the campaign reported receiving; this list is what committees reported giving. " +
                "They come from different FEC filings and won't add up.",
            style = FloorType.text(11f), color = colors.textMuted,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

@Composable
private fun Hairline() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.panelBorder))
}

@Composable
private fun PacRow(check: PacCheck) {
    val colors = Palette
    val large = largeText()
    val spoken = listOfNotNull(check.displayName, check.kind, MoneyFormat.dollars(check.direct)).joinToString(", ")
    Hairline()
    val detail: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            check.kind?.let {
                Text(it, style = FloorType.text(11f), color = colors.textSecondary, maxLines = 1,
                    modifier = Modifier.border(1.dp, colors.raised, RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 1.dp))
            }
            Text(MoneyFormat.check(check.direct), style = FloorType.label(17f).copy(fontFeatureSettings = "tnum"), color = colors.text, maxLines = 1)
        }
    }
    val title: @Composable (Modifier) -> Unit = { m -> Text(check.displayName, style = FloorType.text(13f, FontWeight.SemiBold), color = colors.text, modifier = m) }
    val modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp).clearAndSetSemantics { contentDescription = spoken }
    if (large) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) { title(Modifier); detail() }
    } else {
        Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            title(Modifier.weight(1f))
            detail()
        }
    }
}

// MARK: - Disclosures

@Composable
fun DisclosuresContent(load: Load<Disclosures>, member: Member?, onRetry: () -> Unit) {
    val colors = Palette
    when (load) {
        Load.Loading -> Spinner("Loading the disclosures", top = 40)
        is Load.Failed -> Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Couldn't load ${member?.lastName ?: "this member"}'s disclosures", style = FloorType.text(15f, FontWeight.SemiBold), color = colors.text)
            Text(load.message, style = FloorType.text(13f), color = colors.textSecondary)
            TryAgain(onRetry)
        }
        is Load.Loaded -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            load.saved?.let { SavedDataNote(it) }
            DisclosuresFigures(load.value)
        }
    }
}

/** An annual report's first eight assets show until "+ N more" is tapped. */
private const val ASSETS_SHOWN = 8

/**
 * The disclosures as filed: assets in ranges, trades with how long they took to file, paper filings
 * as links. **Never a total.** Off, the visible placeholder with the API's reason.
 */
@Composable
fun DisclosuresFigures(disclosures: Disclosures) {
    val colors = Palette
    val context = LocalContext.current
    if (!disclosures.enabled) {
        DisclosuresOff(disclosures.reason)
        return
    }
    var allAssets by rememberSaveable { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        val annual = disclosures.annual
        if (annual != null) {
            Label(listOfNotNull("ASSETS", annual.year?.let { "$it ANNUAL REPORT" }, if (annual.amendment) "AMENDED" else null).joinToString(" · "))
            if (annual.transcribed) TranscribedNote()
            if (annual.assets.isEmpty()) Note("The report lists no assets.")
            val shown = if (allAssets) annual.assets.size else minOf(annual.assets.size, ASSETS_SHOWN)
            annual.assets.take(shown).forEach { AssetRange(it) }
            if (shown < annual.assets.size) {
                Text(
                    "+ ${annual.assets.size - shown} more assets",
                    style = FloorType.text(11.5f, FontWeight.SemiBold), color = colors.threshold,
                    modifier = Modifier.clickable(role = Role.Button) { allAssets = true }.padding(horizontal = 2.dp, vertical = 6.dp),
                )
            }
            annual.sourceUrl?.let { url ->
                val filed = annual.filedAt?.let(::day)?.let { "Filed $it · " } ?: ""
                Source("${filed}Open the report") { open(context, url) }
            }
        } else {
            Label("ASSETS")
            Note("No annual report on file in Floor yet.")
        }
        Spacer(Modifier.height(4.dp))
        Label("TRADES · LAST 12 MONTHS")
        if (disclosures.trades.isEmpty()) Note("No trades reported in the last 12 months.")
        disclosures.trades.forEach { trade ->
            // The filed name usually carries the ticker already: "Coca-Cola Company (KO)".
            val ticker = trade.ticker?.takeIf { !trade.asset.contains("($it)") }?.let { " ($it)" } ?: ""
            Range("${trade.verb} · ${trade.asset}$ticker", trade.amount, tradeLine(trade, disclosures.deadline), flagged = trade.pastDeadline)
        }
        if (disclosures.paperFilings.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Label("PAPER FILINGS")
            disclosures.paperFilings.forEach { filing ->
                val kind = if (filing.kind == "ptr") "Trade report" else "Annual report"
                val text = listOfNotNull(
                    kind + (filing.reportYear?.let { " $it" } ?: ""),
                    filing.filedAt?.let(::day)?.let { "filed $it" },
                    if (filing.status == "unparsed") "Floor couldn't read it" else "scanned, not read",
                ).joinToString(" · ")
                val url = filing.sourceUrl
                if (url != null) Source(text) { open(context, url) } else Note(text)
            }
        }
        Text(
            "From the member's own filings. Ranges as filed; Floor doesn't estimate a total. A home is listed only when it earns income.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted,
            modifier = Modifier.padding(start = 2.dp, end = 2.dp, top = 4.dp),
        )
    }
}

@Composable
private fun DisclosuresOff(reason: String?) {
    val colors = Palette
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = colors.threshold, fontWeight = FontWeight.Bold)) { append("NOT LOADED YET  ") }
                withStyle(SpanStyle(color = colors.textSecondary)) { append(reason ?: "Financial disclosures aren't available in Floor yet.") }
            },
            style = FloorType.text(11f),
            modifier = Modifier.dashedPanel(colors.threshold, Color.Transparent, 10.dp).padding(horizontal = 10.dp, vertical = 8.dp),
        )
        Column(Modifier.panel(colors).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("REPORTED ASSETS · RANGES, AS FILED", style = FloorType.text(11f).copy(letterSpacing = 0.7.sp), color = colors.textMuted)
            Text(
                "Members report what they own and owe in value bands, and leave out a home unless it earns income. When this loads, " +
                    "Floor will show those ranges as filed, and their trades — never a single net-worth figure.",
                style = FloorType.text(13f), color = colors.textSecondary,
            )
        }
    }
}

/** `Traded Mar 3 · filed Apr 10 · 38 days`; past the deadline it says so, as a fact. */
private fun tradeLine(trade: DisclosedTrade, deadline: Int): String {
    val parts = mutableListOf<String>()
    owner(trade.owner)?.let { parts += it }
    trade.transactedAt?.let(::day)?.let { parts += "Traded $it" }
    trade.filedAt?.let(::day)?.let { parts += "filed $it" }
    val days = trade.daysToFile
    if (days != null) {
        parts += if (trade.pastDeadline) "filed $days days after, past the $deadline-day deadline" else "$days ${if (days == 1) "day" else "days"}"
    } else if (trade.pastDeadline) {
        parts += "filed after the $deadline-day deadline"
    }
    return parts.joinToString(" · ")
}

/** `Spouse`, `Joint`, `Dependent child`; null for the member's own. */
fun owner(owner: String?): String? = when (owner) {
    "spouse" -> "Spouse"
    "joint" -> "Joint"
    "dependent" -> "Dependent child"
    else -> null
}

/** A calendar day or an instant, as `Jul 28, 2025`. */
fun day(text: String): String? {
    if (text.length == 10) return Formats.dayText(text)
    return try {
        Formats.dayText(Instant.parse(text).atOffset(ZoneOffset.UTC).toLocalDate().toString())
    } catch (_: Exception) {
        Formats.dayText(text)
    }
}

@Composable
private fun Label(text: String) {
    Text(text, style = FloorType.label(10.5f).copy(letterSpacing = 1.sp), color = Palette.textMuted,
        modifier = Modifier.padding(horizontal = 2.dp).semantics { heading() })
}

@Composable
private fun Note(text: String) {
    Text(text, style = FloorType.text(12f), color = Palette.textSecondary, modifier = Modifier.padding(horizontal = 2.dp))
}

@Composable
internal fun Source(text: String, onOpen: () -> Unit) {
    Text("$text ›", style = FloorType.text(11.5f, FontWeight.SemiBold), color = Palette.yea,
        modifier = Modifier.clickable(role = Role.Button, onClick = onOpen).padding(horizontal = 2.dp, vertical = 2.dp))
}

@Composable
internal fun AssetRange(asset: DisclosedAsset) {
    Range(asset.name, asset.value, listOfNotNull(asset.type, owner(asset.owner), asset.account).joinToString(" · "))
}

/** The mock's `.rg`: what it is, its range as filed, and a line of detail. */
@Composable
internal fun Range(title: String, value: String?, detail: String, flagged: Boolean = false) {
    val colors = Palette
    val shape = RoundedCornerShape(10.dp)
    val large = largeText()
    Column(
        Modifier.fillMaxWidth().glass(colors, shape)
            .padding(horizontal = 10.dp, vertical = 8.dp).semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        val valueText: @Composable () -> Unit = {
            Text(value ?: "Not stated", style = FloorType.mono(11.5f, FontWeight.Bold), color = colors.textSecondary)
        }
        if (large) {
            Text(title, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.text)
            valueText()
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f))
                valueText()
            }
        }
        if (detail.isNotEmpty()) Text(detail, style = FloorType.text(10f, FontWeight.Medium), color = if (flagged) colors.nay else colors.textMuted)
    }
}

/**
 * The AI tag on rows Floor's AI read off a paper filing (product rule "AI is labelled and cited"):
 * AI, "may contain errors", and the report link stays right under the rows.
 */
@Composable
fun TranscribedNote() {
    val colors = Palette
    Row(
        Modifier.padding(horizontal = 2.dp).clearAndSetSemantics { contentDescription = "AI. $TRANSCRIBED_TEXT" },
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Text("AI", style = FloorType.label(11f).copy(letterSpacing = 1.1.sp), color = colors.aiInk,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(colors.ai).padding(vertical = 4.dp, horizontal = 6.dp))
        Text(TRANSCRIBED_TEXT, style = FloorType.text(11f, FontWeight.Medium), color = colors.ai, modifier = Modifier.weight(1f))
    }
}

const val TRANSCRIBED_TEXT = "Transcribed by Floor's AI from a handwritten filing. May contain errors; check the original below."
