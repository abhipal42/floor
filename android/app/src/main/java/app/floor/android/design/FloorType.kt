package app.floor.android.design

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.R

/**
 * Type from the canvas and the locked app mocks (iOS `Typography`, `ScaledFont`).
 *
 * Scores, labels and headlines are Barlow Condensed, bundled in `res/font`. Running text is Inter,
 * standing in for the iOS system face (SF Pro), which Android cannot ship: Inter is the closest
 * open face to it, so a card's title wraps where the iOS one does.
 *
 * Sizes are the mocks' points as `sp`, so they grow with the reader's font-size setting the way
 * iOS Dynamic Type grows them. Pass `scales = false` for numbers that must fit a fixed column.
 */
object FloorType {
    /** The bundled Barlow Condensed faces: 600/700/800 roman, 800/900 italic. */
    enum class Face(val weight: FontWeight, val style: FontStyle) {
        SEMI_BOLD(FontWeight.SemiBold, FontStyle.Normal),
        BOLD(FontWeight.Bold, FontStyle.Normal),
        EXTRA_BOLD(FontWeight.ExtraBold, FontStyle.Normal),
        EXTRA_BOLD_ITALIC(FontWeight.ExtraBold, FontStyle.Italic),
        BLACK_ITALIC(FontWeight.Black, FontStyle.Italic),
    }

    val barlowCondensed = FontFamily(
        Font(R.font.barlow_condensed_semibold, FontWeight.SemiBold),
        Font(R.font.barlow_condensed_bold, FontWeight.Bold),
        Font(R.font.barlow_condensed_extrabold, FontWeight.ExtraBold),
        Font(R.font.barlow_condensed_extrabold_italic, FontWeight.ExtraBold, FontStyle.Italic),
        Font(R.font.barlow_condensed_black_italic, FontWeight.Black, FontStyle.Italic),
    )

    val inter = FontFamily(
        Font(R.font.inter_400, FontWeight.Normal),
        Font(R.font.inter_500, FontWeight.Medium),
        Font(R.font.inter_600, FontWeight.SemiBold),
        Font(R.font.inter_700, FontWeight.Bold),
    )

    /** Barlow Condensed at one of the bundled faces. */
    @Composable
    @ReadOnlyComposable
    fun display(size: Float, face: Face = Face.EXTRA_BOLD, scales: Boolean = true): TextStyle = TextStyle(
        fontFamily = barlowCondensed,
        fontWeight = face.weight,
        fontStyle = face.style,
        fontSize = size(size, scales),
    )

    /** The big scoreboard numbers: fixed size, tabular digits, scaled down to fit rather than up. */
    @Composable
    @ReadOnlyComposable
    fun score(size: Float): TextStyle = display(size, Face.EXTRA_BOLD, scales = false).copy(fontFeatureSettings = "tnum")

    /** The italic 900 headlines: "YOUR FINALS", a bill's title. */
    @Composable
    @ReadOnlyComposable
    fun headline(size: Float): TextStyle = display(size, Face.BLACK_ITALIC)

    /** 800 labels: "BOX SCORE", "YEA", a member's surname on a card. */
    @Composable
    @ReadOnlyComposable
    fun label(size: Float): TextStyle = display(size, Face.EXTRA_BOLD)

    /** Running text at the mocks' point size (iOS `.scaledFont` / `.system(size:)`). */
    @Composable
    @ReadOnlyComposable
    fun text(size: Float, weight: FontWeight = FontWeight.Normal, scales: Boolean = true): TextStyle = TextStyle(
        fontFamily = inter,
        fontWeight = weight,
        fontSize = size(size, scales),
    )

    /**
     * The rule a line rests on (iOS `.system(design: .monospaced)`): the platform's monospaced face,
     * as iOS uses its own rather than a bundled one.
     */
    @Composable
    @ReadOnlyComposable
    fun mono(size: Float, weight: FontWeight = FontWeight.Medium): TextStyle = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = weight,
        fontSize = size(size, true),
    )

    /** Body copy: 13. */
    @Composable
    @ReadOnlyComposable
    fun body(): TextStyle = text(13f)

    /** Captions and notes: 12. */
    @Composable
    @ReadOnlyComposable
    fun caption(): TextStyle = text(12f)

    /**
     * A fixed size goes through the density's own dp-to-sp conversion rather than dividing by the
     * font scale: Android 14 scales large text non-linearly (48sp at 200% is not 96dp), so dividing
     * drew the "fixed" scoreboard numbers at about half size at the largest font setting.
     */
    @Composable
    @ReadOnlyComposable
    private fun size(size: Float, scales: Boolean): TextUnit =
        if (scales) size.sp else with(LocalDensity.current) { size.dp.toSp() }
}
