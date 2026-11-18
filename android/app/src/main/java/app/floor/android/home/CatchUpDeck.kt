package app.floor.android.home

import android.provider.Settings
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.design.FloorColors
import app.floor.android.design.FloorType
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.design.SkewChip
import app.floor.android.design.ThresholdBar
import app.floor.android.design.arenaGround
import app.floor.android.design.edgeBrush
import app.floor.android.design.outcome
import app.floor.android.design.panel
import app.floor.android.model.MeasureSummary
import app.floor.android.model.ThresholdLine
import app.floor.android.model.TopicGroup
import app.floor.android.model.VoteStep
import app.floor.android.model.line
import app.floor.android.model.outcome
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** True when the system's "Remove animations" is on, or a test asks for a still frame. */
@Composable
private fun rememberStill(): Boolean {
    val context = LocalContext.current
    val off = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    return off || !LocalPlaysArrivalAnimations.current
}

/**
 * Catch up (v0.2.59, "Your picks" of the locked mock): the five finals [CatchUp] deals, as a swipe
 * deck of story cards inside the 16dp margins. The top card is dragged sideways to send it off (a
 * crossfade instead when animations are off); two ghost cards peek out below it while two or more
 * are left. [front] past the last card is the all-caught-up state.
 *
 * The ghosts are plain shapes at whole-dp insets and offsets with colour alpha, never a scaled or
 * faded layer, so the screenshot is the same on macOS and Linux (lesson 76).
 */
@Composable
fun CatchUpScreen(
    deck: List<FeedItem>,
    front: Int,
    zone: ZoneId,
    locale: Locale,
    onFront: (Int) -> Unit,
    onClose: () -> Unit,
    onOpen: (FeedItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    Column(
        modifier
            .fillMaxSize()
            .arenaGround(colors)
            .verticalScroll(rememberScrollState())
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Header(deck, front, zone, locale, onClose)
        if (front >= deck.size) {
            CaughtUp(deck.size, onStartOver = { onFront(0) }, onClose = onClose)
        } else {
            Deck(deck, front, zone, locale, onFront, onOpen)
        }
    }
}

@Composable
private fun Header(deck: List<FeedItem>, front: Int, zone: ZoneId, locale: Locale, onClose: () -> Unit) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically) {
        RoundButton("✕", "Close catch up", colors.chip, colors.textSecondary, 34.dp, onClose)
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("CATCH UP", style = FloorType.headline(26f), color = colors.text, modifier = Modifier.semantics { heading() })
            val since = CatchUp.since(deck)?.let { "since ${Stories.format(it, zone, locale)}" }
            val where = if (front < deck.size) "${front + 1} of ${deck.size}" else null
            Text(listOfNotNull(where, since).joinToString(" · "), style = FloorType.text(13f), color = colors.textMuted, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.size(34.dp))
    }
}

@Composable
private fun RoundButton(glyph: String, label: String, fill: Color, ink: Color, size: Dp, onClick: () -> Unit) {
    Box(
        Modifier
            .size(size)
            .dropShadow(CircleShape, Shadow(radius = 10.dp, color = Palette.cardShadow, spread = (-8).dp, offset = DpOffset(0.dp, 8.dp)))
            .clip(CircleShape)
            .background(fill)
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, style = FloorType.text(if (size > 40.dp) 22f else 15f, FontWeight.SemiBold, scales = false), color = ink)
    }
}

@Composable
private fun Deck(deck: List<FeedItem>, front: Int, zone: ZoneId, locale: Locale, onFront: (Int) -> Unit, onOpen: (FeedItem) -> Unit) {
    val colors = Palette
    val still = rememberStill()
    val scope = rememberCoroutineScope()
    val drag = remember { Animatable(0f) }
    val left = deck.size - front - 1
    val next: () -> Unit = { onFront(front + 1) }
    val previous: () -> Unit = { if (front > 0) onFront(front - 1) }
    val ghosts = minOf(2, left)
    Box(Modifier.fillMaxWidth().padding(bottom = if (ghosts == 2) 20.dp else if (ghosts == 1) 10.dp else 0.dp)) {
        if (ghosts >= 2) Ghost(colors, drop = 20.dp, inset = 18.dp, opacity = 0.45f)
        if (ghosts >= 1) Ghost(colors, drop = 10.dp, inset = 9.dp, opacity = 0.7f)
        Crossfade(front, animationSpec = tween(if (still) 220 else 0), label = "deck") { index ->
            val item = deck.getOrNull(index) ?: return@Crossfade
            CatchUpCard(
                item, zone, locale,
                Modifier
                    .offset { IntOffset(drag.value.roundToInt(), 0) }
                    .pointerInput(index, still) {
                        val width = size.width.toFloat()
                        detectHorizontalDragGestures(
                            onDragEnd = {
                                scope.launch {
                                    if (abs(drag.value) > width * 0.25f) {
                                        if (!still) drag.animateTo(if (drag.value > 0) width * 1.4f else -width * 1.4f, tween(260))
                                        drag.snapTo(0f)
                                        next()
                                    } else {
                                        drag.animateTo(0f, tween(180))
                                    }
                                }
                            },
                            onDragCancel = { scope.launch { drag.animateTo(0f) } },
                        ) { change, amount ->
                            change.consume()
                            scope.launch { drag.snapTo(drag.value + amount) }
                        }
                    }
                    .semantics {
                        customActions = listOfNotNull(
                            CustomAccessibilityAction("Next final") { next(); true },
                            if (front > 0) CustomAccessibilityAction("Previous final") { previous(); true } else null,
                        )
                    },
                onOpen = { onOpen(item) },
            )
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        RoundButton("↺", "Previous final", colors.chip, colors.textSecondary, 56.dp, previous)
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Swipe for the next one", style = FloorType.text(12f), color = colors.textMuted, textAlign = TextAlign.Center)
            Text(if (left > 0) "$left left" else "Last one", style = FloorType.text(12f, FontWeight.Bold), color = colors.textSecondary)
        }
        RoundButton("→", "Next final", colors.text, colors.ground, 56.dp, next)
    }
}

@Composable
private fun BoxScope.Ghost(colors: FloorColors, drop: Dp, inset: Dp, opacity: Float) {
    val shape = RoundedCornerShape(22.dp)
    Box(
        Modifier
            .matchParentSize()
            .offset(y = drop)
            .padding(horizontal = inset)
            .clip(shape)
            .background(colors.card.copy(alpha = colors.card.alpha * opacity), shape)
            .border(1.dp, colors.panelBorder.copy(alpha = colors.panelBorder.alpha * opacity), shape),
    )
}

/** One final on the deck: the story card's band, the score, the threshold, the twist, the party split, your members. */
@Composable
private fun CatchUpCard(item: FeedItem, zone: ZoneId, locale: Locale, modifier: Modifier, onOpen: () -> Unit) {
    val colors = Palette
    val vote = item.vote
    val measure = item.measure
    val shape = RoundedCornerShape(22.dp)
    val line = vote.line
    val verdict = Stories.verdict(vote)
    val twist = CatchUp.twist(item)
    val title = measure?.title ?: vote.question
    val spoken = buildString {
        append(title).append(". ")
        verdict?.let { append(it.lowercase().replaceFirstChar(Char::uppercase)).append(", ") }
        append("${VoteStep.name(vote)}, ${Stories.spokenScore(vote)}. ")
        line?.let { append(needed(it)).append(". ") }
        append(twist)
        if (item.positions.isNotEmpty()) {
            append(" ")
            append(item.positions.joinToString(", ") { "${it.member.lastName} ${it.position.name.lowercase().replace('_', ' ')}" })
            append(".")
        }
    }
    Column(
        modifier
            .fillMaxWidth()
            .dropShadow(shape, Shadow(radius = 20.dp, color = colors.storyShadow, spread = (-22).dp, offset = DpOffset(0.dp, 22.dp)))
            .clip(shape)
            .background(colors.card, shape)
            .border(1.dp, edgeBrush(colors.storyEdge, colors.storyEdgeFade), shape)
            .clickable(role = Role.Button, onClickLabel = if (measure?.kind == MeasureSummary.Kind.BILL) "Open the bill" else "Open the vote", onClick = onOpen)
            .semantics { contentDescription = spoken },
    ) {
        Band(item, zone, locale)
        if (line != null) {
            Column(Modifier.clearAndSetSemantics { }.padding(start = 18.dp, end = 18.dp, top = 16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("YEA", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.yea)
                        Text("${line.yea}", style = FloorType.display(64f, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum"), color = colors.yea, maxLines = 1)
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        verdict?.let { SkewChip(it, background = colors.outcome(vote.outcome), size = 13f) }
                        Text("FINAL", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.textMuted)
                    }
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.End) {
                        Text("NAY", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.nay)
                        Text("${line.nay}", style = FloorType.display(64f, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum"), color = colors.nay, maxLines = 1)
                    }
                }
                ThresholdBar(line, Modifier.padding(top = 12.dp), height = 10.dp)
                Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                    Text("${line.cast} voted", style = FloorType.text(11.5f, FontWeight.SemiBold), color = colors.textMuted, modifier = Modifier.weight(1f))
                    Text(needed(line), style = FloorType.text(11.5f, FontWeight.SemiBold), color = colors.threshold)
                }
            }
        }
        Column(
            Modifier.padding(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val twistShape = RoundedCornerShape(12.dp)
            Text(
                androidx.compose.ui.text.buildAnnotatedString {
                    pushStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.Bold, color = colors.threshold))
                    append("The twist")
                    pop()
                    append(" · ")
                    append(twist)
                },
                style = FloorType.text(13f).copy(lineHeight = 18.sp),
                color = colors.text,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(twistShape)
                    .background(colors.threshold.copy(alpha = 0.09f), twistShape)
                    .border(1.dp, colors.threshold.copy(alpha = 0.22f), twistShape)
                    .clearAndSetSemantics { }
                    .padding(horizontal = 12.dp, vertical = 11.dp),
            )
            val parties = item.partyTotals.filter { it.yea + it.nay > 0 }
            if (parties.isNotEmpty()) {
                Column(Modifier.clearAndSetSemantics { }, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    parties.forEach { p ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(p.party, style = FloorType.text(12f, FontWeight.Bold), color = colors.party(p.party), modifier = Modifier.width(22.dp))
                            Row(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(50)).background(colors.track)) {
                                if (p.yea > 0) Box(Modifier.weight(p.yea.toFloat()).fillMaxHeight().background(colors.yea))
                                if (p.nay > 0) Box(Modifier.weight(p.nay.toFloat()).fillMaxHeight().background(colors.nay))
                            }
                            Text("${p.yea}–${p.nay}", style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textSecondary, textAlign = TextAlign.End, maxLines = 1, modifier = Modifier.widthIn(min = 54.dp))
                        }
                    }
                }
            }
            if (item.positions.isNotEmpty()) MemberChips(item.positions.map { StoryMember(it, null) })
        }
    }
}

/** The band: cite chip and `ENERGY · SENATE · SEP 30`, the title, CRS's lead and the step's own sentence. */
@Composable
private fun Band(item: FeedItem, zone: ZoneId, locale: Locale) {
    val colors = Palette
    val ink = colors.bandInk
    val vote = item.vote
    val measure = item.measure
    Column(
        Modifier
            .topicBand(colors, TopicGroup.of(measure))
            .clearAndSetSemantics { }
            .padding(start = 18.dp, end = 18.dp, top = 16.dp, bottom = 18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            measure?.let { SkewChip(it.citation, foreground = colors.verdictInk, background = colors.verdictChip, size = 13f) }
            val eyebrow = listOfNotNull(
                measure?.let { Stories.topicLine(it) },
                vote.chamber.title,
                vote.occurredAtInstant?.let { Stories.format(it, zone, locale) },
            ).joinToString(" · ").uppercase()
            Text(eyebrow, style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 0.8.sp), color = ink.copy(alpha = 0.85f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(
            (measure?.title ?: vote.question).uppercase(),
            style = FloorType.display(30f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 30.sp),
            color = ink,
            modifier = Modifier.padding(top = 10.dp),
        )
        val what = when (measure?.kind) {
            MeasureSummary.Kind.NOMINATION -> measure.position
            MeasureSummary.Kind.BILL -> measure.summaryLead
            null -> null
        }
        val lineStyle = FloorType.text(13.5f).copy(lineHeight = 19.5.sp)
        what?.let { Text(it, style = lineStyle, color = ink.copy(alpha = 0.88f), maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp)) }
        CatchUp.stepSentence(item)?.let { Text(it, style = lineStyle, color = ink.copy(alpha = 0.88f), modifier = Modifier.padding(top = if (what == null) 8.dp else 2.dp)) }
    }
}

/** `Needed 60`, `Needed 289`: the line the yea count had to reach. */
private fun needed(line: ThresholdLine): String = "Needed ${line.needed}"

/** After the last card. */
@Composable
private fun CaughtUp(count: Int, onStartOver: () -> Unit, onClose: () -> Unit) {
    val colors = Palette
    Column(
        Modifier.panel(colors, cornerRadius = 22.dp, padding = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("ALL CAUGHT UP", style = FloorType.headline(30f), color = colors.yea, modifier = Modifier.semantics { heading() })
        Text("$count of $count caught up", style = FloorType.text(13f), color = colors.textMuted)
        Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Pill("Start over", colors.chip, colors.textSecondary, onStartOver)
            Pill("Back to Finals", colors.text, colors.ground, onClose)
        }
    }
}

@Composable
private fun Pill(text: String, fill: Color, ink: Color, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Text(
        text,
        style = FloorType.text(14f, FontWeight.Bold),
        color = ink,
        modifier = Modifier
            .clip(shape)
            .background(fill, shape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
    )
}

/**
 * The Finals tab's way in (iOS `catchUpEntry`): a small stack with the count, the title, and a
 * segment per card, green once seen. The stack is offset plain shapes, never rotated layers.
 */
@Composable
fun CatchUpEntry(deck: List<FeedItem>, seen: Set<String>, onOpen: () -> Unit) {
    val colors = Palette
    val done = deck.count { it.id in seen }
    Row(
        Modifier
            .panel(colors)
            .clickable(role = Role.Button, onClick = onOpen)
            .clearAndSetSemantics { contentDescription = "Catch up, ${deck.size} finals. $done of ${deck.size} caught up" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val card = RoundedCornerShape(8.dp)
        Box(Modifier.size(width = 54.dp, height = 62.dp)) {
            Box(Modifier.offset(x = 8.dp).size(width = 44.dp, height = 56.dp).clip(card).background(colors.panelBorder))
            Box(Modifier.offset(x = 4.dp, y = 2.dp).size(width = 44.dp, height = 56.dp).clip(card).background(colors.raised))
            Box(Modifier.offset(y = 4.dp).size(width = 44.dp, height = 56.dp).clip(card).background(colors.text), contentAlignment = Alignment.Center) {
                Text("${deck.size}", style = FloorType.display(22f, FloorType.Face.BLACK_ITALIC, scales = false), color = colors.ground)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("CATCH UP · ${deck.size} FINALS", style = FloorType.headline(22f), color = colors.text)
            Text("The rule, the score, the twist, your members.", style = FloorType.text(12f), color = colors.textMuted)
            Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                deck.forEach { Box(Modifier.size(width = 22.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(if (it.id in seen) colors.yea else colors.panelBorder)) }
            }
        }
        Text("›", style = FloorType.text(20f), color = colors.textMuted)
    }
}
