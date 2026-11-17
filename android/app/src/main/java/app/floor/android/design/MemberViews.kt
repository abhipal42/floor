package app.floor.android.design

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.model.ElectText
import app.floor.android.model.Member
import app.floor.android.model.MemberElect
import app.floor.android.model.PendingSeat
import app.floor.android.model.Position
import app.floor.android.model.chip
import app.floor.android.model.fullName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Locale

// The pieces a member is drawn with (iOS `Components.swift`'s ring and portrait, `ElectViews.swift`,
// `FollowPill`, `FollowButton`, `SectionSwitch`).

/**
 * False draws every portrait as initials without asking the network: how a screenshot test gets the
 * same frame every run (iOS `NoPortraits`).
 */
val LocalLoadsPortraits = staticCompositionLocalOf { true }

/** Portraits from the `unitedstates/images` project, keyed by Bioguide ID (iOS `MemberPortrait.url`). */
private object Portraits {
    private val client = OkHttpClient()
    private val memory = LruCache<String, Bitmap>(60)
    private val missing = mutableSetOf<String>()

    fun url(id: String) = "https://unitedstates.github.io/images/congress/225x275/$id.jpg"

    fun cached(id: String): Bitmap? = memory.get(id)

    suspend fun load(id: String): Bitmap? = withContext(Dispatchers.IO) {
        memory.get(id)?.let { return@withContext it }
        if (synchronized(missing) { id in missing }) return@withContext null
        try {
            client.newCall(Request.Builder().url(url(id)).build()).execute().use { response ->
                if (!response.isSuccessful) {
                    synchronized(missing) { missing += id }
                    return@use null
                }
                BitmapFactory.decodeStream(response.body.byteStream())?.also { memory.put(id, it) }
            }
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * A member's official portrait, falling back to their initials on a party-tinted ground (iOS
 * `MemberPortrait`). Null [cornerRadius] is a circle. Decorative: the row around it names them.
 */
@Composable
fun MemberPortrait(member: Member, modifier: Modifier = Modifier, cornerRadius: Dp? = null) {
    val colors = Palette
    val shape: Shape = cornerRadius?.let { RoundedCornerShape(it) } ?: CircleShape
    val loads = LocalLoadsPortraits.current
    var bitmap by remember(member.bioguideId) { mutableStateOf(if (loads) Portraits.cached(member.bioguideId) else null) }
    if (loads) LaunchedEffect(member.bioguideId) { if (bitmap == null) bitmap = Portraits.load(member.bioguideId) }
    BoxWithConstraints(modifier.clip(shape).background(colors.partyTint(member.party)).clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image != null) {
            Image(image.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alignment = Alignment.TopCenter)
        } else {
            val initials = (member.firstName.take(1) + member.lastName.take(1)).uppercase()
            val side = minOf(maxWidth, maxHeight)
            val size = with(LocalDensity.current) { maxOf(10.dp, side * 0.36f).toSp() }
            Text(initials, style = FloorType.text(10f, FontWeight.Bold).copy(fontSize = size), color = colors.text, maxLines = 1)
        }
    }
}

/** A progress ring; a null share draws only the track, for a figure that does not exist. */
@Composable
fun Ring(share: Double?, color: Color, lineWidth: Dp, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val track = Palette.panelBorder
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val w = lineWidth.toPx()
            val inset = w / 2
            val arcSize = Size(size.width - w, size.height - w)
            drawArc(track, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(w))
            if (share != null) {
                drawArc(color, -90f, 360f * share.coerceIn(0.0, 1.0).toFloat(), false, Offset(inset, inset), arcSize, style = Stroke(w, cap = StrokeCap.Round))
            }
        }
        content()
    }
}

/** The mocks' segmented control: Votes · Money · Contact, or Funding · Disclosures. */
@Composable
fun <T> SectionSwitch(options: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    val colors = Palette
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.panel)
            .padding(3.dp),
    ) {
        options.forEach { option ->
            val on = option == selected
            Text(
                label(option),
                style = FloorType.text(13f, FontWeight.SemiBold),
                color = if (on) colors.ground else colors.textSecondary,
                textAlign = TextAlign.Center,
                maxLines = 1,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) colors.text else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) }
                    .semantics { this.selected = on }
                    .padding(7.dp),
            )
        }
    }
}

/** The switch the Following tab, Finals' scope and "+ Add" use: chips on a panel, the chosen one raised. */
@Composable
fun <T> ChipSwitch(options: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit, size: Float = 12f, spoken: (T) -> String = label) {
    val colors = Palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(colors.panel).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEach { option ->
            val on = option == selected
            Text(
                label(option),
                style = FloorType.label(size).copy(letterSpacing = 0.6.sp),
                color = if (on) colors.text else colors.textMuted,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (on) colors.chip else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) }
                    .semantics {
                        this.selected = on
                        contentDescription = spoken(option)
                    }
                    .padding(vertical = 7.dp),
            )
        }
    }
}

/** Follow / Following on a bill, a topic or a search row (iOS `FollowPill`). */
@Composable
fun FollowPill(on: Boolean, name: String, offTitle: String = "FOLLOW", onTitle: String = "FOLLOWING", onToggle: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(8.dp)
    Text(
        if (on) onTitle else offTitle,
        style = FloorType.label(12f).copy(letterSpacing = 0.6.sp),
        color = if (on) colors.text else colors.ground,
        maxLines = 1,
        modifier = Modifier
            .clip(shape)
            .background(if (on) Color.Transparent else colors.threshold, shape)
            .then(if (on) Modifier.border(1.dp, colors.raised, shape) else Modifier)
            .clickable(role = Role.Switch) { onToggle() }
            .semantics {
                contentDescription = "Follow $name"
                stateDescription = if (on) "On" else "Off"
            }
            .padding(horizontal = 10.dp, vertical = 7.dp),
    )
}

/**
 * Follow / Following on a member (iOS `FollowButton`): filled when you can follow, outlined once you
 * do. Your own rep shows a label, not a button: they come from your district and are hidden, not
 * unfollowed.
 */
@Composable
fun FollowButton(member: Member, following: Boolean, isRep: Boolean, compact: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Palette
    val shape = RoundedCornerShape(if (compact) 8.dp else 9.dp)
    val padding = Modifier.padding(horizontal = if (compact) 10.dp else 12.dp, vertical = if (compact) 7.dp else 10.dp)
    val width = if (compact) Modifier else Modifier.fillMaxWidth()
    val style = FloorType.label(if (compact) 12f else 14f).copy(letterSpacing = 0.6.sp)
    if (isRep) {
        val senator = member.chamber == app.floor.android.model.Chamber.SENATE
        Text(
            if (senator) "YOUR SENATOR" else "YOUR REP",
            style = style,
            color = colors.textMuted,
            textAlign = TextAlign.Center,
            modifier = modifier.then(width).semantics {
                contentDescription = "${member.fullName} is your ${if (senator) "senator" else "representative"}"
            }.then(padding),
        )
    } else {
        Text(
            if (following) (if (compact) "FOLLOWING" else "✓ FOLLOWING") else "FOLLOW",
            style = style,
            color = if (following) colors.text else colors.ground,
            textAlign = TextAlign.Center,
            maxLines = 1,
            modifier = modifier
                .then(width)
                .clip(shape)
                .background(if (following) Color.Transparent else colors.threshold, shape)
                .then(if (following) Modifier.border(1.dp, colors.raised, shape) else Modifier)
                .clickable(role = Role.Switch, onClick = onToggle)
                .semantics {
                    contentDescription = if (following) "Following ${member.fullName}" else "Follow ${member.fullName}"
                    selected = following
                }
                .then(padding),
        )
    }
}

/** The filled YEA / NAY / DNV chip; a candidate's name on a Speaker ballot. */
@Composable
fun PositionChip(position: Position, choice: String?) {
    val colors = Palette
    Text(
        position.chip(choice),
        style = FloorType.label(11f).copy(letterSpacing = 0.8.sp),
        color = colors.ground,
        maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(4.dp)).background(colors.position(position)).padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** The colour a position is printed in. */
fun FloorColors.position(position: Position): Color = when (position) {
    Position.YEA -> yea
    Position.NAY -> nay
    Position.PRESENT, Position.NOT_VOTING -> textMuted
    Position.CANDIDATE -> text
}

// MARK: - Members-elect (round 12, section A)

/** The departing member's tag: a muted outline. */
@Composable
fun LeavingTag() {
    val colors = Palette
    Text(
        "LEAVING",
        style = FloorType.label(10.5f).copy(letterSpacing = 1.sp),
        color = colors.textMuted,
        modifier = Modifier.border(1.dp, colors.raised, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** The ELECT tag: filled, or outlined ([ghost]). */
@Composable
fun ElectTag(text: String = "ELECT", ghost: Boolean = false) {
    val colors = Palette
    val shape = RoundedCornerShape(4.dp)
    Text(
        text,
        style = FloorType.label(10.5f).copy(letterSpacing = 1.sp),
        color = if (ghost) colors.elect else colors.electInk,
        modifier = Modifier
            .clip(shape)
            .background(if (ghost) Color.Transparent else colors.elect, shape)
            .then(if (ghost) Modifier.border(1.dp, colors.elect.copy(alpha = 0.55f), shape) else Modifier)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** A member-elect's initials in the elect-blue ring, a ground-coloured gap between. */
@Composable
fun ElectAvatar(elect: MemberElect, size: Dp = 30.dp) {
    Box(Modifier.size(size + 4.dp).border(1.5.dp, Palette.elect, CircleShape).padding(2.dp)) {
        MemberPortrait(elect.asMember, Modifier.size(size))
    }
}

/** The panel a seat-change row sits on, its border elect blue for an elect. */
private fun Modifier.seatRowSurface(colors: FloorColors, elect: Boolean): Modifier {
    val shape = RoundedCornerShape(12.dp)
    return fillMaxWidth()
        .clip(shape)
        .background(colors.panel, shape)
        .border(1.dp, if (elect) colors.elect.copy(alpha = 0.35f) else colors.panelBorder, shape)
}

/** The current locale, for the dates the elect rows print. */
@Composable
fun currentLocale(): Locale = LocalConfiguration.current.locales[0]

/** A sitting member's row; dimmed, with the LEAVING tag, when [leavingOn] is set. */
@Composable
fun SeatMemberRow(
    member: Member,
    leavingOn: String?,
    caption: String? = null,
    onOpen: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val colors = Palette
    val locale = currentLocale()
    val text = caption?.let { base -> leavingOn?.let { ElectText.day(it, locale) }?.let { "$base · leaves $it" } ?: base }
        ?: ElectText.memberCaption(member, leavingOn, locale)
    Row(
        Modifier
            .alpha(if (leavingOn == null) 1f else 0.62f)
            .seatRowSurface(colors, elect = false)
            .then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open their record", onClick = onOpen) else Modifier)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        MemberPortrait(member, Modifier.size(30.dp))
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(member.fullName.uppercase(), style = FloorType.display(17f, FloorType.Face.BLACK_ITALIC), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(text, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted)
        }
        if (leavingOn != null) Box(Modifier.clearAndSetSemantics { }) { LeavingTag() }
        trailing()
    }
}

/** A member-elect's row, with the line saying who called the race under it. */
@Composable
fun ElectRow(elect: MemberElect, onOpen: () -> Unit) {
    val colors = Palette
    val locale = currentLocale()
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Open what Floor has on them before they take office", onClick = onOpen)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            Modifier.seatRowSurface(colors, elect = true).padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            ElectAvatar(elect)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(elect.fullName.uppercase(), style = FloorType.display(17f, FloorType.Face.BLACK_ITALIC), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(ElectText.electCaption(elect, locale), style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted)
            }
            ElectTag()
            Text("›", style = FloorType.text(13f, FontWeight.SemiBold), color = colors.textMuted, modifier = Modifier.clearAndSetSemantics { })
        }
        Text(ElectText.callLine(elect.call, locale), style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A seat with no winner yet: dashed, centred, never a name. */
@Composable
fun PendingSeatCard(seat: PendingSeat) {
    val (title, body) = ElectText.pending(seat, currentLocale())
    DashedPlaceholder(title, body)
}

/** The mocks' dashed placeholder: a headline and a line, for what does not exist yet. */
@Composable
fun DashedPlaceholder(title: String, body: String, modifier: Modifier = Modifier) {
    val colors = Palette
    Column(
        modifier
            .dashedPanel(colors.raised, Color.Transparent, 12.dp)
            .padding(12.dp)
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(title.uppercase(), style = FloorType.display(18f, FloorType.Face.BLACK_ITALIC), color = colors.text, textAlign = TextAlign.Center)
        Text(body, style = FloorType.text(11f, FontWeight.Medium), color = colors.textMuted, textAlign = TextAlign.Center)
    }
}
