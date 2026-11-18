package app.floor.android.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.model.Headline
import app.floor.android.model.News
import app.floor.android.model.Poll
import app.floor.android.model.Tone
import app.floor.android.model.ToneCounts
import java.time.ZoneId
import java.util.Locale

// v0.2.60's shared pieces: the tone dot and bar, a headline row, the AI READ chip and a poll card,
// on the member page's News section, the News page and the Local tab's IN THE NEWS.

/** A tone's colour: favorable yea, neutral the raised grey (`--s3`), critical nay. */
fun FloorColors.tone(tone: Tone?): Color = when (tone) {
    Tone.FAVORABLE -> yea
    Tone.CRITICAL -> nay
    Tone.OFFICE -> textMuted
    Tone.NEUTRAL, null -> raised
}

/** The AI READ chip, in the AI PICKED chip's style. */
@Composable
fun AiReadChip(modifier: Modifier = Modifier) {
    val colors = Palette
    Text(
        "AI READ",
        style = FloorType.text(9f, FontWeight.ExtraBold).copy(letterSpacing = 1.sp),
        color = colors.aiInk,
        maxLines = 1,
        modifier = modifier.clip(RoundedCornerShape(5.dp)).background(colors.ai).padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/**
 * `12 headlines this week · AI READ 1 favorable, 7 neutral, 4 critical`: the chip and the counts
 * only when the week was AI-read. One sentence for TalkBack.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun NewsSummaryLine(count: String, tone: ToneCounts?, spoken: String, size: Float = 13f) {
    val colors = Palette
    // One run of text with the chip inline, so the counts wrap word by word as the mock's line does.
    val text = buildAnnotatedString {
        append(count)
        if (tone != null) {
            append(" · ")
            appendInlineContent(AI_CHIP, "AI READ")
            append(" ${tone.line}")
        }
    }
    val chipWidth = with(LocalDensity.current) { (AI_CHIP_WIDTH.dp * fontScale).toSp() }
    val chipHeight = with(LocalDensity.current) { (AI_CHIP_HEIGHT.dp * fontScale).toSp() }
    Text(
        text,
        style = FloorType.text(size),
        color = colors.textMuted,
        inlineContent = mapOf(
            AI_CHIP to InlineTextContent(Placeholder(chipWidth, chipHeight, PlaceholderVerticalAlign.TextCenter)) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AiReadChip() }
            },
        ),
        modifier = Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = spoken },
    )
}

private const val AI_CHIP = "ai-read"
private const val AI_CHIP_WIDTH = 56f
private const val AI_CHIP_HEIGHT = 17f

/** The tone bar (the mock's `.tone`): proportional segments, 3dp apart, office never counted. */
@Composable
fun ToneBar(tone: ToneCounts, modifier: Modifier = Modifier, height: Dp = 22.dp) {
    val colors = Palette
    val bar = tone.bar
    if (bar.isEmpty()) return
    Row(
        modifier.fillMaxWidth().height(height).clearAndSetSemantics { contentDescription = tone.spoken },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        bar.forEach { (t, share) ->
            Box(Modifier.weight(share).fillMaxHeight().clip(RoundedCornerShape(4.dp)).background(colors.tone(t)))
        }
    }
}

/** A headline's dot: filled in its tone; hollow for the member's own office. */
@Composable
fun ToneDot(tone: Tone?, modifier: Modifier = Modifier) {
    val color = Palette.tone(tone)
    if (tone == Tone.OFFICE) {
        Canvas(modifier.size(8.dp)) {
            val w = 1.5.dp.toPx()
            drawCircle(color, radius = size.minDimension / 2 - w / 2, style = Stroke(w))
        }
    } else {
        Box(modifier.size(8.dp).clip(CircleShape).background(color))
    }
}

/**
 * One headline (the mock's `.hl`): a hairline above, the tone dot, the title, `Source · Nov 17`,
 * and "From their office" on an office release. Opens the publisher's page.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun HeadlineRow(headline: Headline, zone: ZoneId, locale: Locale, showTone: Boolean = true) {
    val colors = Palette
    val context = LocalContext.current
    val tone = if (showTone) headline.toneValue else null
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.cardBorder))
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (headline.url.isNotBlank()) Modifier.clickable(role = Role.Button, onClickLabel = "Open the article") { open(context, headline.url) } else Modifier)
                .clearAndSetSemantics { contentDescription = if (showTone) headline.spoken(zone, locale) else spokenPlain(headline, zone, locale) }
                .padding(vertical = 11.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            ToneDot(tone, Modifier.padding(top = 6.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(headline.title, style = FloorType.text(13.5f, FontWeight.SemiBold).copy(lineHeight = 1.35.em), color = colors.text)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), itemVerticalAlignment = Alignment.CenterVertically) {
                    Text(headline.sourceLine(zone, locale), style = FloorType.text(11.5f), color = colors.textMuted)
                    if (tone == Tone.OFFICE) {
                        Text(
                            "From their office",
                            style = FloorType.text(10f, FontWeight.Bold),
                            color = colors.textSecondary,
                            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(colors.chip).padding(horizontal = 6.dp, vertical = 1.dp),
                        )
                    }
                }
            }
        }
    }
}

private fun spokenPlain(headline: Headline, zone: ZoneId, locale: Locale): String =
    listOfNotNull(headline.title, headline.sourceLine(zone, locale).takeIf { it.isNotBlank() }).joinToString(", ")

/**
 * One poll (the mock's `.poll`): pollster, dates and who was asked; the bar positive / the middle /
 * negative; the shares in the pollster's words under it. Opens the release.
 */
@Composable
fun PollCard(poll: Poll, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val (positive, middle, negative) = poll.bar
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(16.dp))
            .then(if (poll.url.isNotBlank()) Modifier.clickable(role = Role.Button, onClickLabel = "Open the poll's release") { open(context, poll.url) } else Modifier)
            .clearAndSetSemantics { contentDescription = poll.spoken(locale) }
            .padding(horizontal = 14.dp, vertical = 13.dp),
    ) {
        Text(poll.header(locale), style = FloorType.text(13f, FontWeight.Bold), color = colors.text)
        Row(
            Modifier.fillMaxWidth().padding(top = 7.dp, bottom = 5.dp).height(12.dp).clip(RoundedCornerShape(50)).background(colors.track),
        ) {
            if (positive > 0f) Box(Modifier.weight(positive).fillMaxHeight().background(colors.yea))
            if (middle > 0f) Box(Modifier.weight(middle).fillMaxHeight().background(colors.raised))
            if (negative > 0f) Box(Modifier.weight(negative).fillMaxHeight().background(colors.nay))
        }
        val labels = listOfNotNull(
            "${News.percent(poll.positive.pct)} ${poll.positive.label}" to colors.yea,
            poll.other?.let { "${News.percent(it.pct)} ${it.label}" to colors.textMuted },
            "${News.percent(poll.negative.pct)} ${poll.negative.label}" to colors.nay,
        )
        if (largeText()) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                labels.forEach { (text, color) -> Text(text, style = FloorType.text(11.5f, FontWeight.SemiBold), color = color) }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                labels.forEachIndexed { index, (text, color) ->
                    Text(
                        text,
                        style = FloorType.text(11.5f, FontWeight.SemiBold),
                        color = color,
                        textAlign = when (index) {
                            0 -> TextAlign.Start
                            labels.lastIndex -> TextAlign.End
                            else -> TextAlign.Center
                        },
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
            }
        }
    }
}

/** The dashed note an empty state sits in (the mock's `.need`). */
@Composable
fun NeedNote(text: String, modifier: Modifier = Modifier) {
    val colors = Palette
    Text(
        text,
        style = FloorType.text(12.5f).copy(lineHeight = 1.45.em),
        color = colors.textSecondary,
        modifier = modifier.dashedPanel(colors.raised, Color.Transparent, 14.dp).padding(horizontal = 14.dp, vertical = 12.dp),
    )
}

/** A section's title on the News page and the Local tab (the mock's `.sect h3`), a heading for TalkBack. */
@Composable
fun SectTitle(title: String, modifier: Modifier = Modifier) {
    Text(
        title.uppercase(),
        style = FloorType.display(19f),
        color = Palette.text,
        modifier = modifier.padding(top = 12.dp).semantics { heading() },
    )
}
