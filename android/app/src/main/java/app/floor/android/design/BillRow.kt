package app.floor.android.design

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.model.BillListItem
import app.floor.android.model.BillRoad
import app.floor.android.model.SpokenBill
import app.floor.android.model.StageChip
import app.floor.android.model.chip
import app.floor.android.model.latestStep
import app.floor.android.model.roadSteps

// The pieces of the Round 10 design that bill lists share (iOS `BillRow.swift`): the stage chip,
// the five-step road, a bill row and a topic row. Follow pills arrive with follows (phase 4).

/** At these font scales a list row gives its label and latest step more lines, as iOS does at accessibility sizes. */
@Composable
internal fun largeText(): Boolean = LocalDensity.current.fontScale >= 1.5f

/** A small heading over a group of rows: `TOPICS · 32`, `BILLS · 20`. */
@Composable
fun ListHeading(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = FloorType.label(12f).copy(letterSpacing = 1.2.sp),
        color = Palette.textMuted,
        modifier = modifier.padding(top = 6.dp).semantics { heading() },
    )
}

/** The stage chip: filled green for law, filled orange for a failed vote, outlined on the way. */
@Composable
fun StageChipView(chip: StageChip) {
    val colors = Palette
    val shape = RoundedCornerShape(4.dp)
    val fill = when (chip.tone) {
        StageChip.Tone.LAW -> colors.yea
        StageChip.Tone.FAILED -> colors.nay
        StageChip.Tone.NEUTRAL -> Color.Transparent
    }
    Text(
        chip.text,
        style = FloorType.display(10.5f, FloorType.Face.EXTRA_BOLD).copy(letterSpacing = 0.8.sp),
        color = if (chip.tone == StageChip.Tone.NEUTRAL) colors.textSecondary else colors.ground,
        maxLines = 1,
        modifier = Modifier
            .clip(shape)
            .background(fill, shape)
            .then(if (chip.tone == StageChip.Tone.NEUTRAL) Modifier.border(1.dp, colors.raised, shape) else Modifier)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** Five bars, the steps reached in the threshold yellow. */
@Composable
fun BillRoadView(steps: Int) {
    val colors = Palette
    Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        repeat(BillRoad.steps.size) { index ->
            Box(
                Modifier
                    .weight(1f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(if (index < steps) colors.threshold else colors.panelBorder),
            )
        }
    }
}

/** A bill in a list (the mock's `.bl2`): citation and stage chip, the plain label, the latest step, the road. */
@Composable
fun BillRow(bill: BillListItem, onOpen: () -> Unit, showsLatest: Boolean = true, showsRoad: Boolean = true) {
    val colors = Palette
    val large = largeText()
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel, shape)
            .border(1.dp, colors.panelBorder, shape)
            .clickable(role = Role.Button, onClickLabel = "Open the bill", onClick = onOpen)
            .padding(horizontal = 11.dp, vertical = 9.dp)
            .clearAndSetSemantics { contentDescription = SpokenBill.billRow(bill) },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                bill.citation.uppercase(),
                style = FloorType.label(12f).copy(letterSpacing = 0.8.sp),
                color = colors.threshold,
                maxLines = 1,
            )
            Spacer(Modifier.weight(1f).width(4.dp))
            bill.chip?.let { StageChipView(it) }
        }
        Text(
            bill.label,
            style = FloorType.text(13f, FontWeight.Bold),
            color = colors.text,
            maxLines = if (large) 10 else 3,
            overflow = TextOverflow.Ellipsis,
        )
        if (showsLatest) {
            bill.latestStep?.let {
                Text(
                    it,
                    style = FloorType.text(11f, FontWeight.Medium),
                    color = colors.textMuted,
                    maxLines = if (large) 8 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (showsRoad) bill.roadSteps?.let { BillRoadView(it) }
    }
}

/** A topic in a list (the mock's `.tp`): its name, a count line, and `›`. */
@Composable
fun TopicRow(name: String, detail: String?, spoken: String, onOpen: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel, shape)
            .border(1.dp, colors.panelBorder, shape)
            .clickable(role = Role.Button, onClickLabel = "Open the topic's bills", onClick = onOpen)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .clearAndSetSemantics { contentDescription = spoken },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name.uppercase(), style = FloorType.display(20f, FloorType.Face.BLACK_ITALIC), color = colors.text, maxLines = 2)
            if (detail != null) Text(detail, style = FloorType.text(11f, FontWeight.Medium), color = colors.textMuted)
        }
        Text("›", style = FloorType.text(20f), color = colors.textMuted)
    }
}

/** A dashed-border notice: "COULDN'T SEARCH", "NOTHING MATCHES …". */
@Composable
fun Notice(title: String, body: String) {
    val colors = Palette
    Column(
        Modifier
            .padding(top = 10.dp)
            .dashedPanel(colors.panelBorder, colors.panel, 14.dp)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(title, style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.textMuted)
        Text(body, style = FloorType.text(13f), color = colors.textSecondary)
    }
}
