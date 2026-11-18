package app.floor.android.member

import android.provider.Settings
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.FloorColors
import app.floor.android.design.FloorType
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.dashedPanel
import app.floor.android.design.panel
import app.floor.android.model.Member
import app.floor.android.model.Promise
import app.floor.android.model.Promises
import app.floor.android.model.fullName
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Round 13 (the locked mock `floor-said.html`, iOS `SaidView`): Said, the swipe deck of what the
// campaign site promised, quoted exactly; and Posts, under the member's accounts, newest first from
// the free networks. AI only picks the lines, so every deck carries the AI tag and the archive link.

/** The sentence under every deck (product rule "AI is labelled and cited"). */
const val PROMISES_AI_NOTE = "Picked by AI, quoted exactly. It may miss some."

/** True when the system's "Remove animations" is on, or a test asks for a still frame. */
@Composable
private fun rememberStill(): Boolean {
    val context = LocalContext.current
    val systemOff = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    return systemOff || !LocalPlaysArrivalAnimations.current
}

@Composable
private fun AiTag() {
    Text(
        "AI", style = FloorType.label(10.5f).copy(letterSpacing = 1.05.sp), color = Palette.aiInk,
        modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(Palette.ai).padding(vertical = 3.dp, horizontal = 6.dp),
    )
}

/** The mock's `.ph`: a dashed card saying exactly what is missing, never an empty space. */
@Composable
internal fun DashedNote(title: String, body: String, modifier: Modifier = Modifier) {
    val colors = Palette
    Column(
        modifier.dashedPanel(colors.raised, Color.Transparent, 12.dp).padding(12.dp).semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(title.uppercase(), style = FloorType.headline(18f), color = colors.text, textAlign = TextAlign.Center)
        Text(body, style = FloorType.text(11f, FontWeight.Medium), color = colors.textMuted, textAlign = TextAlign.Center)
    }
}

@Composable
private fun <T> Loading(load: Load<T>, spinner: String, onRetry: () -> Unit, content: @Composable (T) -> Unit) {
    when (load) {
        Load.Loading -> Spinner(spinner, top = 40)
        is Load.Failed -> Column(Modifier.panel(Palette), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(load.message, style = FloorType.text(13f), color = Palette.textSecondary)
            TryAgain(onRetry)
        }
        is Load.Loaded -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            load.saved?.let { SavedDataNote(it) }
            content(load.value)
        }
    }
}

// MARK: - Said

@Composable
internal fun SaidContent(
    load: Load<Promises>,
    member: Member?,
    index: Int,
    locale: Locale,
    onIndex: (Int) -> Unit,
    onOpenTopic: (String) -> Unit,
    onRetry: () -> Unit,
) {
    Loading(load, "Loading what the campaign said", onRetry) { said ->
        val name = member?.fullName ?: "this member"
        val year = said.electionYear?.toString()
        when (said.state) {
            Promises.Status.PROMISES -> Deck(said, index, locale, onIndex, onOpenTopic)
            Promises.Status.NO_PLATFORM -> NoPlatform(said, member, locale)
            Promises.Status.NO_SITE -> DashedNote(
                "No campaign site on file",
                "The FEC lists no website for the campaign that won $name this seat${year?.let { " in $it" } ?: ""}, so there are no promises to quote.",
            )
            Promises.Status.NO_SNAPSHOT -> DashedNote(
                "No archived copy",
                "The Internet Archive has no copy of ${said.siteHost ?: "the campaign site"} from before election day${year?.let { " $it" } ?: ""}, so there is nothing to quote.",
            )
            Promises.Status.UNCHECKED -> DashedNote(
                "Not checked yet",
                "Floor hasn't read $name's campaign site yet. What it promised shows here once it has, quoted exactly.",
            )
        }
    }
}

/** Direction 2, the swipe deck: one promise per card, the rest stacked behind it. */
@Composable
private fun Deck(said: Promises, index: Int, locale: Locale, onIndex: (Int) -> Unit, onOpenTopic: (String) -> Unit) {
    val colors = Palette
    val context = LocalContext.current
    val promises = said.promises
    val count = promises.size
    val still = rememberStill()
    val pager = rememberPagerState(initialPage = index.coerceIn(0, count - 1)) { count }
    val scope = rememberCoroutineScope()
    LaunchedEffect(pager) { snapshotFlow { pager.currentPage }.collect(onIndex) }
    val go: (Int) -> Unit = { page ->
        scope.launch { if (still) pager.scrollToPage(page) else pager.animateScrollToPage(page) }
    }
    val archived = said.archivedDay(locale)
    val openArchive: () -> Unit = { (said.snapshotUrl ?: said.pageUrl ?: said.siteUrl)?.let { open(context, it) } }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                listOfNotNull(said.electionYear?.let { "$it campaign" } ?: "Campaign", "$count ${if (count == 1) "promise" else "promises"}")
                    .joinToString(" · ").uppercase(),
                style = FloorType.label(11.5f).copy(letterSpacing = 1.1.sp), color = colors.textMuted,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            AiTag()
        }
        val card: @Composable (Int, Modifier) -> Unit = { page, modifier ->
            PromiseCard(promises[page], page, count, archived, modifier, go, openArchive, onOpenTopic)
        }
        // The stack peeks out below the front card, as the Finals deck's does.
        Box(Modifier.fillMaxWidth().padding(bottom = if (count > 1) 14.dp else 0.dp)) {
            // Every card laid out unseen, so the deck is as tall as its tallest card and doesn't jump.
            Box(Modifier.alpha(0f).clearAndSetSemantics { }) { promises.indices.forEach { card(it, Modifier) } }
            if (count > 2) Behind(colors, colors.card, drop = 14.dp, inset = 14.dp, opacity = 0.5f)
            if (count > 1) Behind(colors, colors.cardSunken, drop = 7.dp, inset = 7.dp, opacity = 0.8f)
            HorizontalPager(
                pager,
                Modifier.matchParentSize(),
                pageSpacing = 16.dp,
                flingBehavior = if (still) PagerDefaults.flingBehavior(pager, snapAnimationSpec = snap()) else PagerDefaults.flingBehavior(pager),
            ) { page -> card(page, Modifier.fillMaxSize()) }
        }
        Row(Modifier.padding(horizontal = 2.dp).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
            AiTag()
            Text(PROMISES_AI_NOTE, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.ai, modifier = Modifier.weight(1f))
        }
        Text(
            "Swipe for the next. The big line is the quote's own words, cut at a clause, never rewritten. " +
                "From ${said.siteHost ?: "the campaign site"}, as the Internet Archive kept it${archived?.let { " on $it" } ?: ""}.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp),
        )
    }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.Behind(colors: FloorColors, fill: Color, drop: Dp, inset: Dp, opacity: Float) {
    // Whole-dp insets and offsets and colour alpha, not a scaled, faded graphics layer: a scaled
    // layer is resampled, and macOS and Linux resample it differently, so the deck's screenshot
    // drifted between this Mac and CI (v0.2.55).
    val shape = RoundedCornerShape(18.dp)
    Box(
        Modifier.matchParentSize()
            .offset(y = drop)
            .padding(horizontal = inset)
            .clip(shape)
            .background(fill.copy(alpha = fill.alpha * opacity), shape)
            .border(1.dp, colors.panelBorder.copy(alpha = colors.panelBorder.alpha * opacity), shape),
    )
}

@Composable
private fun PromiseCard(
    promise: Promise,
    page: Int,
    count: Int,
    archived: String?,
    modifier: Modifier,
    go: (Int) -> Unit,
    openArchive: () -> Unit,
    onOpenTopic: (String) -> Unit,
) {
    val colors = Palette
    val shape = RoundedCornerShape(18.dp)
    val topic = promise.floorTopic
    val heading = promise.heading?.trim()?.takeIf { it.isNotEmpty() }
    val spoken = buildString {
        append("Promise ${page + 1} of $count")
        if (heading != null) append(", under $heading")
        append(". “${promise.quote}”")
        if (archived != null) append(" Archived $archived.")
    }
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Brush.verticalGradient(0f to colors.deckTop, 0.65f to colors.panel), shape)
            .border(1.dp, colors.panelBorder, shape)
            .clearAndSetSemantics {
                contentDescription = spoken
                customActions = listOfNotNull(
                    if (page < count - 1) CustomAccessibilityAction("Next promise") { go(page + 1); true } else null,
                    if (page > 0) CustomAccessibilityAction("Previous promise") { go(page - 1); true } else null,
                    CustomAccessibilityAction("Open the archived page") { openArchive(); true },
                    topic?.let { CustomAccessibilityAction("Open the topic $it") { onOpenTopic(it); true } },
                )
            }
            .padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            // "2 of 3" never breaks across lines.
            "${heading ?: "Promise"} · ${page + 1} of $count".uppercase(),
            style = FloorType.label(11.5f).copy(letterSpacing = 1.6.sp), color = colors.threshold,
        )
        Text("“${promise.headline}”".uppercase(), style = FloorType.headline(25f).copy(lineHeight = 24.sp), color = colors.text)
        Row(Modifier.height(IntrinsicSize.Min)) {
            Box(Modifier.width(2.dp).fillMaxHeight().background(colors.threshold))
            Text(
                promise.quote,
                style = FloorType.text(13f).copy(fontFamily = FontFamily.Serif, fontWeight = FontWeight.Medium, lineHeight = 18.sp),
                color = colors.textSecondary,
                modifier = Modifier.padding(start = 9.dp),
            )
        }
        if (topic != null) {
            Text(
                "Floor topic · $topic ›".uppercase(), style = FloorType.label(10.5f).copy(letterSpacing = 1.sp), color = colors.yea,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(role = Role.Button) { onOpenTopic(topic) }.padding(vertical = 2.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                repeat(count) { i ->
                    val on = i == page
                    Box(
                        Modifier.clip(RoundedCornerShape(3.dp)).clickable(role = Role.Tab) { go(i) }.padding(vertical = 6.dp)
                            .semantics { selected = on },
                    ) {
                        Box(Modifier.size(width = if (on) 16.dp else 6.dp, height = 6.dp).clip(RoundedCornerShape(3.dp)).background(if (on) colors.text else colors.raised))
                    }
                }
            }
            Text(
                if (archived != null) "Archived $archived ›" else "Archived copy ›",
                style = FloorType.text(10.5f, FontWeight.Bold), color = colors.textMuted,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(role = Role.Button, onClick = openArchive).padding(vertical = 4.dp),
            )
        }
    }
}

/** The site listed no issues: the archived page itself, in a browser frame, shows the gap. */
@Composable
private fun NoPlatform(said: Promises, member: Member?, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val url = said.snapshotUrl ?: said.siteUrl
    val host = said.siteHost
    val stamp = said.snapshotInstant?.atZone(ZoneId.of("America/New_York"))?.format(DateTimeFormatter.ofPattern("MMM d yyyy", locale))?.uppercase()
    val shape = RoundedCornerShape(12.dp)
    val name = member?.lastName ?: "This member"
    val year = said.electionYear?.let { "$it " } ?: ""
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(
            Modifier.fillMaxWidth().clip(shape).border(1.dp, colors.panelBorder, shape)
                .then(if (url != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the archived copy") { open(context, url) } else Modifier)
                .clearAndSetSemantics { contentDescription = "The Internet Archive's copy of ${host ?: "the campaign site"}${stamp?.let { ", $it" } ?: ""}" },
        ) {
            Row(
                Modifier.fillMaxWidth().background(colors.browserBar).padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                repeat(2) { Box(Modifier.size(7.dp).clip(RoundedCornerShape(50)).background(colors.browserDot)) }
                Text(
                    host ?: "campaign site", style = FloorType.mono(10f), color = colors.browserChrome, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(5.dp)).background(colors.browserUrl).padding(horizontal = 6.dp, vertical = 4.dp),
                )
            }
            Box(Modifier.fillMaxWidth().background(colors.paper)) {
                Column(
                    Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 30.dp, bottom = 26.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text((host ?: "Campaign site").uppercase(), style = FloorType.headline(20f), color = colors.paperInk, textAlign = TextAlign.Center)
                    listOf(0.7f, 0.5f).forEach { Box(Modifier.fillMaxWidth(it).height(6.dp).clip(RoundedCornerShape(3.dp)).background(colors.paperRule)) }
                }
                if (stamp != null) {
                    Text(
                        "WAYBACK\n$stamp",
                        style = FloorType.mono(9f, FontWeight.Bold).copy(lineHeight = 10.sp), color = colors.wayback,
                        modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).rotate(6f)
                            .border(1.5.dp, colors.wayback, RoundedCornerShape(5.dp)).background(colors.paper.copy(alpha = 0.9f))
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    )
                }
            }
        }
        Text("$name's ${year}campaign site listed no issues.", style = FloorType.text(11f, FontWeight.Bold), color = colors.text)
        Text(
            "Floor shows what the campaign published and doesn't fill the gap from news or speeches.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted,
        )
        if (url != null) {
            Text(
                "Open the archived copy ›", style = FloorType.text(11.5f, FontWeight.SemiBold), color = colors.yea,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(role = Role.Button) { open(context, url) }.padding(2.dp),
            )
        }
    }
}

