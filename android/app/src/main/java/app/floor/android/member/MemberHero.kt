package app.floor.android.member

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.design.FloorType
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Palette
import app.floor.android.design.cssGradient
import app.floor.android.home.Stories
import app.floor.android.model.Chamber
import app.floor.android.model.Member
import app.floor.android.model.MemberVote
import app.floor.android.model.PartyName
import app.floor.android.model.Position
import app.floor.android.model.RecordStats
import app.floor.android.model.StateName
import app.floor.android.model.fullName
import app.floor.android.model.seatBadge
import java.time.ZoneId
import java.util.Locale

// The one-scroll member page's top (Arena, v0.2.58; the mock's `.hero`, `.hstats`, `.strk`,
// `.jump`): the party-coloured hero with the portrait, the record's three figures and the streak of
// the last 40 calls, then the sticky jump chips.

/** At these font scales the hero's stat tiles stack. */
@Composable
internal fun largeText(): Boolean = LocalDensity.current.fontScale >= 1.5f

/** The hero's small line over the name: `YOUR SENATOR · NEW YORK`, `YOUR REP · NY-12`, `FOLLOWING`, `SENATE · TEXAS`. */
fun heroEyebrow(member: Member, isRep: Boolean, following: Boolean): String {
    val senate = member.chamber == Chamber.SENATE
    return when {
        isRep && senate -> "YOUR SENATOR · ${StateName.full(member.state).uppercase()}"
        isRep -> "YOUR REP · ${member.seatBadge}"
        following -> "FOLLOWING"
        senate -> "SENATE · ${StateName.full(member.state).uppercase()}"
        else -> "HOUSE · ${member.seatBadge}"
    }
}

/** `Democrat · Senate`. */
fun heroSubtitle(member: Member): String = "${PartyName.singular(member.party)} · ${member.chamber.title}"

/** The hero as TalkBack reads it, one sentence: who, the seat, and the three figures when there are any. */
fun heroSpoken(member: Member, eyebrow: String, figures: HeroFigures?): String {
    // `YOUR SENATOR · NEW YORK` reads as "Your Senator, New York"; `NY-12` stays as printed.
    val role = eyebrow.split(" · ").joinToString(", ") { part ->
        if (part.any { it.isDigit() }) part else part.lowercase().split(" ").joinToString(" ") { w -> w.replaceFirstChar(Char::uppercase) }
    }
    val who = "${member.fullName}. $role. ${heroSubtitle(member).replace(" · ", ", ")}."
    val f = figures ?: return who
    val party = f.withParty?.let { "with their party $it" } ?: "no party-loyalty figure"
    return "$who $party, showed up ${f.showedUp.replace("/", " of ")}, on the winning side ${f.winning.replace("/", " of ")}."
}

/** The three glass tiles' figures, from the same arithmetic the Votes screen shows. */
data class HeroFigures(val withParty: String?, val showedUp: String, val winning: String) {
    companion object {
        fun of(withPartyShare: Double?, stats: RecordStats) = HeroFigures(
            withPartyShare?.let { String.format(Locale.US, "%.1f%%", it * 100) },
            "${stats.showedUp}/${stats.calls.size}",
            "${stats.sidedWithOutcome}/${stats.decided}",
        )
    }
}

/**
 * The hero: a deep gradient in the party's colour (independents in grey) with a radial light at the
 * top right, under the status bar; the back button and [trailing] (Follow) on it; the portrait,
 * [eyebrow], the name and [subtitle]; then [content] (the tiles and the streak, or a member-elect's
 * line). Drawn with Brushes and a shadow only (lesson 76).
 */
@Composable
fun MemberHero(
    member: Member,
    eyebrow: String,
    subtitle: String,
    spoken: String,
    back: String,
    onBack: () -> Unit,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    val colors = Palette
    val ink = colors.heroInk
    val light = colors.heroLight(member.party)
    val green = colors.heroGreen
    val background = cssGradient(165.0, listOf(colors.heroTop(member.party), colors.heroBottom(member.party), colors.heroBottom(member.party)), listOf(0f, 0.75f, 1f))
    Column(
        Modifier
            .fillMaxWidth()
            .background(background)
            .drawBehind {
                drawRect(Brush.radialGradient(listOf(light, Color.Transparent), center = Offset(size.width * 0.9f, 0f), radius = size.width * 0.8f))
                drawRect(Brush.radialGradient(listOf(green, Color.Transparent), center = Offset(0f, size.height), radius = size.width * 0.6f))
            }
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 18.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(colors.heroButtonDim)
                    .clickable(role = Role.Button, onClick = onBack)
                    .semantics { contentDescription = "Back to $back" },
                contentAlignment = Alignment.Center,
            ) {
                Text("‹", style = FloorType.text(20f, FontWeight.SemiBold, scales = false), color = ink)
            }
            Spacer(Modifier.weight(1f))
            trailing?.invoke()
        }
        Row(
            Modifier.fillMaxWidth().clearAndSetSemantics {
                contentDescription = spoken
                heading()
            },
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val portrait = RoundedCornerShape(20.dp)
            MemberPortrait(
                member,
                Modifier
                    .dropShadow(portrait, Shadow(radius = 15.dp, color = colors.heroShadow, spread = (-12).dp, offset = DpOffset(0.dp, 18.dp)))
                    .border(3.dp, colors.heroRing, portrait)
                    .size(width = 92.dp, height = 112.dp),
                cornerRadius = 20.dp,
            )
            Column(Modifier.weight(1f)) {
                Text(eyebrow, style = FloorType.text(10f, FontWeight.ExtraBold).copy(letterSpacing = 1.4.sp), color = ink)
                Text(
                    member.fullName.uppercase(),
                    style = FloorType.headline(40f).copy(lineHeight = 0.9.em),
                    color = ink,
                    modifier = Modifier.padding(top = 5.dp, bottom = 4.dp),
                )
                Text(subtitle, style = FloorType.text(12.5f), color = ink)
            }
        }
        content()
    }
}

/** Follow on the hero: a white pill in the party's ink; "Following ✓" once you do. */
@Composable
fun HeroFollow(member: Member, following: Boolean, onToggle: () -> Unit) {
    val colors = Palette
    Text(
        if (following) "Following ✓" else "Follow",
        style = FloorType.text(12.5f, FontWeight.Bold),
        color = colors.heroBottom(member.party),
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(colors.heroInk)
            .clickable(role = Role.Switch, onClick = onToggle)
            .semantics {
                contentDescription = "Follow ${member.fullName}"
                stateDescription = if (following) "On" else "Off"
            }
            .padding(horizontal = 13.dp, vertical = 8.dp),
    )
}

/** The three glass tiles; stacked at the largest text sizes. */
@Composable
fun HeroStats(figures: HeroFigures) {
    val tiles = listOf(
        (figures.withParty ?: "—") to "With party",
        figures.showedUp to "Showed up",
        figures.winning to "Winning side",
    )
    if (largeText()) {
        Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            tiles.forEach { (big, label) -> HeroTile(big, label, Modifier.fillMaxWidth()) }
        }
    } else {
        Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            tiles.forEach { (big, label) -> HeroTile(big, label, Modifier.weight(1f)) }
        }
    }
}

@Composable
private fun HeroTile(big: String, label: String, modifier: Modifier) {
    val colors = Palette
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.clip(shape).background(colors.heroTile, shape).border(1.dp, colors.heroTileBorder, shape)
            .clearAndSetSemantics { }
            .padding(start = 10.dp, end = 10.dp, top = 9.dp, bottom = 8.dp),
    ) {
        Text(big, style = FloorType.display(25f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 1.em, fontFeatureSettings = "tnum"), color = colors.heroInk, maxLines = 1)
        Text(label, style = FloorType.text(10.5f, FontWeight.SemiBold), color = colors.heroInk, maxLines = 1)
    }
}

/** `Nov 11, Daniel Desmond Domenico, Nay`, for TalkBack on a streak bar. */
private fun spokenCall(call: MemberVote, zone: ZoneId, locale: Locale): String {
    val position = when (call.position) {
        Position.CANDIDATE -> call.choice ?: "a candidate"
        Position.NOT_VOTING -> "Did not vote"
        else -> call.position.name.lowercase().replaceFirstChar { it.uppercase() }
    }
    val day = call.vote.occurredAtInstant?.let { Stories.format(it, zone, locale) }
    return listOfNotNull(day, call.measure?.title ?: call.cite, position).joinToString(", ")
}

/**
 * The last 40 calls as bars, oldest to newest: yea green, nay orange, anything else translucent
 * white. Each bar opens its vote; the strip says its tally first.
 */
@Composable
fun HeroStreak(stats: RecordStats, zone: ZoneId, locale: Locale, onOpenVote: (String) -> Unit) {
    val colors = Palette
    val calls = stats.calls
    if (calls.isEmpty()) return
    val yea = calls.count { it.position == Position.YEA }
    val nay = calls.count { it.position == Position.NAY }
    val other = calls.size - yea - nay
    val summary = "Last ${calls.size} calls, oldest to newest: $yea yea, $nay nay" + if (other > 0) ", $other other" else ""
    Row(
        Modifier.fillMaxWidth().padding(top = 12.dp).height(15.dp).semantics { contentDescription = summary },
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        calls.forEach { call ->
            val fill = when (call.position) {
                Position.YEA -> colors.streakYea
                Position.NAY -> colors.streakNay
                else -> colors.streakOther
            }
            Box(
                Modifier.weight(1f).height(15.dp).clip(RoundedCornerShape(2.dp)).background(fill)
                    .clickable(role = Role.Button, onClickLabel = "Open the vote") { onOpenVote(call.vote.id) }
                    .semantics { contentDescription = spokenCall(call, zone, locale) },
            )
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = 4.dp).clearAndSetSemantics { }) {
        Text("Last ${calls.size} calls", style = FloorType.text(10f, FontWeight.SemiBold), color = colors.heroInk, modifier = Modifier.weight(1f))
        calls.last().vote.occurredAtInstant?.let {
            Text(Stories.format(it, zone, locale), style = FloorType.text(10f, FontWeight.SemiBold), color = colors.heroInk)
        }
    }
}

/**
 * The sticky jump chips (the mock's `.jump`): one per section with something in it; the one whose
 * section is at the top is filled. Each is a button that scrolls to its section.
 */
@Composable
fun JumpChips(sections: List<MemberSection>, active: MemberSection?, statusBar: Boolean, onJump: (MemberSection) -> Unit) {
    val colors = Palette
    Column(Modifier.fillMaxWidth().background(colors.ground.copy(alpha = JUMP_FILL))) {
        if (statusBar) Spacer(Modifier.windowInsetsPadding(WindowInsets.statusBars))
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            sections.forEach { section -> Chip(section, section == active) { onJump(section) } }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.cardBorder))
    }
}

/** How opaque the chips' bar is over what scrolls under it (`.jump`'s 90% ground). */
private const val JUMP_FILL = 0.94f

@Composable
private fun RowScope.Chip(section: MemberSection, on: Boolean, onClick: () -> Unit) {
    val colors = Palette
    Text(
        section.title,
        style = FloorType.text(12.5f, FontWeight.Bold),
        color = if (on) colors.ground else colors.textSecondary,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (on) colors.text else colors.chip)
            .clickable(role = Role.Button, onClickLabel = "Jump to ${section.title}", onClick = onClick)
            .semantics { selected = on }
            .padding(horizontal = 13.dp, vertical = 7.dp),
    )
}

