package app.floor.android.vote

import android.icu.text.DateFormat
import android.icu.util.TimeZone
import android.icu.util.ULocale
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.R
import app.floor.android.design.FloorType
import app.floor.android.design.LitObject
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SkewChip
import app.floor.android.design.ThresholdBar
import app.floor.android.design.outcome
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance
import app.floor.android.model.MeasureSummary
import app.floor.android.model.PartyName
import app.floor.android.model.PartyTotals
import app.floor.android.model.Position
import app.floor.android.model.Spoken
import app.floor.android.model.ThresholdLine
import app.floor.android.model.Vote
import app.floor.android.model.VoteDetail
import app.floor.android.model.VoteExplainer
import app.floor.android.model.VoteKind
import app.floor.android.model.VoteState
import app.floor.android.model.VoteTotals
import app.floor.android.model.line
import app.floor.android.model.outcome
import app.floor.android.model.outcomeWord
import app.floor.android.model.questionKind
import java.time.Instant
import java.time.ZoneId
import java.util.Date
import java.util.Locale

/**
 * "Sep 30, 11:58 AM": when a vote happened, in [zone] and [locale] as the caller passes them (the
 * device's in the app, Eastern in the screenshot tests), never a default zone read behind its back
 * (HANDOFF lesson 69). ICU's skeleton keeps the reader's own order and 12- or 24-hour clock; iOS
 * words the same skeleton "Sep 30 at 11:58 AM".
 */
fun whenLabel(instant: Instant, zone: ZoneId, locale: Locale): String {
    val format = DateFormat.getInstanceForSkeleton("MMMdjmm", ULocale.forLocale(locale))
    format.timeZone = TimeZone.getTimeZone(zone.id)
    return format.format(Date.from(instant))
}

/** At these font scales rows the mock draws side by side stack, as iOS does at accessibility sizes. */
@Composable
private fun largeText(): Boolean = LocalDensity.current.fontScale >= 1.5f

/**
 * One vote, as the locked Vote mock draws it (iOS `VoteScreenView`): what this kind of vote is, a
 * broadcast scoreboard, the threshold bar, the box score by party, the bill, and the full roll as
 * squares by party. A Speaker election gets its own board and the ballot instead.
 *
 * "Your members" needs a district or follows, which arrive in a later phase; without them iOS draws
 * no such section either. The bill card names the bill without its level of six until the bill
 * model lands (see [VoteModel]).
 *
 * @param zone the zone the vote's time is printed in; pass it explicitly (lesson 69).
 */
@Composable
fun VoteScreen(
    state: VoteScreenState,
    zone: ZoneId,
    locale: Locale,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onToggleExplainer: () -> Unit,
    onOpenKinds: () -> Unit,
    onSelectRollParty: (String) -> Unit,
    onOpenMeasure: (MeasureSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    Column(
        modifier
            .fillMaxSize()
            .background(colors.ground)
            .windowInsetsPadding(WindowInsets.statusBars),
    ) {
        val detail = (state.phase as? VoteScreenState.Phase.Loaded)?.detail
        TopBar(back = "Finals", onBack = onBack, trailing = detail?.vote?.let(::rollLabel))
        when (val phase = state.phase) {
            VoteScreenState.Phase.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    color = colors.accent,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(22.dp).semantics { contentDescription = "Loading the vote" },
                )
            }
            is VoteScreenState.Phase.Failed -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(phase.message, style = FloorType.body(), color = colors.textSecondary, textAlign = TextAlign.Center)
                    Text(
                        "Try again",
                        style = FloorType.text(15f, FontWeight.SemiBold),
                        color = colors.accent,
                        modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onRetry)
                            .padding(6.dp),
                    )
                }
            }
            is VoteScreenState.Phase.Loaded -> Loaded(
                state, phase.detail, zone, locale, onToggleExplainer, onOpenKinds, onSelectRollParty, onOpenMeasure,
            )
        }
    }
}

/** `SENATE · ROLL 253`, at the top right as the iOS navigation bar has it. */
private fun rollLabel(vote: Vote): String =
    listOfNotNull(vote.chamber.title.uppercase(), vote.rollNumber?.let { "ROLL $it" }).joinToString(" · ")

/** The back link, and an optional label at the right (the iOS navigation bar, in Floor's type). */
@Composable
internal fun TopBar(back: String, onBack: () -> Unit, trailing: String? = null) {
    val colors = Palette
    Row(
        Modifier.fillMaxWidth().padding(start = 10.dp, end = 16.dp, top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "‹ $back",
            style = FloorType.text(15f, FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier
                .clip(RoundedCornerShape(7.dp))
                .clickable(role = Role.Button, onClick = onBack)
                .semantics { contentDescription = "Back to $back" }
                .padding(horizontal = 6.dp, vertical = 8.dp),
        )
        Spacer(Modifier.weight(1f))
        // Fixed, as a navigation bar's label does not grow.
        if (trailing != null) Text(trailing, style = FloorType.text(12f, scales = false), color = colors.textMuted, maxLines = 1)
    }
}

@Composable
private fun Loaded(
    state: VoteScreenState,
    detail: VoteDetail,
    zone: ZoneId,
    locale: Locale,
    onToggleExplainer: () -> Unit,
    onOpenKinds: () -> Unit,
    onSelectRollParty: (String) -> Unit,
    onOpenMeasure: (MeasureSummary) -> Unit,
) {
    val vote = detail.vote
    val day = vote.occurredAtInstant?.let { whenLabel(it, zone, locale) }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        state.saved?.let { SavedDataNote(it) }
        // No explainer is no card: an unknown kind of vote gets no line, never a guess.
        vote.explainer?.let { ExplainerCard(it, state.explainerOpen, onToggleExplainer, onOpenKinds) }
        if (vote.kind == VoteKind.ELECTION) {
            ElectionBoard(detail, day)
            CandidateTable(detail)
        } else {
            Broadcast(detail, day)
            vote.line?.let { ThresholdSection(it, vote.totals) }
            BoxScore(detail)
        }
        detail.measure?.let { MeasureLink(it, onOpenMeasure) }
        if (vote.kind == VoteKind.QUESTION && detail.rollParties.isNotEmpty()) {
            FullRoll(detail, state.rollParty, onSelectRollParty)
        }
    }
}

// MARK: - What this vote is

/**
 * "What this vote is" (round 11, section B): one hand-written line on what the vote does and
 * doesn't do, with the rule it rests on. Written by Floor from House and Senate rules, not AI.
 * Folds to its header; "?" opens every kind of vote.
 */
@Composable
private fun ExplainerCard(explainer: VoteExplainer, open: Boolean, onToggle: () -> Unit, onOpenKinds: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel, shape)
            .border(1.dp, colors.raised, shape)
            .padding(horizontal = 11.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(role = Role.Button, onClick = onToggle)
                    .defaultMinSize(minHeight = 28.dp)
                    .clearAndSetSemantics {
                        contentDescription = "What this vote is"
                        stateDescription = if (open) "Expanded" else "Collapsed"
                        onClick(if (open) "Fold the explanation" else "Show the explanation") { onToggle(); true }
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("WHAT THIS VOTE IS", style = FloorType.label(11f).copy(letterSpacing = 1.1.sp), color = colors.threshold)
                Icon(
                    painterResource(if (open) R.drawable.ic_chevron_up else R.drawable.ic_chevron_down),
                    contentDescription = null,
                    tint = colors.threshold,
                    modifier = Modifier.size(16.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            Box(
                Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(role = Role.Button, onClick = onOpenKinds)
                    .defaultMinSize(minWidth = 30.dp, minHeight = 28.dp)
                    .clearAndSetSemantics {
                        contentDescription = "Kinds of vote"
                        onClick("List every kind of vote and what each one does") { onOpenKinds(); true }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text("?", style = FloorType.label(15f), color = colors.threshold)
            }
        }
        if (open) {
            Text(explainer.text, style = FloorType.text(12.5f).copy(lineHeight = 17.5.sp), color = colors.text)
            Text(
                explainer.source,
                style = FloorType.mono(10f),
                color = colors.textMuted,
                modifier = Modifier.semantics { contentDescription = "Source: ${explainer.source}" },
            )
        }
    }
}

// MARK: - Scoreboard

/** The broadcast scoreboard's turf: a lit display, so it stays dark in light mode. */
@Composable
private fun Turf(content: @Composable () -> Unit) {
    LitObject {
        val colors = Palette
        val shape = RoundedCornerShape(18.dp)
        Box(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .drawBehind {
                    val stripe = 48.dp.toPx()
                    var x = 0f
                    var alt = false
                    while (x < size.width) {
                        drawRect(if (alt) colors.turfAlt else colors.turf, Offset(x, 0f), Size(stripe, size.height))
                        x += stripe
                        alt = !alt
                    }
                }
                .border(1.dp, colors.turfBorder, shape),
        ) { content() }
    }
}

/** The line above the scores: what kind of vote and when, and what it needed. Wraps when it can't fit. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun BoardHeader(lead: String, need: String) {
    val colors = Palette
    FlowRow(
        Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(lead, style = FloorType.text(11f), color = colors.textSecondary, modifier = Modifier.padding(end = 8.dp))
        Text(need, style = FloorType.text(11f, FontWeight.SemiBold), color = colors.threshold)
    }
}

@Composable
private fun Broadcast(detail: VoteDetail, day: String?) {
    val vote = detail.vote
    val spoken = Spoken.scoreboard(vote, detail.measure?.title ?: vote.question, detail.measure?.citation, day)
    Turf {
        val colors = Palette
        Column(Modifier.clearAndSetSemantics { contentDescription = spoken }) {
            BoardHeader(listOfNotNull(vote.questionKind, day).joinToString(" · "), "NEEDED ${vote.votesNeeded}")
            Row(
                Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 14.dp),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterHorizontally),
            ) {
                BigSide("YEA", vote.totals.yea, colors.yea, Modifier.weight(1f, fill = false))
                SkewChip(if (vote.state == VoteState.FINAL) "FINAL" else "VOTING", size = 16f, modifier = Modifier.padding(bottom = 26.dp))
                BigSide("NAY", vote.totals.nay, colors.nay, Modifier.weight(1f, fill = false))
            }
            OutcomeStrip(
                word = vote.outcomeWord ?: "FINAL",
                wordColor = colors.ground,
                wordBackground = colors.outcome(vote.outcome),
                title = detail.title,
            )
        }
    }
}

/**
 * The result word beside the title, as the mock draws it, or above it at large font scales, where a
 * word column beside the title leaves the title a few letters a line.
 */
@Composable
private fun OutcomeStrip(word: String, wordColor: Color, wordBackground: Color, title: String) {
    val colors = Palette
    val large = largeText()
    val wordText = @Composable { mod: Modifier ->
        Box(mod.background(wordBackground).padding(horizontal = 12.dp, vertical = if (large) 6.dp else 0.dp), contentAlignment = Alignment.CenterStart) {
            Text(word, style = FloorType.label(15f), color = wordColor, maxLines = 1)
        }
    }
    val titleText = @Composable { mod: Modifier ->
        Text(
            title,
            style = FloorType.text(13f, FontWeight.SemiBold),
            color = colors.text,
            maxLines = if (large) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis,
            modifier = mod.background(colors.ground.copy(alpha = 0.92f)).padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
    if (large) {
        Column(Modifier.fillMaxWidth()) {
            wordText(Modifier.fillMaxWidth())
            titleText(Modifier.fillMaxWidth())
        }
    } else {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            wordText(Modifier.fillMaxHeight())
            titleText(Modifier.weight(1f))
        }
    }
}

@Composable
private fun BigSide(label: String, value: Int, color: Color, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = FloorType.label(14f).copy(letterSpacing = 1.7.sp), color = color, maxLines = 1)
        ShrinkingNumber(value, color, 96f)
    }
}

/** A big score: fixed size, never wrapping, shrinking to as little as half to fit its column. */
@Composable
private fun ShrinkingNumber(value: Int, color: Color, size: Float, modifier: Modifier = Modifier) {
    val style = FloorType.display(size, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum")
    BasicText(
        "$value",
        style = style.copy(color = color, textAlign = TextAlign.Center),
        maxLines = 1,
        autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize / 2, maxFontSize = style.fontSize),
        modifier = modifier,
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ThresholdSection(line: ThresholdLine, totals: VoteTotals) {
    val colors = Palette
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ThresholdBar(line, height = 12.dp)
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val over = line.over
            val short = line.short
            when {
                over != null -> Text(
                    if (over == 1) "1 vote over the line" else "$over votes over the line",
                    style = FloorType.caption(), color = colors.textMuted, modifier = Modifier.padding(end = 8.dp),
                )
                short != null -> Text("$short short", style = FloorType.caption(), color = colors.nay, modifier = Modifier.padding(end = 8.dp))
            }
            if (totals.notVoting > 0) Text("${totals.notVoting} did not vote", style = FloorType.caption(), color = colors.textMuted)
        }
    }
}

// MARK: - Box score

@Composable
private fun BoxScore(detail: VoteDetail) {
    val colors = Palette
    val present = detail.anyPresent
    val totals = detail.vote.totals
    val large = largeText()
    // A number column, wide enough for three digits at the reader's font size.
    val cell = with(LocalDensity.current) { 34.sp.toDp() }
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("BOX SCORE", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        Column {
            val head = FloorType.text(11f, FontWeight.SemiBold)
            ScoreRow(
                cell, Modifier.padding(vertical = 6.dp), team = { Text("TEAM", style = head, color = colors.textMuted, maxLines = 1) },
                cells = listOfNotNull(
                    "YEA" to colors.textMuted, "NAY" to colors.textMuted,
                    if (present) "PRES" to colors.textMuted else null, "DNP" to colors.textMuted,
                ),
                style = head,
            )
            detail.boxScore.forEach { row ->
                HorizontalDivider(color = colors.panelBorder)
                val name = PartyName.plural(row.party)
                val spoken = "$name: ${row.yea} yea, ${row.nay} nay, " +
                    (if (present) "${row.present} present, " else "") + "${row.notVoting} did not vote"
                Column(Modifier.clearAndSetSemantics { contentDescription = spoken }) {
                    // At large sizes "Republicans" and four numbers cannot share a row, so the
                    // team's name takes a row of its own above its numbers.
                    if (large) {
                        Text(name, style = FloorType.text(14f, FontWeight.SemiBold), color = colors.text, modifier = Modifier.padding(top = 9.dp))
                    }
                    ScoreRow(
                        cell, Modifier.padding(vertical = 9.dp),
                        team = {
                            if (!large) {
                                Text(name, style = FloorType.text(14f, FontWeight.SemiBold), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        },
                        cells = listOfNotNull(
                            "${row.yea}" to colors.yea, "${row.nay}" to colors.nay,
                            if (present) "${row.present}" to colors.textMuted else null, "${row.notVoting}" to colors.textMuted,
                        ),
                        style = FloorType.text(14f).copy(fontFeatureSettings = "tnum"),
                        bold = 2,
                    )
                }
            }
            HorizontalDivider(color = colors.panelBorder)
            val totalSpoken = "Total: ${totals.yea} yea, ${totals.nay} nay, " +
                (if (present) "${totals.present} present, " else "") + "${totals.notVoting} did not vote"
            ScoreRow(
                cell, Modifier.padding(vertical = 9.dp).clearAndSetSemantics { contentDescription = totalSpoken },
                team = { Text("TOTAL", style = FloorType.label(18f), color = colors.text, maxLines = 1) },
                cells = listOfNotNull(
                    "${totals.yea}" to colors.yea, "${totals.nay}" to colors.nay,
                    if (present) "${totals.present}" to colors.textMuted else null, "${totals.notVoting}" to colors.textMuted,
                ),
                style = FloorType.label(18f).copy(fontFeatureSettings = "tnum"),
            )
        }
        detail.crossoverSentence?.let {
            Text(
                it, style = FloorType.caption().copy(lineHeight = 17.sp), color = colors.textSecondary,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/** One box-score row: the team, then fixed-width number columns. The first [bold] numbers are bold. */
@Composable
private fun ScoreRow(
    cell: Dp,
    modifier: Modifier,
    team: @Composable () -> Unit,
    cells: List<Pair<String, Color>>,
    style: TextStyle,
    bold: Int = 0,
) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) { team() }
        // Five columns cannot grow without limit on a phone: past what fits, a cell shrinks (to 40%,
        // as on iOS) rather than wrapping a number or clipping a heading.
        cells.forEachIndexed { index, (text, color) ->
            val cellStyle = if (index < bold) style.copy(fontWeight = FontWeight.Bold) else style
            BasicText(
                text,
                style = cellStyle.copy(color = color, textAlign = TextAlign.Center),
                maxLines = 1,
                autoSize = TextAutoSize.StepBased(minFontSize = cellStyle.fontSize * 0.4f, maxFontSize = cellStyle.fontSize),
                modifier = Modifier.padding(start = 8.dp).width(cell),
            )
        }
    }
}

// MARK: - Speaker election

@Composable
private fun ElectionBoard(detail: VoteDetail, day: String?) {
    val vote = detail.vote
    val leaders = detail.candidatesByStrength.take(2)
    val elected = vote.electedSpeaker
    val spoken = Spoken.scoreboard(vote, vote.question, null, day)
    Turf {
        val colors = Palette
        Column(Modifier.clearAndSetSemantics { contentDescription = spoken }) {
            BoardHeader(listOfNotNull(vote.question, day).joinToString(" · "), "MAJORITY OF NAMES CAST")
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 14.dp),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterHorizontally),
            ) {
                leaders.forEachIndexed { index, entry ->
                    Column(Modifier.weight(1f, fill = false), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            entry.candidate.uppercase(), style = FloorType.label(14f).copy(letterSpacing = 1.2.sp),
                            color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        ShrinkingNumber(entry.total, if (index == 0) colors.text else colors.trailing, 80f)
                    }
                }
            }
            // Leading a ballot is not winning it: 17 of the 20 Speaker ballots since 2023 elected
            // nobody (HANDOFF lesson 16).
            OutcomeStrip(
                word = if (elected == null) "NO WINNER" else "ELECTED",
                wordColor = if (elected == null) colors.text else colors.ground,
                wordBackground = if (elected == null) colors.raised else colors.yea,
                title = elected?.let { "${it.name} elected Speaker" } ?: "No candidate reached a majority; the House balloted again.",
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CandidateTable(detail: VoteDetail) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("BALLOT", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        detail.candidatesByStrength.forEach { entry ->
            HorizontalDivider(color = colors.panelBorder)
            val split = entry.parties.joinToString(" · ") { "${it.party} ${it.total}" }
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp)
                    .clearAndSetSemantics { contentDescription = "${entry.candidate}, ${entry.total}: $split" },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FlowRow(Modifier.weight(1f), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(entry.candidate, style = FloorType.text(14f, FontWeight.SemiBold), color = colors.text, modifier = Modifier.padding(end = 8.dp))
                    Text(split, style = FloorType.caption(), color = colors.textMuted)
                }
                Text(
                    "${entry.total}", style = FloorType.label(18f).copy(fontFeatureSettings = "tnum"), color = colors.text,
                    modifier = Modifier.padding(start = 12.dp),
                )
            }
        }
    }
}

// MARK: - The bill

@Composable
private fun MeasureLink(measure: MeasureSummary, onOpen: (MeasureSummary) -> Unit) {
    val colors = Palette
    if (measure.kind == MeasureSummary.Kind.BILL) {
        Row(
            Modifier
                .clip(RoundedCornerShape(16.dp))
                .clickable(role = Role.Button, onClickLabel = "Open the bill") { onOpen(measure) }
                .panel(colors),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("THE BILL · ${measure.citation}", style = FloorType.text(11f), color = colors.textMuted)
                Text(measure.title, style = FloorType.text(15f, FontWeight.SemiBold), color = colors.text)
            }
            Spacer(Modifier.width(12.dp))
            Text("›", style = FloorType.text(20f), color = colors.textMuted)
        }
    } else {
        // A nomination has no screen of its own yet, so this is information, not a link.
        Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("THE NOMINATION · ${measure.citation}", style = FloorType.text(11f), color = colors.textMuted)
            Text(measure.title, style = FloorType.text(15f, FontWeight.SemiBold), color = colors.text)
        }
    }
}

// MARK: - Full roll

/**
 * The full roll as squares by party. The API reports a vote's party counts, not every member's
 * position, so the squares are counts and carry no names; the caption says so (as on iOS).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FullRoll(detail: VoteDetail, rollParty: String?, onSelect: (String) -> Unit) {
    val colors = Palette
    val parties = detail.rollParties
    val selected = parties.firstOrNull { it.party == rollParty } ?: parties[0]
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, itemVerticalAlignment = Alignment.Bottom) {
            Text("FULL ROLL", style = FloorType.label(20f), color = colors.text, modifier = Modifier.padding(end = 8.dp).semantics { heading() })
            Text("${detail.rollCount} members", style = FloorType.caption(), color = colors.textMuted, modifier = Modifier.padding(bottom = 2.dp))
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            parties.forEach { party ->
                val on = party.party == selected.party
                Text(
                    PartyName.plural(party.party),
                    style = FloorType.text(12f, FontWeight.SemiBold),
                    color = if (on) colors.ground else colors.textSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(7.dp))
                        .background(if (on) colors.text else Color.Transparent)
                        .clickable(role = Role.Tab) { onSelect(party.party) }
                        .semantics { this.selected = on }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
        Squares(selected)
        Text("One square per member, by count: yea · nay · present · did not vote.", style = FloorType.caption(), color = colors.textMuted)
    }
}

@Composable
private fun Squares(party: PartyTotals) {
    val colors = Palette
    val columns = 22
    val spoken = "${PartyName.plural(party.party)}: ${party.yea} yea, ${party.nay} nay, " +
        "${party.present} present, ${party.notVoting} did not vote"
    val squares = party.squares
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val gap = 2.dp
        val side = (maxWidth - gap * (columns - 1)) / columns
        val rows = (squares.size + columns - 1) / columns
        val height = if (rows == 0) 0.dp else side * rows + gap * (rows - 1)
        Canvas(Modifier.fillMaxWidth().height(height).clearAndSetSemantics { contentDescription = spoken }) {
            val s = side.toPx()
            val g = gap.toPx()
            val r = CornerRadius(2.dp.toPx())
            squares.forEachIndexed { i, position ->
                val color = when (position) {
                    Position.YEA -> colors.yea
                    Position.NAY -> colors.nay
                    Position.PRESENT -> colors.textMuted
                    Position.NOT_VOTING, Position.CANDIDATE -> colors.raised
                }
                drawRoundRect(color, Offset((i % columns) * (s + g), (i / columns) * (s + g)), Size(s, s), r)
            }
        }
    }
}
