package app.floor.android.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.unit.DpOffset
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.R
import app.floor.android.design.FloorType
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Palette
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Position
import app.floor.android.model.TopicGroup
import app.floor.android.model.Vote
import app.floor.android.model.chip
import java.time.ZoneId
import java.util.Locale

/**
 * Arena's story hairline: [top] at the top left fading to [fade] by 40% along a 160-degree line,
 * as CSS lays a `linear-gradient(160deg, ...)` over a box of any size.
 */
private fun edgeBrush(top: Color, fade: Color): Brush = object : ShaderBrush() {
    override fun createShader(size: Size): Shader {
        val radians = Math.toRadians(160.0)
        val dx = sin(radians).toFloat()
        val dy = -cos(radians).toFloat()
        val half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        val center = Offset(size.width / 2, size.height / 2)
        return LinearGradientShader(
            from = center - Offset(dx * half, dy * half),
            to = center + Offset(dx * half, dy * half),
            colors = listOf(top, fade, fade),
            colorStops = listOf(0f, 0.4f, 1f),
        )
    }
}

/** At these font scales the steps stack, as iOS does at accessibility sizes. */
@Composable
private fun largeText(): Boolean = LocalDensity.current.fontScale >= 1.5f

private fun TopicGroup.icon(): Int = when (this) {
    TopicGroup.DEFENSE -> R.drawable.ic_topic_defense
    TopicGroup.MONEY -> R.drawable.ic_topic_money
    TopicGroup.COURTS -> R.drawable.ic_topic_courts
    TopicGroup.HEALTH -> R.drawable.ic_topic_health
    TopicGroup.LAND -> R.drawable.ic_topic_land
    TopicGroup.RIGHTS -> R.drawable.ic_topic_rights
    TopicGroup.GOV -> R.drawable.ic_topic_gov
    TopicGroup.OTHER -> R.drawable.ic_topic_other
}

/** A week's header, or its "Also this week" (the mock's `.dayl`). */
@Composable
fun StorySectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = FloorType.text(11f, FontWeight.ExtraBold).copy(letterSpacing = 1.3.sp),
        color = Palette.textMuted,
        modifier = Modifier.padding(horizontal = 4.dp).semantics { heading() },
    )
}

/**
 * One bill or nominee and every final on it, as the locked Finals mock (option B) draws it in the
 * Arena style (iOS `StoryCard`): a band coloured by topic with the title and verdict, CRS's
 * sentence on what it does, each vote as a step, the main step's party split, and your members'
 * votes. The card's hairline is a gradient Brush border and its shadow a drop shadow, never a
 * scaled layer (lesson 76).
 *
 * TalkBack reads the card as one sentence and opens the bill; each step is its own button that
 * opens that vote.
 */
@Composable
fun StoryCard(
    story: Story,
    members: List<StoryMember>,
    zone: ZoneId,
    locale: Locale,
    onOpen: () -> Unit,
    onOpenVote: (Vote) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    val measure = story.measure ?: return
    val main = story.main ?: return
    val shape = RoundedCornerShape(22.dp)
    val highlight = colors.storyHighlight
    Column(
        modifier
            .fillMaxWidth()
            .dropShadow(shape, Shadow(radius = 20.dp, color = colors.storyShadow, spread = (-22).dp, offset = DpOffset(0.dp, 22.dp)))
            .clip(shape)
            .background(colors.card, shape)
            .drawWithContent {
                drawContent()
                drawRect(highlight, size = Size(size.width, 1.dp.toPx()))
            }
            .border(1.dp, edgeBrush(colors.storyEdge, colors.storyEdgeFade), shape)
            .clickable(
                role = Role.Button,
                onClickLabel = if (measure.kind == MeasureSummary.Kind.BILL) "Open the bill" else "Open the confirmation vote",
                onClick = onOpen,
            )
            .semantics { contentDescription = Stories.spoken(story, members) },
    ) {
        Band(story, measure, Stories.verdict(main.vote))
        Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 13.dp, bottom = 14.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
            measure.summaryLead?.let { lead ->
                Column(Modifier.clearAndSetSemantics { }, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        "WHAT IT DOES · CRS SUMMARY",
                        style = FloorType.text(9.5f, FontWeight.ExtraBold).copy(letterSpacing = 1.1.sp),
                        color = colors.textMuted,
                    )
                    Text(lead, style = FloorType.text(13.5f).copy(lineHeight = 1.5.em), color = colors.textSecondary)
                }
            }
            Column {
                story.steps.forEachIndexed { index, step ->
                    if (index > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(colors.cardBorder))
                    Step(step.vote, isMain = step === main, zone, locale) { onOpenVote(step.vote) }
                }
            }
            if (main.partyTotals.isNotEmpty()) SplitBar(main)
            if (members.isNotEmpty()) MemberChips(members)
        }
    }
}

@Composable
private fun Band(story: Story, measure: MeasureSummary, verdict: String?) {
    val colors = Palette
    val ink = colors.bandInk
    val sheen = colors.bandSheen
    val shade = colors.bandShade
    Column(
        Modifier
            .fillMaxWidth()
            .background(colors.topic(story.topic))
            .drawBehind {
                drawRect(Brush.radialGradient(listOf(sheen, Color.Transparent), center = Offset(size.width, 0f), radius = size.width * 0.8f))
                drawRect(Brush.verticalGradient(listOf(Color.Transparent, shade)))
            }
            .clearAndSetSemantics { }
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        val topic: @Composable (Modifier) -> Unit = { m ->
            Row(m.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(story.topic.icon()), contentDescription = null, tint = ink, modifier = Modifier.size(14.dp))
                Text(
                    Stories.topicLine(measure).uppercase(),
                    style = FloorType.text(10.5f, FontWeight.ExtraBold).copy(letterSpacing = 1.2.sp),
                    color = ink,
                )
            }
        }
        val chip: @Composable (Modifier) -> Unit = { m ->
            verdict?.let {
                Text(
                    it,
                    style = FloorType.display(12f, FloorType.Face.BLACK_ITALIC).copy(letterSpacing = 1.sp),
                    color = colors.verdictInk,
                    modifier = m
                        .clip(RoundedCornerShape(7.dp))
                        .background(colors.verdictChip)
                        .padding(start = 8.dp, end = 8.dp, top = 4.dp, bottom = 3.dp),
                )
            }
        }
        // At the largest text sizes the verdict goes above the topic, so the topic line keeps the width.
        if (largeText()) {
            chip(Modifier.padding(bottom = 6.dp))
            topic(Modifier)
        } else {
            Row(verticalAlignment = Alignment.Top) {
                topic(Modifier.weight(1f))
                chip(Modifier.padding(start = 8.dp))
            }
        }
        Text(
            measure.title.uppercase(),
            style = FloorType.display(26f).copy(lineHeight = 1.em),
            color = ink,
            modifier = Modifier.padding(top = 7.dp),
        )
        Text(Stories.citationLine(measure), style = FloorType.text(12f), color = ink, modifier = Modifier.padding(top = 4.dp))
    }
}

/** `245–175` in Arena's score face (Barlow Condensed 900 italic), yea and nay in their colours. */
@Composable
private fun Score(vote: Vote, size: Float) {
    val colors = Palette
    val style = FloorType.display(size, FloorType.Face.BLACK_ITALIC).copy(fontFeatureSettings = "tnum")
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("${vote.totals.yea}", style = style, color = colors.yea)
        Text("–", style = style, color = colors.textMuted)
        Text("${vote.totals.nay}", style = style, color = colors.nay)
    }
}

/** One vote on the measure; the main one has a haloed green dot and a bigger score. */
@Composable
private fun Step(vote: Vote, isMain: Boolean, zone: ZoneId, locale: Locale, onOpen: () -> Unit) {
    val colors = Palette
    val name = Stories.stepName(vote, zone, locale)
    val modifier = Modifier
        .fillMaxWidth()
        .clickable(role = Role.Button, onClickLabel = "Open the vote", onClick = onOpen)
        .clearAndSetSemantics { contentDescription = "$name, ${Stories.spokenScore(vote)}" }
        .padding(vertical = 7.dp)
    val label: @Composable (Modifier) -> Unit = { m ->
        Text(
            name,
            style = FloorType.text(12.5f, if (isMain) FontWeight.Bold else FontWeight.Normal),
            color = if (isMain) colors.text else colors.textSecondary,
            modifier = m,
        )
    }
    val score: @Composable () -> Unit = { Score(vote, if (isMain) 25f else 17f) }
    if (largeText()) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Dot(isMain)
                label(Modifier.weight(1f))
            }
            Row(Modifier.padding(start = 23.dp)) { score() }
        }
    } else {
        Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Dot(isMain)
            label(Modifier.weight(1f))
            score()
        }
    }
}

@Composable
private fun Dot(isMain: Boolean) {
    val colors = Palette
    Box(Modifier.size(14.dp), contentAlignment = Alignment.Center) {
        // A 4dp halo around the 9dp dot.
        if (isMain) Box(Modifier.requiredSize(17.dp).clip(CircleShape).background(colors.yea.copy(alpha = 0.22f)))
        Box(Modifier.size(9.dp).clip(CircleShape).background(if (isMain) colors.yea else colors.raised))
    }
}

/** The main step by party: yea in full party colour, nay at 30% over the track, sized by count. */
@Composable
private fun SplitBar(main: FeedItem) {
    val colors = Palette
    Row(
        Modifier.fillMaxWidth().height(8.dp).clearAndSetSemantics { },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Stories.split(main.partyTotals).forEach { (party, position, count) ->
            val fill = colors.party(party).let { if (position == Position.YEA) it else lerp(colors.track, it, 0.3f) }
            Box(Modifier.weight(count.toFloat()).fillMaxHeight().clip(RoundedCornerShape(4.dp)).background(fill))
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MemberChips(members: List<StoryMember>) {
    val colors = Palette
    val pill = RoundedCornerShape(50)
    FlowRow(
        Modifier.clearAndSetSemantics { },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        members.forEach { m ->
            val p = m.position
            Row(
                Modifier
                    .clip(pill)
                    .background(colors.cardSunken, pill)
                    .border(1.dp, colors.cardBorder, pill)
                    .padding(start = 3.dp, end = 10.dp, top = 3.dp, bottom = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                MemberPortrait(p.member, Modifier.size(24.dp))
                Text(p.member.lastName, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textSecondary)
                Text(
                    p.position.chip(p.choice),
                    style = FloorType.text(12f, FontWeight.ExtraBold),
                    color = when (p.position) {
                        Position.YEA -> colors.yea
                        Position.NAY -> colors.nay
                        else -> colors.textMuted
                    },
                )
                m.sameOnAll?.let { Text(Stories.onAll(it), style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textSecondary) }
            }
        }
    }
}

/** A measure with only procedural votes, or a vote with no measure (the mock's `.mini`, Arena-styled): opens the vote. */
@Composable
fun StoryMini(story: Story, zone: ZoneId, locale: Locale, onOpenVote: (Vote) -> Unit) {
    val colors = Palette
    val vote = story.latest.vote
    val title = Stories.miniTitle(story)
    val line = Stories.miniLine(story, zone, locale)
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(shape)
            .background(colors.card, shape)
            .border(1.dp, colors.cardBorder, shape)
            .clickable(role = Role.Button, onClickLabel = "Open the vote") { onOpenVote(vote) }
            .clearAndSetSemantics { contentDescription = "$title. $line. ${Stories.spokenScore(vote)}." }
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(Modifier.width(5.dp).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(colors.topic(story.topic)))
        Column(Modifier.weight(1f)) {
            Text(title, style = FloorType.text(13.5f, FontWeight.Bold), color = colors.text)
            Text(line, style = FloorType.text(11.5f), color = colors.textMuted)
        }
        Score(vote, 19f)
    }
}
