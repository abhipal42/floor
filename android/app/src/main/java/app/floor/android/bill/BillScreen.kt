package app.floor.android.bill

import android.content.Intent
import android.icu.text.DateFormat
import android.icu.util.TimeZone
import android.icu.util.ULocale
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import app.floor.android.design.largeText
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.position
import app.floor.android.model.shortLabel
import app.floor.android.model.questionKind
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SkewChip
import app.floor.android.design.outcome
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Bill
import app.floor.android.model.Formats
import app.floor.android.model.StateName
import app.floor.android.model.Topic
import app.floor.android.model.Vote
import app.floor.android.model.VoteKind
import app.floor.android.model.outcome
import app.floor.android.model.sponsorLine
import app.floor.android.vote.TopBar
import java.time.ZoneId
import java.util.Date
import java.util.Locale

/** `Nov 12`: the day a vote happened, in [zone] and [locale] as passed in (HANDOFF lesson 69). */
fun playDay(vote: Vote, zone: ZoneId, locale: Locale): String {
    val instant = vote.occurredAtInstant ?: return ""
    val format = DateFormat.getInstanceForSkeleton("MMMd", ULocale.forLocale(locale))
    format.timeZone = TimeZone.getTimeZone(zone.id)
    return format.format(Date.from(instant))
}

/**
 * A bill, as the locked Bill mock draws it (iOS `BillScreenView`): the title and its sponsor, "On
 * the floor this week" when it is listed, the AI section (labelled, cited to the CRS paragraph,
 * with its disclaimer), six levels to law with the votes that moved it, its topic, the CRS summary
 * itself, Speak up and Share, and what it costs.
 *
 * With a follow list ([follow]) the citation moves above the title beside Follow bill, and the topic
 * card says whether you follow it; without one it sits at the top right, as iOS draws it. "Your
 * members on this bill" follows Speak up when you have members.
 *
 * @param onSpeakUp opens the Speak up sheet ([SpeakUpSheet]), which the caller presents.
 * @param zone the zone a vote's day is printed in; pass it explicitly (lesson 69).
 */
@Composable
fun BillScreen(
    state: BillScreenState,
    back: String,
    zone: ZoneId,
    locale: Locale,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onToggleCitation: (String) -> Unit,
    onRetryAnalysis: () -> Unit,
    onOpenVote: (Vote) -> Unit,
    onOpenTopic: (String) -> Unit,
    onSpeakUp: () -> Unit,
    modifier: Modifier = Modifier,
    follow: BillFollow? = null,
) {
    val colors = Palette
    Column(modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        val bill = (state.phase as? BillScreenState.Phase.Loaded)?.bill
        TopBar(back = back, onBack = onBack, trailing = if (follow == null) bill?.let(::citationLine) else null)
        when (val phase = state.phase) {
            BillScreenState.Phase.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    color = colors.accent,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(22.dp).semantics { contentDescription = "Loading the bill" },
                )
            }
            is BillScreenState.Phase.Failed -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(phase.message, style = FloorType.body(), color = colors.textSecondary, textAlign = TextAlign.Center)
                    Text(
                        "Try again",
                        style = FloorType.text(15f, FontWeight.SemiBold),
                        color = colors.accent,
                        modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onRetry)
                            .padding(6.dp),
                    )
                }
            }
            is BillScreenState.Phase.Loaded -> Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                val loaded = phase.bill
                state.saved?.let { SavedDataNote(it) }
                if (follow != null) FollowRow(loaded, follow)
                Header(loaded)
                state.listing?.let { FloorBanner(it) }
                AIAnalysisSection(state.analysis, state.openCitation, onToggleCitation, onRetryAnalysis)
                Levels(loaded, zone, locale, onOpenVote)
                // Only one of the 32 topics: anything else has no page to open.
                loaded.policyArea?.let(Topic::canonical)?.let { TopicCard(it, follow?.followingTopic?.invoke(it) == true, onOpenTopic) }
                loaded.summary?.takeIf { it.isNotEmpty() }?.let {
                    WhatItDoes(it, loaded.summaryStage, analysisShown = state.analysis is AnalysisPhase.Loaded)
                }
                SpeakUpAndShare(state, loaded, onSpeakUp)
                if (state.yourMembers.isNotEmpty()) YourMembers(state.yourMembers)
                if (loaded.cboEstimates.isNotEmpty()) Cost(loaded)
            }
        }
    }
}

/** Follow bill on the bill screen, and whether you follow a topic (for the topic card). */
data class BillFollow(val following: Boolean, val followingTopic: (String) -> Boolean, val onToggle: () -> Unit)

/** The citation and Follow bill, above the title. */
@Composable
private fun FollowRow(bill: Bill, follow: BillFollow) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(citationLine(bill), style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.threshold, modifier = Modifier.weight(1f))
        app.floor.android.design.FollowPill(follow.following, bill.citation, offTitle = "FOLLOW BILL", onTitle = "✓ FOLLOWING", onToggle = follow.onToggle)
    }
}

/** "Your members on this bill": their position on its latest roll call in their chamber, or that there is none. */
@Composable
private fun YourMembers(members: List<MemberOnBill>) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("YOUR MEMBERS ON THIS BILL", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        members.forEach { entry ->
            Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                app.floor.android.design.MemberPortrait(entry.member, Modifier.size(34.dp))
                val vote = entry.vote
                Text(
                    androidx.compose.ui.text.buildAnnotatedString {
                        pushStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.Bold))
                        append(entry.member.lastName)
                        pop()
                        append(if (vote != null) " · ${vote.chamber.title} ${vote.questionKind.lowercase()}" else " · no ${entry.member.chamber.title} vote on it yet")
                    },
                    style = FloorType.text(13f), color = colors.text, modifier = Modifier.weight(1f),
                )
                entry.position?.let { position ->
                    Text(
                        if (position == app.floor.android.model.Position.CANDIDATE) (entry.choice ?: "BALLOT").uppercase() else position.shortLabel,
                        style = FloorType.display(20f, FloorType.Face.BLACK_ITALIC), color = colors.position(position),
                    )
                }
            }
        }
    }
}

/** `H.R. 5267 · 119TH CONGRESS`. */
private fun citationLine(bill: Bill): String = "${bill.citation} · ${StateName.ordinal(bill.congress)} Congress".uppercase()

@Composable
private fun Header(bill: Bill) {
    val colors = Palette
    val sponsor = listOfNotNull(
        bill.sponsor?.sponsorLine,
        bill.policyArea,
        bill.introducedOn?.let { Formats.dayText(it) }?.let { "introduced $it" },
    ).joinToString(" · ")
    Column(Modifier.semantics(mergeDescendants = true) { heading() }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Shrinks to fit four lines rather than truncating, as iOS's minimumScaleFactor(0.5) does.
        val style = FloorType.headline(46f).copy(color = colors.text)
        BasicText(
            bill.displayTitle.uppercase(),
            style = style,
            maxLines = 4,
            autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize * 0.5f, maxFontSize = style.fontSize),
        )
        Text(sponsor, style = FloorType.text(13f), color = colors.textMuted)
    }
}

/** "On the floor this week" (round 11, section C's bill screen). */
@Composable
private fun FloorBanner(listing: FloorListing) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.threshold.copy(alpha = 0.1f), shape)
            .border(1.dp, colors.threshold.copy(alpha = 0.35f), shape)
            .padding(horizontal = 11.dp, vertical = 9.dp)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text("ON THE FLOOR THIS WEEK", style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.threshold)
        Text(
            listing.bannerLine + " Listed means it may come up; items move through the week.",
            style = FloorType.text(11f),
            color = colors.textSecondary,
        )
    }
}

@Composable
private fun Levels(bill: Bill, zone: ZoneId, locale: Locale, onOpenVote: (Vote) -> Unit) {
    val colors = Palette
    val levels = LawLevels(bill)
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HeadingRow(
            { Text("SIX LEVELS TO LAW", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() }) },
        ) {
            Text(
                levels.status,
                style = FloorType.label(16f),
                color = when {
                    levels.isBlocked -> colors.nay
                    levels.isLaw || levels.isComplete -> colors.yea
                    else -> colors.textSecondary
                },
                maxLines = 1,
            )
        }
        // The six columns are a fixed-size diagram, as on iOS: grown, the names broke mid-word.
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Top) {
            levels.levels.forEach { LevelColumn(it) }
        }
        if (bill.votes.isNotEmpty()) {
            Column {
                bill.votes.reversed().forEach { vote -> Play(vote, zone, locale) { onOpenVote(vote) } }
            }
        }
    }
}

@Composable
private fun RowScope.LevelColumn(level: LawLevels.Level) {
    val colors = Palette
    val bar = when (level.state) {
        LawLevels.State.DONE -> colors.yea
        LawLevels.State.STUCK, LawLevels.State.FAILED -> colors.nay
        LawLevels.State.PENDING, LawLevels.State.NOT_APPLICABLE -> colors.panelBorder
    }
    val reached = level.state in setOf(LawLevels.State.DONE, LawLevels.State.STUCK, LawLevels.State.FAILED)
    val described = when (level.state) {
        LawLevels.State.DONE -> "done"
        LawLevels.State.PENDING -> "not yet"
        LawLevels.State.STUCK -> "stuck"
        LawLevels.State.FAILED -> "failed"
        LawLevels.State.NOT_APPLICABLE -> "does not apply"
    }
    Column(
        Modifier
            .weight(1f)
            .clearAndSetSemantics {
                contentDescription = "Level ${level.number}, ${level.name}: $described${if (level.boss) ", supermajority" else ""}"
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(3.dp)).background(bar))
        Text(
            "${level.number}",
            style = FloorType.display(18f, FloorType.Face.EXTRA_BOLD, scales = false),
            color = if (reached) colors.text else colors.raised,
        )
        Text(
            if (level.state == LawLevels.State.NOT_APPLICABLE) "—" else level.name,
            style = FloorType.text(9f, scales = false),
            color = colors.textMuted,
            textAlign = TextAlign.Center,
            maxLines = 2,
        )
        if (level.boss) SkewChip("BOSS", foreground = colors.ground, background = colors.threshold, size = 9f)
    }
}

/** A heading with a note at its right; at large text sizes the note goes under it rather than colliding. */
@Composable
private fun HeadingRow(heading: @Composable () -> Unit, trailing: @Composable () -> Unit) {
    if (largeText()) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            heading()
            trailing()
        }
    } else {
        Row(verticalAlignment = Alignment.Bottom) {
            heading()
            Spacer(Modifier.weight(1f).width(8.dp))
            trailing()
        }
    }
}

/** One vote on the bill: its day, what it was, and the count, opening the vote. */
@Composable
private fun Play(vote: Vote, zone: ZoneId, locale: Locale, onOpen: () -> Unit) {
    val colors = Palette
    val rule = colors.card
    Row(
        Modifier
            .fillMaxWidth()
            .drawBehind { drawRect(rule, size = Size(size.width, 1.dp.toPx())) }
            .clickable(role = Role.Button, onClickLabel = "Open the vote", onClick = onOpen)
            .padding(vertical = 9.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            playDay(vote, zone, locale),
            style = FloorType.text(12f),
            color = colors.textMuted,
            softWrap = false,
            modifier = Modifier.widthIn(min = 48.dp),
        )
        Text(
            if (vote.kind == VoteKind.ELECTION) vote.question else vote.playDescription,
            style = FloorType.text(13f),
            color = colors.text,
            modifier = Modifier.weight(1f),
        )
        Text(
            "${vote.totals.yea}–${vote.totals.nay}",
            style = FloorType.label(18f).copy(fontFeatureSettings = "tnum"),
            color = colors.outcome(vote.outcome),
        )
    }
}

/** The bill's CRS policy area as a link to its topic's page. */
@Composable
private fun TopicCard(area: String, following: Boolean, onOpen: (String) -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(14.dp)
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("TOPIC", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        Text(
            if (following) "$area ✓ Following" else "$area ›",
            style = FloorType.text(12f, FontWeight.Bold),
            color = colors.threshold,
            modifier = Modifier
                .clip(shape)
                .border(1.dp, colors.threshold, shape)
                .clickable(role = Role.Button, onClickLabel = "Open every bill in $area") { onOpen(area) }
                .semantics { contentDescription = if (following) "Topic: $area, following" else "Topic: $area" }
                .padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun WhatItDoes(summary: String, stage: String?, analysisShown: Boolean) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HeadingRow(
            {
                // With an analysis above, "What it does" is its first heading, so this one names its source.
                Text(
                    if (analysisShown) "CRS SUMMARY" else "WHAT IT DOES",
                    style = FloorType.label(20f),
                    color = colors.text,
                    modifier = Modifier.semantics { heading() },
                )
            },
        ) {
            if (stage != null) Text(stage, style = FloorType.text(11f), color = colors.textMuted)
        }
        Text(summary, style = FloorType.text(13f).copy(lineHeight = 19.sp), color = colors.textSecondary)
        // Not our words, and not a model's: the Congressional Research Service summary.
        Text("Congressional Research Service summary", style = FloorType.text(11f), color = colors.textMuted)
    }
}

/** Speak up and Share, under the summary. Share is the system share sheet with the API's line and link. */
@Composable
private fun SpeakUpAndShare(state: BillScreenState, bill: Bill, onSpeakUp: () -> Unit) {
    val context = LocalContext.current
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ActionButton("SPEAK UP", filled = true, hint = "Write or call your own members about this bill", onClick = onSpeakUp)
        ActionButton("SHARE", filled = false, hint = "Sends a link to this bill's page, which opens in any browser") {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, bill.citation)
                putExtra(Intent.EXTRA_TEXT, state.shareText(bill))
            }
            context.startActivity(Intent.createChooser(send, null))
        }
    }
}

@Composable
private fun RowScope.ActionButton(title: String, filled: Boolean, hint: String, onClick: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(9.dp)
    Text(
        title,
        style = FloorType.label(13f).copy(letterSpacing = 0.6.sp, textAlign = TextAlign.Center),
        color = if (filled) colors.ground else colors.text,
        modifier = Modifier
            .weight(1f)
            .clip(shape)
            .background(if (filled) colors.threshold else Color.Transparent, shape)
            .then(if (filled) Modifier else Modifier.border(1.dp, colors.raised, shape))
            .clickable(role = Role.Button, onClickLabel = hint, onClick = onClick)
            .padding(vertical = 10.dp),
    )
}

@Composable
private fun Cost(bill: Bill) {
    val colors = Palette
    val context = LocalContext.current
    val one = bill.cboEstimates.size == 1
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("COST", style = FloorType.label(20f), color = colors.text, modifier = Modifier.semantics { heading() })
        Text(
            if (one) "Congressional Budget Office estimate available."
            else "${bill.cboEstimates.size} Congressional Budget Office estimates available.",
            style = FloorType.text(13f),
            color = colors.textSecondary,
        )
        bill.cboEstimates.forEach { estimate ->
            Text(
                if (one) "Open the CBO estimate ›" else "${estimate.title} ›",
                style = FloorType.text(13f, FontWeight.SemiBold),
                color = colors.yea,
                modifier = Modifier.clickable(role = Role.Button) { open(context, estimate.url) },
            )
        }
    }
}
