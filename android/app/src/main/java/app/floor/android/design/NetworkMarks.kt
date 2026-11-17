package app.floor.android.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp
import app.floor.android.model.SocialNetwork

// The round 13 polish mock's network marks (`floor-polish.html`, iOS `NetworkMark`): monochrome,
// on a 24×24 grid, drawn in one colour by the `Icon` tint. The black below is only a mask.

private class Part(val path: String, val stroke: Float? = null, val evenOdd: Boolean = false)

private fun mark(name: String, vararg parts: Part): ImageVector =
    ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
        parts.forEach { part ->
            val ink = SolidColor(Color.Black)
            addPath(
                pathData = addPathNodes(part.path),
                pathFillType = if (part.evenOdd) PathFillType.EvenOdd else PathFillType.NonZero,
                fill = if (part.stroke == null) ink else null,
                stroke = if (part.stroke != null) ink else null,
                strokeLineWidth = part.stroke ?: 0f,
            )
        }
    }.build()

private val X = mark(
    "x",
    Part("M17.8 3h3.1l-6.8 7.8L22 21h-6.2l-4.9-6.4L5.3 21H2.2l7.3-8.3L2 3h6.4l4.4 5.8L17.8 3zm-1.1 16.2h1.7L7.4 4.7H5.6l11.1 14.5z"),
)

private val Facebook = mark(
    "facebook",
    Part("M13.5 21v-7.4h2.5l.4-2.9h-2.9V8.9c0-.8.2-1.4 1.4-1.4h1.5V4.9c-.3 0-1.2-.1-2.2-.1-2.2 0-3.7 1.3-3.7 3.8v2.1H8v2.9h2.5V21h3z"),
)

private val Instagram = mark(
    "instagram",
    Part("M8.5 3.5h7a5 5 0 0 1 5 5v7a5 5 0 0 1-5 5h-7a5 5 0 0 1-5-5v-7a5 5 0 0 1 5-5z", stroke = 1.9f),
    Part("M16 12a4 4 0 1 1-8 0a4 4 0 1 1 8 0z", stroke = 1.9f),
    Part("M18.4 6.8a1.2 1.2 0 1 1-2.4 0a1.2 1.2 0 1 1 2.4 0z"),
)

/** The play triangle is a hole (even-odd), so it shows whatever the mark sits on. */
private val YouTube = mark(
    "youtube",
    Part("M6.5 5h11A4.5 4.5 0 0 1 22 9.5v5a4.5 4.5 0 0 1-4.5 4.5h-11A4.5 4.5 0 0 1 2 14.5v-5A4.5 4.5 0 0 1 6.5 5zM10 9l5.2 3L10 15z", evenOdd = true),
)

private val Bluesky = mark(
    "bluesky",
    Part("M5.9 4.1C8.2 5.8 10.7 9.3 12 11c1.3-1.7 3.8-5.2 6.1-6.9 1.7-1.2 4.4-2.2 4.4.9 0 .6-.4 5.1-.6 5.8-.7 2.6-3.3 3.2-5.6 2.8 4 .7 5 3 2.8 5.2-4.2 4.3-6-1.1-6.5-2.5l-.6-1.6-.6 1.6c-.5 1.4-2.3 6.8-6.5 2.5-2.2-2.2-1.2-4.5 2.8-5.2-2.3.4-4.9-.2-5.6-2.8-.2-.7-.6-5.2-.6-5.8 0-3.1 2.7-2.1 4.4-.9z"),
)

/** Floor's own simple mark: a rounded speech bubble with an "m" cut out of it. */
private val Mastodon = mark(
    "mastodon",
    Part(
        "M8 3h8a5 5 0 0 1 5 5v5a5 5 0 0 1-5 5h-5l-4.5 3.2.5-3.4A5 5 0 0 1 3 13V8a5 5 0 0 1 5-5z" +
            "M7.5 13.5V9.75a2.25 2.25 0 0 1 4.5 0a2.25 2.25 0 0 1 4.5 0V13.5h-1.6V9.75a.65 .65 0 0 0-1.3 0V13.5h-3.2V9.75a.65 .65 0 0 0-1.3 0V13.5z",
        evenOdd = true,
    ),
)

/** The network's mark, for an `Icon` tinted with a [Palette] ink. */
val SocialNetwork.mark: ImageVector
    get() = when (this) {
        SocialNetwork.X -> X
        SocialNetwork.FACEBOOK -> Facebook
        SocialNetwork.INSTAGRAM -> Instagram
        SocialNetwork.YOUTUBE -> YouTube
        SocialNetwork.BLUESKY -> Bluesky
        SocialNetwork.MASTODON -> Mastodon
    }
