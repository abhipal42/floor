package app.floor.android.week

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.R
import app.floor.android.bills.Failed
import app.floor.android.bills.Spinner
import app.floor.android.design.FloorColors
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SkewChip
import app.floor.android.design.arenaGround
import app.floor.android.design.dashedPanel
import app.floor.android.design.glass
import app.floor.android.design.heroEdge
import app.floor.android.home.TabBarClearance
import app.floor.android.model.RecentVote
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.model.ScheduleItem
import app.floor.android.model.SenateMeeting
import app.floor.android.store.FollowState
import app.floor.android.vote.TopBar
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/**
 * The Week tab (v0.2.59, "Your picks" of the locked mock; iOS `WeekView`): both chambers on one
 * scroll. A one-line summary from the schedule, then HEADLINERS (the Senate measures the Digest's
 * program names and the House bills up under a rule), SENATE NEXT (today's meeting or the next),
 * FAST TRACK (the House's suspensions as topic tiles) and anything else listed. "Program ›", a tile
 * and "All ›" open their rows on their own screen ([WeekState.Detail]). An empty side says why,
 * never that the House is in recess: an unpublished week is not reported as one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeekScreen(
    state: WeekState,
    follows: FollowState,
    /** The latest finals, for each headliner's vote chips. */
    votes: List<RecentVote>,
    /** The reader's zone and locale, passed rather than read inside (lesson 69): the chips' days. */
    zone: ZoneId,
    locale: Locale,
    onWeek: (Int) -> Unit,
    onOpen: (WeekState.Detail?) -> Unit,
    onRetry: () -> Unit,
    onOpenBill: (String) -> Unit,
    modifier: Modifier = Modifier,
    /** What "today" is for SENATE NEXT. */
    now: Instant = Instant.now(),
) {
    val colors = Palette
    val schedule = (state.phase as? WeekState.Phase.Loaded)?.schedule
    val detail = state.detail
    if (detail != null && schedule != null) {
        BackHandler { onOpen(null) }
        Detail(detail, schedule, follows, onBack = { onOpen(null) }, onOpenBill = onOpenBill, modifier = modifier)
        return
    }
    PullToRefreshBox(isRefreshing = false, onRefresh = onRetry, modifier = modifier.fillMaxSize().arenaGround(colors)) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Header(state, onWeek)
            when (val phase = state.phase) {
                WeekState.Phase.Loading -> Spinner("Loading the week")
                is WeekState.Phase.Failed -> Failed(phase.message, onRetry)
                is WeekState.Phase.Loaded -> {
                    state.saved?.let { SavedDataNote(it) }
                    Week(phase.schedule, follows, votes, zone, locale, now, onOpen, onOpenBill)
                }
            }
        }
    }
}

@Composable
private fun Header(state: WeekState, onWeek: (Int) -> Unit) {
    val colors = Palette
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(state.title, style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() })
            Spacer(Modifier.weight(1f).width(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Arrow(R.drawable.ic_chevron_left, "Previous week") { onWeek(state.offset - 1) }
                Text(state.range, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textMuted, maxLines = 1)
                Arrow(R.drawable.ic_chevron_right, "Next week") { onWeek(state.offset + 1) }
            }
        }
        (state.phase as? WeekState.Phase.Loaded)?.let {
            Text(WeekPlan.summary(it.schedule), style = FloorType.text(13f), color = colors.textMuted)
        }
    }
}

@Composable
private fun Arrow(icon: Int, label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .sizeIn(minWidth = 28.dp, minHeight = 28.dp)
            .clip(RoundedCornerShape(7.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = Palette.threshold, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun Week(
    schedule: Schedule,
    follows: FollowState,
    votes: List<RecentVote>,
    zone: ZoneId,
    locale: Locale,
    now: Instant,
    onOpen: (WeekState.Detail?) -> Unit,
    onOpenBill: (String) -> Unit,
) {
    val headliners = WeekPlan.headliners(schedule, votes, follows, zone, locale)
    if (headliners.isNotEmpty()) {
        Section("HEADLINERS")
        headliners.forEach { HeadlinerCard(it, onOpenBill) }
    }

    val senate = schedule.senate
    if (senate == null || senate.meetings.isEmpty()) {
        Section("SENATE NEXT")
        Placeholder("No Senate meeting posted", schedule.senateReason ?: "The Senate hasn't named a meeting in this week.")
    } else {
        Section("SENATE NEXT", link = "Program ›", linkSpoken = "Open the Senate's program") { onOpen(WeekState.Detail.Senate) }
        WeekPlan.senateNext(senate, now)?.let { SenateNext(it, now) { onOpen(WeekState.Detail.Senate) } }
    }

    val house = schedule.house.items
    val tiles = WeekPlan.fastTrack(house, follows)
    if (schedule.house.inSession != true || house.isEmpty()) {
        Placeholder(
            "No floor schedule posted",
            "No floor schedule posted for this week. The House lists each week's bills ahead of time, and they show here once it does.",
            Modifier.padding(top = 14.dp),
        )
        Placeholder(
            "Nothing you follow is scheduled",
            // iOS adds "and you can get an alert": Android has no alerts yet (no push).
            "Follow a bill or a topic and it shows here the week it reaches the floor.",
        )
        return
    }
    if (tiles.isNotEmpty()) {
        Section("FAST TRACK · ${tiles.sumOf { it.count }}", link = "All ›", linkSpoken = "Every fast-track bill") { onOpen(WeekState.Detail.FastTrack(null)) }
        Text(
            "House bills that need two-thirds and usually pass without debate.",
            style = FloorType.text(12.5f),
            color = Palette.textMuted,
        )
        Tiles(tiles) { onOpen(WeekState.Detail.FastTrack(it.topic)) }
    }
    val also = WeekPlan.alsoListed(house, follows)
    if (also.isNotEmpty()) {
        Section("ALSO LISTED")
        also.forEach { RowFor(it, onOpenBill) }
    }
    Footnote(WeekSort.sourceLine(schedule), "Listed means it may come up: the House adds and drops items through the week.")
}

/** A headliner: the topic's 4dp top edge (gold when you follow it), the cite chip, the chamber, the title, the context, the votes. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeadlinerCard(headliner: Headliner, onOpenBill: (String) -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(22.dp)
    val item = headliner.item
    val id = item.billId
    val followed = headliner.row.followed != null
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, shape, edge = colors.heroEdge())
            .then(if (id != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the bill") { onOpenBill(id) } else Modifier)
            .clearAndSetSemantics {
                contentDescription = listOfNotNull(
                    item.label, headliner.label.lowercase().replaceFirstChar(Char::uppercase), headliner.headline, headliner.context,
                    if (followed) "You follow this" else null,
                ).plus(headliner.chips).joinToString(". ")
            },
    ) {
        Box(Modifier.fillMaxWidth().height(4.dp).background(if (followed) colors.threshold else colors.topic(headliner.topic)))
        Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SkewChip(item.label, size = 13f)
                Spacer(Modifier.weight(1f).width(8.dp))
                Text(
                    headliner.label,
                    style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp),
                    color = colors.chamberText(headliner.chamber),
                    maxLines = 1,
                )
            }
            Text(
                headliner.headline.uppercase(),
                style = FloorType.display(25f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 25.sp),
                color = colors.text,
                modifier = Modifier.padding(top = 10.dp),
            )
            headliner.context?.let {
                Text(it, style = FloorType.text(12.5f).copy(lineHeight = 18.sp), color = colors.textSecondary, modifier = Modifier.padding(top = 7.dp))
            }
            if (headliner.chips.isNotEmpty()) {
                FlowRow(Modifier.padding(top = 11.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    headliner.chips.forEach { VoteChip(it) }
                }
            }
        }
    }
}

@Composable
private fun VoteChip(text: String) {
    val colors = Palette
    val pill = RoundedCornerShape(50)
    Text(
        text,
        style = FloorType.text(12.5f, FontWeight.SemiBold),
        color = colors.textSecondary,
        maxLines = 1,
        modifier = Modifier
            .clip(pill)
            .background(colors.chip, pill)
            .padding(horizontal = 11.dp, vertical = 6.dp),
    )
}

/** Today's meeting, or the next one: the day and the convene time big, the heading and the program's first sentence. */
@Composable
private fun SenateNext(meeting: SenateMeeting, now: Instant, onProgram: () -> Unit) {
    val colors = Palette
    val time = WeekPlan.convenes(meeting)
    Row(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClickLabel = "Open the Senate's program", onClick = onProgram)
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.widthIn(min = 52.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(WeekPlan.meetingDay(meeting, now), style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.textMuted)
            if (time != null) {
                Text(time.first, style = FloorType.display(26f, FloorType.Face.BLACK_ITALIC), color = colors.text)
                Text(time.second, style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.textMuted)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(meeting.heading ?: WeekSort.convenes(meeting), style = FloorType.text(14.5f, FontWeight.Bold), color = colors.text)
            val program = meeting.program
            when {
                meeting.proForma -> Text(
                    "Pro forma session: the Senate meets for seconds and does no business.",
                    style = FloorType.text(12.5f), color = colors.textMuted,
                )
                program != null -> Text(
                    WeekPlan.sentences(program).firstOrNull() ?: program,
                    style = FloorType.text(12.5f), color = colors.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                else -> Text(
                    "The program comes out with the Congressional Record, usually the morning after the Senate adjourns.",
                    style = FloorType.text(12.5f), color = colors.textMuted,
                )
            }
        }
    }
}

/** Two columns of glass tiles, one per topic group: the count big in the topic's colour, then its name. */
@Composable
private fun Tiles(tiles: List<FastTrackTile>, onTile: (FastTrackTile) -> Unit) {
    val colors = Palette
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(2).forEach { pair ->
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                pair.forEach { tile ->
                    Column(
                        Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .glass(colors, RoundedCornerShape(14.dp))
                            .clickable(role = Role.Button, onClickLabel = "Open these bills") { onTile(tile) }
                            .clearAndSetSemantics { contentDescription = "${tile.count} fast-track ${if (tile.count == 1) "bill" else "bills"} in ${tile.topic.title}" }
                            .padding(12.dp),
                    ) {
                        Text("${tile.count}", style = FloorType.display(26f, FloorType.Face.BLACK_ITALIC), color = colors.topicText(tile.topic))
                        Text(tile.topic.title, style = FloorType.text(12f), color = colors.textSecondary)
                    }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// MARK: - Screens opened from the week

@Composable
private fun Detail(
    detail: WeekState.Detail,
    schedule: Schedule,
    follows: FollowState,
    onBack: () -> Unit,
    onOpenBill: (String) -> Unit,
    modifier: Modifier,
) {
    val colors = Palette
    Column(modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = "Week", onBack = onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            when (detail) {
                WeekState.Detail.Senate -> {
                    Text("SENATE", style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() })
                    Senate(schedule, follows, onOpenBill)
                }
                is WeekState.Detail.FastTrack -> {
                    val tiles = WeekPlan.fastTrack(schedule.house.items, follows)
                    val rows = detail.topic?.let { t -> tiles.firstOrNull { it.topic == t }?.rows }
                        ?: WeekSort.groups(schedule.house.items.filter { it.category == ScheduleCategory.SUSPENSION }, follows).flatMap { it.rows }
                    Text(
                        "FAST TRACK" + (detail.topic?.let { " · ${it.title.uppercase()}" } ?: ""),
                        style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() },
                    )
                    Text("House bills that need two-thirds and usually pass without debate.", style = FloorType.text(12.5f), color = colors.textMuted)
                    rows.forEach { RowFor(it, onOpenBill) }
                    Footnote(WeekSort.sourceLine(schedule))
                }
            }
        }
    }
}

/** Today's Senate content, as the Senate side of the week showed it before v0.2.59. */
@Composable
private fun Senate(schedule: Schedule, follows: FollowState, onOpenBill: (String) -> Unit) {
    val senate = schedule.senate
    if (senate == null || senate.meetings.isEmpty()) {
        Placeholder(
            "No Senate meeting posted",
            schedule.senateReason ?: "The Senate hasn't named a meeting in this week.",
            Modifier.padding(top = 14.dp),
        )
        return
    }
    senate.meetings.forEach { Meeting(it, senate.items, onOpenBill) }
    if (senate.items.isNotEmpty()) {
        GroupHeading("MEASURES NAMED")
        WeekSort.groups(senate.items, follows).flatMap { it.rows }.forEach { RowFor(it, onOpenBill) }
    }
    Footnote(
        "The Senate plans a day at a time: it posts the next day's plan when it adjourns, so this side fills in through the week.",
        WeekSort.senateSource(senate),
    )
}

@Composable
private fun Meeting(meeting: SenateMeeting, items: List<ScheduleItem>, onOpenBill: (String) -> Unit) {
    val colors = Palette
    GroupHeading("MEETING")
    Column(Modifier.card(colors).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(WeekSort.convenes(meeting), style = FloorType.text(13f, FontWeight.Bold), color = colors.text)
        if (meeting.proForma) {
            Text(
                "Pro forma session: the Senate meets for seconds and does no business.",
                style = FloorType.text(10.5f, FontWeight.Medium),
                color = colors.textMuted,
            )
        }
    }
    if (!meeting.proForma) {
        Column(Modifier.card(colors, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("PROGRAM · DAILY DIGEST", style = FloorType.label(11f).copy(letterSpacing = 1.1.sp), color = colors.textMuted)
            val program = meeting.program
            if (program != null) {
                Text(
                    linked(program, items, onOpenBill),
                    style = FloorType.text(12.5f).copy(lineHeight = 18.sp),
                    color = colors.text,
                )
            } else {
                Text(
                    "The program comes out with the Congressional Record, usually the morning after the Senate adjourns.",
                    style = FloorType.text(12f),
                    color = colors.textMuted,
                )
            }
        }
    }
}

/** The program verbatim, each measure it names that Floor has a page for made a link to its bill. */
@Composable
private fun linked(program: String, items: List<ScheduleItem>, onOpenBill: (String) -> Unit): AnnotatedString {
    val style = TextLinkStyles(SpanStyle(color = Palette.threshold, textDecoration = TextDecoration.Underline))
    return buildAnnotatedString {
        append(program)
        WeekSort.links(program, items).forEach { link ->
            addLink(LinkAnnotation.Clickable(link.billId, style) { onOpenBill(link.billId) }, link.start, link.end)
        }
    }
}

// MARK: - Pieces

/** A section's title (the mock's `.sect h3`), with its link on the right when it has one. */
@Composable
private fun Section(title: String, link: String? = null, linkSpoken: String? = null, onLink: (() -> Unit)? = null) {
    val colors = Palette
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, style = FloorType.display(19f), color = colors.text, modifier = Modifier.weight(1f).semantics { heading() })
        if (link != null && onLink != null) {
            Text(
                link,
                style = FloorType.text(12.5f, FontWeight.SemiBold),
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

@Composable
private fun GroupHeading(text: String) {
    Text(
        text,
        style = FloorType.label(11.5f).copy(letterSpacing = 1.2.sp),
        color = Palette.threshold,
        modifier = Modifier.padding(start = 2.dp, end = 2.dp, top = 6.dp).semantics { heading() },
    )
}

@Composable
private fun Footnote(vararg lines: String) {
    Column(Modifier.padding(start = 2.dp, end = 2.dp, top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        lines.forEach { Text(it, style = FloorType.text(10.5f, FontWeight.Medium), color = Palette.textMuted) }
    }
}

@Composable
private fun Placeholder(title: String, body: String, modifier: Modifier = Modifier) {
    val colors = Palette
    Column(
        modifier
            .dashedPanel(colors.raised, Color.Transparent)
            .padding(12.dp)
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(title.uppercase(), style = FloorType.display(18f, FloorType.Face.BLACK_ITALIC), color = colors.text, textAlign = TextAlign.Center)
        Text(body, style = FloorType.text(11.5f, FontWeight.Medium), color = colors.textMuted, textAlign = TextAlign.Center)
    }
}

/** The mock's `.wk` card: panel, hairline, 12dp corners. */
private fun Modifier.card(colors: FloorColors, vertical: androidx.compose.ui.unit.Dp = 9.dp): Modifier {
    val shape = RoundedCornerShape(12.dp)
    return fillMaxWidth().glass(colors, shape).padding(horizontal = 11.dp, vertical = vertical)
}

@Composable
private fun RowFor(row: WeekSort.Row, onOpenBill: (String) -> Unit) {
    val id = row.item.billId
    WeekRow(row, if (id != null) ({ onOpenBill(id) }) else null)
}

/** One item on a week's list: citation, a FOLLOWING tag, the title, the latest step; a gold leading edge when you follow it. */
@Composable
internal fun WeekRow(row: WeekSort.Row, onOpen: (() -> Unit)?) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    val edge = row.followed != null && !row.pulled
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .alpha(if (row.pulled) 0.6f else 1f)
            .glass(colors, shape)
            .then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the bill", onClick = onOpen) else Modifier)
            .clearAndSetSemantics { contentDescription = WeekSort.spoken(row) },
    ) {
        if (edge) Box(Modifier.width(3.dp).fillMaxHeight().background(colors.threshold))
        Column(
            Modifier.weight(1f).padding(start = if (edge) 8.dp else 11.dp, end = 11.dp, top = 9.dp, bottom = 9.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(row.item.label.uppercase(), style = FloorType.label(12f).copy(letterSpacing = 0.8.sp), color = colors.threshold, maxLines = 1)
                Spacer(Modifier.weight(1f).width(4.dp))
                val tag = WeekSort.tag(row.followed)
                if (row.pulled) {
                    Text("OFF THE LIST", style = FloorType.label(10f).copy(letterSpacing = 0.8.sp), color = colors.textMuted)
                } else if (tag != null) {
                    Text(tag, style = FloorType.label(10f).copy(letterSpacing = 0.8.sp), color = colors.threshold, maxLines = 1)
                }
            }
            Text(row.item.title, style = FloorType.text(13f, FontWeight.Bold), color = colors.text)
            row.item.latestLine?.let { Text(it, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted) }
        }
    }
}
