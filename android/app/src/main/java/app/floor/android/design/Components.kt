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
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import app.floor.android.model.Outcome
import app.floor.android.model.ThresholdLine

// The small pieces every app screen in the locked mocks shares (iOS `Components.swift`): the panel
// surface, the skewed chip and the threshold bar.

/** The mocks' card, as Arena glass ([glass]) with 16dp corners. */
fun Modifier.panel(colors: FloorColors, cornerRadius: Dp = 16.dp, padding: Dp = 14.dp): Modifier =
    fillMaxWidth()
        .glass(colors, RoundedCornerShape(cornerRadius))
        .padding(padding)

/**
 * Arena's glass card (`.d1 --shadowS`): a soft long drop shadow, the [fill] (the panel, unless a
 * card has its own), a 1dp highlight along the top edge, and a 1dp hairline, which [edge] replaces
 * with a gradient Brush on a hero card. Drawn with Brushes and a shadow, never a scaled or faded
 * graphics layer (lesson 76). Every card on every screen is drawn through this.
 */
fun Modifier.glass(colors: FloorColors, shape: Shape, fill: Brush? = null, edge: Brush? = null): Modifier {
    val highlight = colors.cardHighlight
    return dropShadow(shape, Shadow(radius = 10.dp, color = colors.cardShadow, spread = (-16).dp, offset = DpOffset(0.dp, 10.dp)))
        .clip(shape)
        .then(if (fill != null) Modifier.background(fill, shape) else Modifier.background(colors.panel, shape))
        .drawWithContent {
            drawContent()
            drawRect(highlight, size = Size(size.width, 1.dp.toPx()))
        }
        .then(if (edge != null) Modifier.border(1.dp, edge, shape) else Modifier.border(1.dp, colors.panelBorder, shape))
}

/**
 * A hero card's hairline (story cards, post cards): [top] at the top left fading to [fade] by 40%
 * along a 160-degree line, as CSS lays a `linear-gradient(160deg, ...)` over a box of any size.
 */
fun edgeBrush(top: Color, fade: Color): Brush = cssGradient(160.0, listOf(top, fade, fade), listOf(0f, 0.4f, 1f))

/**
 * A CSS `linear-gradient(<angle>deg, ...)` over a box of any size: 0 degrees points up, 90 right,
 * and the line is long enough that the end colours reach the box's corners, as CSS draws it.
 */
fun cssGradient(degrees: Double, colors: List<Color>, stops: List<Float>): Brush = object : ShaderBrush() {
    override fun createShader(size: Size): Shader {
        val radians = Math.toRadians(degrees)
        val dx = sin(radians).toFloat()
        val dy = -cos(radians).toFloat()
        val half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        val center = Offset(size.width / 2, size.height / 2)
        return LinearGradientShader(
            from = center - Offset(dx * half, dy * half),
            to = center + Offset(dx * half, dy * half),
            colors = colors,
            colorStops = stops,
        )
    }
}

/** The gradient hairline in the current palette: the story card's, and the post card's. */
fun FloorColors.heroEdge(): Brush = edgeBrush(storyEdge, storyEdgeFade)

/**
 * Arena's ground (`.d1 .scroll`) for a tab's root screen: the ground colour with a soft radial
 * glow from the top centre, reaching 420dp and fading out by 60% of that.
 */
fun Modifier.arenaGround(colors: FloorColors): Modifier {
    val glow = colors.groundGlow
    val ground = colors.ground
    return drawBehind {
        drawRect(ground)
        val reach = 420.dp.toPx()
        drawRect(
            Brush.radialGradient(
                0f to glow, 0.6f to glow.copy(alpha = 0f),
                center = Offset(size.width / 2, 0f),
                radius = reach,
            ),
            size = Size(size.width, minOf(size.height, reach)),
        )
    }
}

/** The round open-arrow (↗) a post card ends its header with (the mock's `ARROW`). */
val OpenArrow: ImageVector = ImageVector.Builder("open", 24.dp, 24.dp, 24f, 24f).apply {
    addPath(
        pathData = addPathNodes("M7 17 17 7M9 7h8v8"),
        stroke = SolidColor(Color.Black),
        strokeLineWidth = 2.6f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
    )
}.build()

/**
 * A section's title on the one-scroll member page (the mock's `.blk h3`): Barlow Condensed black
 * italic, a heading for TalkBack, and its "All 40 ›" link on the right when it has one.
 */
@Composable
fun BlockHeader(title: String, link: String? = null, linkSpoken: String? = null, onLink: (() -> Unit)? = null) {
    val colors = Palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Text(
            title.uppercase(),
            style = FloorType.headline(23f),
            color = colors.text,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        if (link != null && onLink != null) {
            Text(
                link,
                style = FloorType.text(12.5f, FontWeight.Bold),
                color = colors.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(role = Role.Button, onClick = onLink)
                    .semantics { linkSpoken?.let { contentDescription = it } }
                    .padding(horizontal = 4.dp, vertical = 4.dp),
            )
        }
    }
}

/**
 * A dashed-outline card (iOS `StrokeStyle(dash:)`): what a notice or a placeholder sits in, so it
 * reads as not-content. [fill] may be transparent.
 */
fun Modifier.dashedPanel(stroke: Color, fill: Color, cornerRadius: Dp = 12.dp, dash: Float = 4f, gap: Float = 3f): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    return fillMaxWidth()
        .clip(shape)
        .background(fill, shape)
        .drawBehind {
            val width = 1.dp.toPx()
            val inset = width / 2
            drawRoundRect(
                stroke,
                topLeft = Offset(inset, inset),
                size = Size(size.width - width, size.height - width),
                cornerRadius = CornerRadius(cornerRadius.toPx() - inset),
                style = Stroke(width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash.dp.toPx(), gap.dp.toPx()))),
            )
        }
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
