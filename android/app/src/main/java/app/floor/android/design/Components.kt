package app.floor.android.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.floor.android.model.Outcome
import app.floor.android.model.ThresholdLine

// The small pieces every app screen in the locked mocks shares (iOS `Components.swift`): the panel
// surface, the skewed chip and the threshold bar.

/** The mocks' card: a panel fill, a 1dp hairline, 16dp corners. */
fun Modifier.panel(colors: FloorColors, cornerRadius: Dp = 16.dp, padding: Dp = 14.dp): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    return fillMaxWidth()
        .clip(shape)
        .background(colors.panel, shape)
        .border(1.dp, colors.panelBorder, shape)
        .padding(padding)
}

/** Green when the question carried, orange when it did not, grey when it settled nothing. */
fun FloorColors.outcome(outcome: Outcome?): Color = when (outcome) {
    Outcome.CARRIED -> yea
    Outcome.FAILED -> nay
    null -> textSecondary
}

/** Leans the view as italic type does: the skewed chips' 10-degree slant. */
private fun Modifier.skewed(shift: Float): Modifier = drawWithContent {
    val matrix = Matrix().apply {
        values[Matrix.SkewX] = -0.176f
        values[Matrix.TranslateX] = shift * density
    }
    withTransform({ transform(matrix) }) { this@drawWithContent.drawContent() }
}

/** The skewed label: a chamber tag, a result, FINAL. */
@Composable
fun SkewChip(
    text: String,
    modifier: Modifier = Modifier,
    foreground: Color = Palette.ground,
    background: Color = Palette.text,
    size: Float = 12f,
) {
    Text(
        text,
        style = FloorType.display(size, FloorType.Face.EXTRA_BOLD, scales = false),
        color = foreground,
        maxLines = 1,
        overflow = TextOverflow.Clip,
        modifier = modifier
            .skewed(size * 0.1f)
            .background(background)
            .padding(horizontal = (size * 0.55f).dp, vertical = (size * 0.1f).dp),
    )
}

/** The yea fill with the yellow line it had to cross. */
@Composable
fun ThresholdBar(line: ThresholdLine, modifier: Modifier = Modifier, height: Dp = 6.dp) {
    val track = Palette.panelBorder
    val yea = Palette.yea
    val threshold = Palette.threshold
    Canvas(
        modifier
            .fillMaxWidth()
            .height(height)
            .semantics { contentDescription = "${line.yea} yea of ${line.cast} cast; the line is ${line.needed}" },
    ) {
        val w = size.width
        val h = size.height
        val r = CornerRadius(h / 2, h / 2)
        drawRoundRect(track, cornerRadius = r)
        val fill = (w * line.yeaShare).toFloat()
        if (fill > 0f) {
            val path = Path().apply {
                addRoundRect(
                    RoundRect(
                        left = 0f, top = 0f, right = fill, bottom = h,
                        topLeftCornerRadius = r, bottomLeftCornerRadius = r,
                    ),
                )
            }
            drawPath(path, yea)
        }
        val tick = 2.dp.toPx()
        val x = minOf(w - tick, (w * line.lineShare).toFloat())
        val extra = 4.dp.toPx()
        drawRect(threshold, topLeft = Offset(x, -extra), size = Size(tick, h + extra * 2))
    }
}
