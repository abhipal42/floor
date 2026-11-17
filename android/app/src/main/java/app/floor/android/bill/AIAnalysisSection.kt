package app.floor.android.bill

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.invisibleToUser
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.design.FloorType
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.design.Tones
import app.floor.android.design.dashedPanel

// Section E of the locked live/AI design (iOS `AIAnalysisView.swift`): a violet-labelled section at
// the top of the bill, each line with its citation chips, a tapped chip opening the CRS paragraph
// verbatim, and the API's disclaimer under it all. "AI is labelled and cited": the AI tag heads
// every state that draws something, and no line is drawn without a chip.

/** The bill screen's AI section in whichever state [phase] is in. */
@Composable
fun AIAnalysisSection(phase: AnalysisPhase, openCitation: String?, onToggle: (String) -> Unit, onRetry: () -> Unit) {
    when (phase) {
        AnalysisPhase.Loading -> AISkeleton()
        AnalysisPhase.Hidden -> Unit
        AnalysisPhase.NoSummary -> NoSummaryCard()
        is AnalysisPhase.Loaded -> AIAnalysisCard(phase.analysis, openCitation, onToggle)
        AnalysisPhase.Failed -> AIBox {
            AILabel("Couldn't load the AI summary")
            Text(
                "Try again",
                style = FloorType.text(13f, FontWeight.SemiBold),
                color = Palette.ai,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onRetry)
                    .padding(vertical = 4.dp),
            )
        }
    }
}

/** The violet card every AI state draws in: the mock's `.ai`. */
@Composable
private fun AIBox(content: @Composable () -> Unit) {
    val ai = Palette.ai
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Brush.verticalGradient(listOf(ai.copy(alpha = Tones.AI_CARD_TINT), ai.copy(alpha = 0.02f))), shape)
            .border(1.dp, ai.copy(alpha = 0.35f), shape)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) { content() }
}

/** The "AI" tag and what wrote the section: the mock's `.lab`. */
@Composable
private fun AILabel(text: String) {
    val colors = Palette
    Row(
        Modifier.clearAndSetSemantics { contentDescription = "AI. $text" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Text(
            "AI",
            style = FloorType.label(11f).copy(letterSpacing = 1.1.sp),
            color = colors.aiInk,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(colors.ai).padding(horizontal = 6.dp, vertical = 4.dp),
        )
        Text(text, style = FloorType.text(11f, FontWeight.Medium), color = colors.ai)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AIAnalysisCard(analysis: AIAnalysis, openCitation: String?, onToggle: (String) -> Unit) {
    val colors = Palette
    AIBox {
        AILabel("Written by AI from the CRS summary")
        if (analysis.stale) Text(AIAnalysis.STALE_NOTE, style = FloorType.text(11f), color = colors.textSecondary)
        analysis.groups.forEach { group ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    group.heading.uppercase(),
                    style = FloorType.label(11.5f).copy(letterSpacing = 1.15.sp),
                    color = colors.textSecondary,
                    modifier = Modifier.semantics { heading() },
                )
                group.lines.forEach { line ->
                    Column {
                        Text(
                            line.text,
                            style = FloorType.text(13f).copy(lineHeight = 18.sp),
                            color = colors.text,
                            modifier = Modifier.semantics { contentDescription = line.spoken },
                        )
                        // Each chip is a 48dp-tall target (Android's minimum), laid out rather than overhanging.
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            line.citations.forEach { Chip(it, it.id == openCitation, onToggle) }
                        }
                        line.citations.firstOrNull { it.id == openCitation }?.let { Source(analysis, it) }
                    }
                }
            }
        }
        val rule = colors.ai.copy(alpha = 0.2f)
        Text(
            analysis.disclaimer,
            style = FloorType.text(11f),
            color = colors.textSecondary,
            modifier = Modifier
                .fillMaxWidth()
                .drawWithContent {
                    drawRect(rule, size = androidx.compose.ui.geometry.Size(size.width, 1.dp.toPx()))
                    drawContent()
                }
                .padding(top = 8.dp),
        )
    }
}

@Composable
private fun Chip(citation: AIAnalysis.Citation, open: Boolean, onToggle: (String) -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(4.dp)
    Box(
        Modifier
            .defaultMinSize(minHeight = 48.dp)
            .clickable(role = Role.Button) { onToggle(citation.id) }
            .clearAndSetSemantics {
                contentDescription = "Source: ${citation.spoken}"
                selected = open
                onClick(if (open) "Hide the cited paragraph" else "Show the cited paragraph") { onToggle(citation.id); true }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(
            citation.label,
            style = FloorType.mono(11f),
            color = if (open) colors.aiInk else colors.ai,
            modifier = Modifier
                .clip(shape)
                .background(if (open) colors.ai else Color.Transparent, shape)
                .border(1.dp, colors.ai.copy(alpha = 0.45f), shape)
                .padding(horizontal = 4.dp, vertical = 2.dp),
        )
    }
}

/** The cited paragraph, verbatim, under a violet rule. */
@Composable
private fun Source(analysis: AIAnalysis, citation: AIAnalysis.Citation) {
    val colors = Palette
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .padding(vertical = 6.dp)
            .clearAndSetSemantics { contentDescription = analysis.sourceSpoken(citation) },
    ) {
        Box(Modifier.width(2.dp).fillMaxHeight().background(colors.ai))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(analysis.sourceLabel(citation), style = FloorType.label(10.5f).copy(letterSpacing = 1.05.sp), color = colors.textSecondary)
            SelectionContainer {
                Text(
                    citation.source,
                    // Georgia on iOS: the system serif stands in, marking the words as the source's, not Floor's.
                    style = FloorType.text(12.5f).copy(fontFamily = FontFamily.Serif, lineHeight = 17.sp),
                    color = colors.textSecondary,
                )
            }
        }
    }
}

/** While the analysis is being fetched: the label and three shimmering bars, the mock's `.skel`. */
@Composable
private fun AISkeleton() {
    val colors = Palette
    val animates = LocalPlaysArrivalAnimations.current
    val shift = if (animates) {
        rememberInfiniteTransition(label = "skeleton").animateFloat(
            -1f, 1f, infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart), label = "shimmer",
        ).value
    } else {
        null
    }
    AIBox {
        AILabel("Loading the AI summary…")
        listOf(0.9f, 0.7f, 0.8f).forEach { width ->
            Box(
                Modifier
                    .fillMaxWidth(width)
                    .height(10.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(colors.track)
                    .drawWithContent {
                        drawContent()
                        if (shift != null) {
                            val x = shift * size.width
                            drawRect(
                                Brush.horizontalGradient(
                                    listOf(Color.Transparent, colors.raised.copy(alpha = 0.6f), Color.Transparent),
                                    startX = x, endX = x + size.width,
                                ),
                            )
                        }
                    }
                    .semantics { invisibleToUser() },
            )
        }
    }
}

/** No CRS summary, so nothing for a model to write from: the mock's dashed card. */
@Composable
private fun NoSummaryCard() {
    val colors = Palette
    Column(
        Modifier
            .dashedPanel(colors.panelBorder, colors.panel, 14.dp)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text("NO SUMMARY YET", style = FloorType.label(11.5f).copy(letterSpacing = 1.15.sp), color = colors.textMuted)
        Text(
            "CRS hasn't published a summary for this version, so Floor has nothing to explain from. " +
                "The bill's own title and actions are below.",
            style = FloorType.text(13f),
            color = colors.textSecondary,
        )
    }
}
