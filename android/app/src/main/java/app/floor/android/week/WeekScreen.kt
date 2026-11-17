package app.floor.android.week

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.R
import app.floor.android.bills.Failed
import app.floor.android.bills.Spinner
import app.floor.android.design.FloorColors
import app.floor.android.design.glass
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.arenaGround
import app.floor.android.design.SavedDataNote
import app.floor.android.design.dashedPanel
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Chamber
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.model.ScheduleItem
import app.floor.android.model.SenateMeeting
import app.floor.android.store.FollowState

/**
 * The Week tab (iOS `WeekView`, round 11 section A). House: the Majority Leader's list split the way
 * the House splits it, what you follow first with the gold edge. Senate: when it next meets and the
 * Daily Digest's program in its own words, the measures it names linked. An empty side says why,
 * never a blank list, and never that the House is in recess: an unpublished week is not reported as one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeekScreen(
    state: WeekState,
    follows: FollowState,
    onWeek: (Int) -> Unit,
    onChamber: (Chamber) -> Unit,
    onExpand: (ScheduleCategory) -> Unit,
    onRetry: () -> Unit,
    onOpenBill: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    PullToRefreshBox(isRefreshing = false, onRefresh = onRetry, modifier = modifier.fillMaxSize().arenaGround(colors)) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Header(state, onWeek)
            when (val phase = state.phase) {
                WeekState.Phase.Loading -> Spinner("Loading the week")
                is WeekState.Phase.Failed -> Failed(phase.message, onRetry)
                is WeekState.Phase.Loaded -> {
                    state.saved?.let { SavedDataNote(it) }
                    Segment(phase.schedule, state.chamber, onChamber)
                    if (state.chamber == Chamber.HOUSE) {
                        House(phase.schedule, follows, state.expanded, onExpand, onOpenBill)
                    } else {
                        Senate(phase.schedule, follows, onOpenBill)
                    }
                }
            }
        }
    }
}

@Composable
private fun Header(state: WeekState, onWeek: (Int) -> Unit) {
    val colors = Palette
    Row(Modifier.fillMaxWidth().padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(state.title, style = FloorType.headline(28f), color = colors.text, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.weight(1f).width(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Arrow(R.drawable.ic_chevron_left, "Previous week") { onWeek(state.offset - 1) }
            Text(state.range, style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textMuted, maxLines = 1)
            Arrow(R.drawable.ic_chevron_right, "Next week") { onWeek(state.offset + 1) }
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
private fun Segment(schedule: Schedule, chamber: Chamber, onChamber: (Chamber) -> Unit) {
    val colors = Palette
    val listed = schedule.house.items.count { it.removedAt == null }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(colors.panel).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf(Chamber.HOUSE, Chamber.SENATE).forEach { option ->
            val on = option == chamber
            val title = if (option == Chamber.HOUSE && listed > 0) "HOUSE · $listed" else option.title.uppercase()
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (on) colors.chip else Color.Transparent)
                    .clickable(role = Role.Tab) { onChamber(option) }
                    .semantics {
                        selected = on
                        contentDescription = if (option == Chamber.HOUSE) "House, $listed listed" else "Senate"
                    }
                    .padding(vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(title, style = FloorType.label(12f).copy(letterSpacing = 0.6.sp), color = if (on) colors.text else colors.textMuted, maxLines = 1)
            }
        }
    }
}

// MARK: - House

@Composable
private fun House(
    schedule: Schedule,
    follows: FollowState,
    expanded: Set<ScheduleCategory>,
    onExpand: (ScheduleCategory) -> Unit,
    onOpenBill: (String) -> Unit,
) {
    val groups = WeekSort.groups(schedule.house.items, follows)
    if (schedule.house.inSession != true || groups.isEmpty()) {
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
    groups.forEach { group ->
        val open = group.category in expanded
        val shown = if (open) group.rows.size else minOf(group.rows.size, WeekSort.visibleCount(group))
        val hidden = group.rows.size - shown
        GroupHeading("${group.title} · ${group.count}".uppercase())
        group.rows.take(shown).forEach { row -> RowFor(row, onOpenBill) }
        if (hidden > 0) {
            Text(
                "+ $hidden more",
                style = FloorType.text(11.5f, FontWeight.SemiBold),
                color = Palette.threshold,
                modifier = Modifier
                    .heightIn(min = 28.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .clickable(role = Role.Button) { onExpand(group.category) }
                    .semantics { contentDescription = "Show $hidden more ${group.title.lowercase()}" }
                    .padding(horizontal = 2.dp, vertical = 6.dp),
            )
        }
    }
    Footnote(WeekSort.sourceLine(schedule), "Listed means it may come up: the House adds and drops items through the week.")
}

// MARK: - Senate

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
    GroupHeading("NEXT MEETING")
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
