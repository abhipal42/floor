package app.floor.android.home

import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import app.floor.android.design.FloorType
import app.floor.android.design.LitObject
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.design.dayText
import app.floor.android.model.RecentVote
import app.floor.android.model.VoteKind
import app.floor.android.model.outcomeWord
import app.floor.android.model.questionKind
import kotlinx.coroutines.delay

/** The split-flap board's three rows (iOS `FlapBoard`). */
object FlapBoardRows {
    const val WIDTH = 16

    /** `HOUSE  ROLL 321` / `H.R. 1013 PASSED` / `YEA 295 NAY 128`, each centred and cut to fit. */
    fun rows(item: RecentVote): List<String> {
        val vote = item.vote
        val first = listOfNotNull(vote.chamber.title.uppercase(), vote.rollNumber?.let { "ROLL $it" }).joinToString("  ")
        if (vote.kind == VoteKind.ELECTION) {
            val leader = vote.leadingCandidate
            return listOf(
                first,
                if (vote.electedSpeaker == null) "NO SPEAKER YET" else "SPEAKER ELECTED",
                leader?.let { "${it.name.uppercase()} ${it.total}" } ?: "",
            ).map(::pad)
        }
        val cite = item.measure?.citation?.uppercase() ?: vote.questionKind.uppercase()
        val word = vote.outcomeWord ?: "FINAL"
        val second = if (cite.length + 1 + word.length <= WIDTH) "$cite $word" else word
        return listOf(first, second, "YEA ${vote.totals.yea} NAY ${vote.totals.nay}").map(::pad)
    }

    /** Centred in sixteen cells, the extra space on the right. */
    fun pad(text: String): String {
        val cut = text.take(WIDTH)
        val left = (WIDTH - cut.length) / 2
        return " ".repeat(left) + cut + " ".repeat(WIDTH - cut.length - left)
    }
}

private const val GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

/**
 * The latest final on a split-flap board: three rows of sixteen cells that settle into place, cell
 * by cell, left to right. With animations removed in the system settings it is drawn settled.
 *
 * A lit board, so it stays dark in light mode, as the real ones do.
 */
@Composable
fun SplitFlapBoard(item: RecentVote, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val systemOff = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val still = systemOff || !LocalPlaysArrivalAnimations.current
    val rows = FlapBoardRows.rows(item)
    var settled by remember(item.id) { mutableIntStateOf(if (still) Int.MAX_VALUE else 0) }
    LaunchedEffect(item.id, still) {
        if (still) {
            settled = Int.MAX_VALUE
            return@LaunchedEffect
        }
        for (step in 0..rows.size * FlapBoardRows.WIDTH) {
            settled = step
            delay(14)
        }
        settled = Int.MAX_VALUE
    }
    val spoken = "Latest final: " + rows.joinToString(", ") { it.trim() }
    LitObject {
        val colors = Palette
        val tints = listOf(colors.textMuted, colors.text, colors.yea)
        val shape = RoundedCornerShape(16.dp)
        Column(
            modifier
                .fillMaxWidth()
                .clip(shape)
                .background(colors.flapBoard, shape)
                .border(1.dp, colors.panelBorder, shape)
                .padding(12.dp)
                .clearAndSetSemantics { contentDescription = spoken },
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            rows.forEachIndexed { r, row ->
                Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    row.forEachIndexed { c, char ->
                        val index = r * FlapBoardRows.WIDTH + c
                        val shown = if (index < settled || char == ' ') char else GLYPHS[(index * 7 + settled) % GLYPHS.length]
                        Box(
                            Modifier
                                .weight(1f)
                                .height(28.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(
                                    Brush.verticalGradient(
                                        0.49f to colors.flapTop, 0.51f to colors.flapBottom,
                                    ),
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                shown.toString(),
                                style = FloorType.display(17f, FloorType.Face.EXTRA_BOLD, scales = false),
                                color = tints[r],
                            )
                        }
                    }
                }
            }
            Text(
                "LATEST FINAL" + (item.vote.dayText()?.let { " · " + it.uppercase() } ?: ""),
                style = FloorType.text(10f, scales = false),
                color = colors.textMuted,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}
