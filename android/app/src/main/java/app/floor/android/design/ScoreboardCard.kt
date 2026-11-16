package app.floor.android.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.model.Spoken
import app.floor.android.model.Vote
import app.floor.android.model.VoteKind
import app.floor.android.model.VoteState
import app.floor.android.model.line
import app.floor.android.model.outcome
import app.floor.android.model.outcomeWord
import app.floor.android.model.questionKind
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** `Nov 11`: a card's day, in the reader's zone, as the iOS cards print it. */
fun Vote.dayText(zone: ZoneId = ZoneId.systemDefault()): String? =
    occurredAtInstant?.atZone(zone)?.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))

/**
 * A final, as the locked Home mock draws it (iOS `ScoreboardCard`): chamber tag, citation and date,
 * what it needed, the title, the two scores either side of the result, the threshold bar, and the
 * kind of question.
 *
 * The score row is a fixed 36dp side label, a flexible score, a fixed 84dp result, the mirror; the
 * scores shrink to fit their column, so a three-digit House total never wraps. A Speaker election
 * has no yea or nay, so it gets its own body. TalkBack reads the whole card as one sentence.
 *
 * Members' chips in the footer arrive with the delegation (a later phase); the feed has none yet.
 */
@Composable
fun ScoreboardCard(vote: Vote, title: String, citation: String?, modifier: Modifier = Modifier) {
    val colors = Palette
    val day = vote.dayText()
    val spoken = Spoken.scoreboard(vote, title, citation, day)
    Column(
        modifier
            .panel(colors)
            .clearAndSetSemantics { contentDescription = spoken },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SkewChip(vote.chamber.title.uppercase())
            Spacer(Modifier.width(8.dp))
            Text(
                listOfNotNull(citation, day).joinToString(" · "),
                style = FloorType.text(11f),
                color = colors.textMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                if (vote.kind == VoteKind.ELECTION) "MAJORITY OF NAMES" else vote.line?.label.orEmpty(),
                style = FloorType.text(11f, FontWeight.SemiBold),
                color = colors.threshold,
                maxLines = 1,
            )
        }
        Text(
            title,
            style = FloorType.text(15f, FontWeight.SemiBold).copy(lineHeight = 21.sp),
            color = colors.text,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        val line = vote.line
        if (vote.kind == VoteKind.ELECTION) {
            ElectionBody(vote)
        } else if (line != null) {
            ScoreRow(vote)
            ThresholdBar(line)
        }
        Text(vote.questionKind, style = FloorType.text(12f), color = colors.textMuted, maxLines = 1)
    }
}

@Composable
private fun ScoreRow(vote: Vote) {
    val colors = Palette
    // The side labels stay at the mock's 13 like the scores: they name the columns of a fixed row.
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "YEA", style = FloorType.display(13f, scales = false), color = colors.yea, maxLines = 1,
            modifier = Modifier.width(36.dp),
        )
        Score(vote.totals.yea, colors.yea, Modifier.weight(1f))
        Box(Modifier.width(84.dp), contentAlignment = Alignment.Center) { ResultChip(vote) }
        Score(vote.totals.nay, colors.nay, Modifier.weight(1f))
        Text(
            "NAY", style = FloorType.display(13f, scales = false), color = colors.nay, maxLines = 1,
            textAlign = TextAlign.End, modifier = Modifier.width(36.dp),
        )
    }
}

@Composable
private fun ResultChip(vote: Vote) {
    val colors = Palette
    when (vote.state) {
        VoteState.FINAL -> SkewChip(vote.outcomeWord ?: "FINAL", background = colors.outcome(vote.outcome), size = 13f)
        VoteState.OPEN -> SkewChip("VOTING", background = colors.liveText, size = 13f)
        VoteState.SCHEDULED -> SkewChip("SOON", background = colors.scheduled, size = 13f)
    }
}

/** A score that shrinks to as little as half size to fit its column, never wrapping. */
@Composable
private fun Score(value: Int, color: Color, modifier: Modifier = Modifier) {
    val style = FloorType.score(48f)
    BasicText(
        "$value",
        style = style.copy(color = color, textAlign = TextAlign.Center),
        maxLines = 1,
        autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize / 2, maxFontSize = style.fontSize),
        modifier = modifier,
    )
}

/**
 * A Speaker ballot: who led, by how much, and whether anyone reached a majority of the votes cast
 * for a person. Leading a ballot is not winning it (HANDOFF lesson 16).
 */
@Composable
private fun ElectionBody(vote: Vote) {
    val colors = Palette
    val leaders = vote.candidates.sortedByDescending { it.total }.take(2)
    val castForAPerson = vote.candidates.sumOf { it.total }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            leaders.forEachIndexed { index, candidate ->
                val align = if (index == 0) Alignment.Start else Alignment.End
                Column(Modifier.weight(1f), horizontalAlignment = align) {
                    Text(
                        candidate.name.uppercase(), style = FloorType.label(13f), color = colors.textSecondary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Score(
                        candidate.total, if (index == 0) colors.text else colors.trailing,
                        Modifier.fillMaxWidth(),
                    )
                }
                if (index == 0) {
                    when {
                        // Counting is not over: ELECTED or NO WINNER would call it early.
                        vote.state != VoteState.FINAL -> SkewChip(
                            if (vote.state == VoteState.OPEN) "VOTING" else "SOON",
                            background = if (vote.state == VoteState.OPEN) colors.liveText else colors.scheduled,
                            size = 13f,
                        )
                        vote.electedSpeaker == null ->
                            SkewChip("NO WINNER", foreground = colors.text, background = colors.raised, size = 13f)
                        else -> SkewChip("ELECTED", foreground = colors.ground, background = colors.yea, size = 13f)
                    }
                }
            }
        }
        val share = if (castForAPerson > 0) (leaders.firstOrNull()?.total ?: 0).toFloat() / castForAPerson else 0f
        Canvas(Modifier.fillMaxWidth().height(6.dp)) {
            val r = CornerRadius(size.height / 2, size.height / 2)
            drawRoundRect(colors.panelBorder, cornerRadius = r)
            drawRoundRect(colors.text, size = Size(size.width * share, size.height), cornerRadius = r)
            val extra = 4.dp.toPx()
            drawRect(
                colors.threshold, topLeft = Offset(size.width * 0.5f, -extra),
                size = Size(2.dp.toPx(), size.height + extra * 2),
            )
        }
    }
}
