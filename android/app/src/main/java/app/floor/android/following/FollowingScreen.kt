package app.floor.android.following

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bills.BillsState
import app.floor.android.bills.Failed
import app.floor.android.bills.Spinner
import app.floor.android.bills.memberCaption
import app.floor.android.design.BillRow
import app.floor.android.design.ChipSwitch
import app.floor.android.design.FloorType
import app.floor.android.design.FollowPill
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Palette
import app.floor.android.design.PositionChip
import app.floor.android.design.TopicRow
import app.floor.android.design.dashedPanel
import app.floor.android.home.TabBarClearance
import app.floor.android.member.DashedNote
import app.floor.android.member.Load
import app.floor.android.member.PostCard
import app.floor.android.model.PostsWall
import app.floor.android.model.BillRoad
import app.floor.android.model.Delegation
import app.floor.android.model.Member
import app.floor.android.model.MemberVote
import app.floor.android.model.PartyLoyalty
import app.floor.android.model.SpokenBill
import app.floor.android.model.SpokenMember
import app.floor.android.model.Topic
import app.floor.android.model.TopicText
import app.floor.android.model.fullName
import app.floor.android.store.FollowKind
import app.floor.android.store.FollowState
import java.time.ZoneId
import java.util.Locale

/** The switch at the top of the tab. */
enum class FollowingSegment { MEMBERS, BILLS, TOPICS, POSTS }

/** Everything the Following tab draws, so a test can draw any state. */
data class FollowingState(
    val follows: FollowState = FollowState(),
    val delegation: Delegation? = null,
    val segment: FollowingSegment = FollowingSegment.MEMBERS,
    val editing: Boolean = false,
    val loyalty: Map<String, PartyLoyalty> = emptyMap(),
    /** Each member's recent votes, newest first: the latest-vote chip. */
    val records: Map<String, List<MemberVote>> = emptyMap(),
    /** The 32 topics with their counts: the Topics segment's counts and suggestions. */
    val topics: BillsState.Phase = BillsState.Phase.Loading,
    /** Your members' posts: the Posts segment. */
    val wall: Load<PostsWall> = Load.Loading,
) {
    val reps: List<Member> get() = delegation?.members.orEmpty()

    /** Whose posts the wall shows: your reps, then who you follow, the API's first twelve. */
    val wallMembers: List<Member> get() = follows.yourMembers(reps).take(PostsWall.MAX_MEMBERS)

    /** Everyone you follow who is not one of your reps. */
    val followed: List<Member> get() = follows.followed(reps)

    /** Edit is reachable whenever there is something to edit. */
    val canEdit: Boolean get() = delegation != null || followed.isNotEmpty()

    fun count(segment: FollowingSegment): Int = when (segment) {
        FollowingSegment.MEMBERS -> follows.yourMembers(reps).size
        FollowingSegment.BILLS -> follows.followedBills.size
        FollowingSegment.TOPICS -> follows.followedTopics.size
        FollowingSegment.POSTS -> 0
    }

    /** `MEMBERS · 3`; Posts carries no count (posts are never tallied). */
    fun label(segment: FollowingSegment): String =
        if (segment == FollowingSegment.POSTS) segment.name else "${segment.name} · ${count(segment)}"

    /** Topics you don't follow, biggest first: the suggestions. */
    val suggestedTopics: List<Topic>
        get() = (topics as? BillsState.Phase.Loaded)?.topics.orEmpty()
            .filter { it.name !in follows.followedTopics && it.bills > 0 }
            .sortedWith(compareByDescending<Topic> { it.bills }.thenBy { it.name })
            .take(6)

    fun topic(name: String): Topic? = (topics as? BillsState.Phase.Loaded)?.topics?.firstOrNull { it.name == name }
}

/** The tab's callbacks. */
class FollowingActions(
    val onSegment: (FollowingSegment) -> Unit = {},
    val onEditing: (Boolean) -> Unit = {},
    val onAdd: () -> Unit = {},
    val onUpdate: ((FollowState) -> FollowState) -> Unit = {},
    val onOpenMember: (Member) -> Unit = {},
    val onOpenBill: (String) -> Unit = {},
    val onOpenTopic: (String) -> Unit = {},
    val onFindReps: () -> Unit = {},
    val onRetryTopics: () -> Unit = {},
    val onRetryWall: () -> Unit = {},
)

/**
 * The Following tab (iOS `FollowingView`, the locked Round 10 design): Members · Bills · Topics over
 * three lists. Members: your reps, pinned from your district, then everyone you follow. Edit hides
 * or shows a rep (they can't be unfollowed: they are your district), unfollows anyone else, and
 * reorders with Move up / Move down rather than iOS's drag handle. Bills: each followed bill's row.
 * Topics: followed topics with their counts, then the biggest others as suggestions.
 *
 * iOS's bell (the Alerts screen) is left out: alerts need push, which Android does not have yet,
 * and the tab says so rather than drawing switches that would do nothing.
 */
@Composable
fun FollowingScreen(state: FollowingState, actions: FollowingActions, zone: ZoneId, locale: Locale) {
    val colors = Palette
    LazyColumn(
        Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        item { Header(state, actions) }
        item {
            ChipSwitch(
                FollowingSegment.entries, state.segment, state::label, actions.onSegment,
                spoken = {
                    val name = it.name.lowercase().replaceFirstChar { c -> c.uppercase() }
                    if (it == FollowingSegment.POSTS) "$name from your members" else "$name, ${state.count(it)} followed"
                },
            )
        }
        when (state.segment) {
            FollowingSegment.MEMBERS -> {
                reps(state, actions, zone)
                following(state, actions, zone)
            }
            FollowingSegment.BILLS -> bills(state, actions)
            FollowingSegment.TOPICS -> topics(state, actions)
            FollowingSegment.POSTS -> posts(state, actions, zone, locale)
        }
    }
}

// MARK: Posts

/**
 * The wall (round 13): your members' posts from YouTube, Bluesky and Mastodon, newest first, never
 * ranked or counted; then one dashed note naming everyone whose accounts are all links-only.
 */
private fun LazyListScope.posts(state: FollowingState, actions: FollowingActions, zone: ZoneId, locale: Locale) {
    val members = state.wallMembers
    if (members.isEmpty()) {
        item {
            EmptyCard(
                "NO MEMBERS YET",
                "Set your district or follow members, and their posts from YouTube, Bluesky and Mastodon show here.",
                "FIND MEMBERS TO FOLLOW", filled = true, onClick = actions.onAdd,
            )
        }
        return
    }
    item { GroupHeader("YOUR MEMBERS' POSTS", "Newest first") }
    when (val wall = state.wall) {
        Load.Loading -> item { Spinner("Loading your members' posts") }
        is Load.Failed -> item { Failed(wall.message, actions.onRetryWall) }
        is Load.Loaded -> {
            wall.saved?.let { saved -> item { app.floor.android.design.SavedDataNote(saved) } }
            val byId = members.associateBy { it.bioguideId }
            val posts = wall.value.shown
            if (posts.isEmpty()) {
                item {
                    DashedNote("Nothing posted lately", "None of your members has posted on YouTube, Bluesky or Mastodon in the last 30 days.")
                }
            }
            items(posts, key = { "post-" + it.id }) { post ->
                PostCard(post, zone, locale, byline = post.memberId?.let { byId[it]?.lastName }, compact = true)
            }
            val unreadable = wall.value.unreadable.mapNotNull { byId[it] }
            if (unreadable.isNotEmpty()) {
                item {
                    val names = unreadable.map { it.lastName }
                    val who = if (names.size == 1) names[0] else names.dropLast(1).joinToString(", ") + " and " + names.last()
                    DashedNote(
                        "$who ${if (names.size == 1) "posts" else "post"} only on X or Facebook",
                        "Neither lets apps read posts for free, so ${if (names.size == 1) "those posts are" else "their posts are"} links on the Contact tab.",
                    )
                }
            }
        }
    }
}

@Composable
private fun Header(state: FollowingState, actions: FollowingActions) {
    val colors = Palette
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("FOLLOWING", style = FloorType.headline(28f), color = colors.text, modifier = Modifier.semantics { heading() })
            Spacer(Modifier.weight(1f))
            if (!state.editing && state.canEdit && state.segment == FollowingSegment.MEMBERS) {
                HeaderButton("EDIT", "Edit your members") { actions.onEditing(true) }
                Spacer(Modifier.width(14.dp))
            }
            HeaderButton(if (state.editing) "DONE" else "+ ADD", if (state.editing) "Done editing" else "Add members, bills or topics") {
                if (state.editing) actions.onEditing(false) else actions.onAdd()
            }
        }
        Text("Alerts come to Android later.", style = FloorType.text(11f), color = colors.textMuted)
    }
}

@Composable
private fun HeaderButton(text: String, spoken: String, onClick: () -> Unit) {
    Text(
        text, style = FloorType.label(15f), color = Palette.threshold,
        modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = spoken }.padding(4.dp),
    )
}

// MARK: Members

private fun LazyListScope.reps(state: FollowingState, actions: FollowingActions, zone: ZoneId) {
    val delegation = state.delegation
    if (delegation == null) {
        item { GroupHeader("YOUR REPS", null) }
        item {
            EmptyCard(
                "NO DISTRICT YET",
                "Add your address or use your location to pin your own representative and senators here.",
                "FIND MY REPS", filled = false, onClick = actions.onFindReps,
            )
        }
        return
    }
    val shown = if (state.editing) state.reps else state.follows.visibleReps(state.reps)
    item {
        GroupHeader(
            "YOUR REPS · ${delegation.district.name}",
            if (state.editing) "Change address" else "From your address",
            action = if (state.editing) actions.onFindReps else null,
        )
    }
    items(shown, key = { "rep-" + it.bioguideId }) { member ->
        if (state.editing) RepEditRow(member, state.follows.isHidden(member.bioguideId)) {
            actions.onUpdate { s -> s.setHidden(member.bioguideId, !s.isHidden(member.bioguideId)) }
        } else PlayerRow(member, state, zone) { actions.onOpenMember(member) }
    }
    if (!state.editing && shown.isEmpty()) {
        item { Text("You hid all your reps. Edit to show them again.", style = FloorType.text(12f), color = Palette.textMuted) }
    }
}

private fun LazyListScope.following(state: FollowingState, actions: FollowingActions, zone: ZoneId) {
    val followed = state.followed
    if (followed.isEmpty()) {
        item { GroupHeader("FOLLOWING", null, modifier = Modifier.padding(top = 6.dp)) }
        item {
            EmptyCard(
                "FOLLOW ANYONE IN CONGRESS",
                "Search by name, state or district. Their votes show up in Finals.",
                "FIND MEMBERS TO FOLLOW", filled = true, onClick = actions.onAdd,
            )
        }
        return
    }
    item {
        GroupHeader(
            "FOLLOWING · ${followed.size}",
            if (state.editing) "Move up or down to reorder" else "Edit",
            action = if (state.editing) null else ({ actions.onEditing(true) }),
            modifier = Modifier.padding(top = 6.dp),
        )
    }
    itemsIndexed(followed, key = { _, m -> "followed-" + m.bioguideId }) { index, member ->
        if (state.editing) {
            FollowedEditRow(member, index, followed.size, actions)
        } else {
            PlayerRow(member, state, zone) { actions.onOpenMember(member) }
        }
    }
}

private fun percent(share: Double) = String.format(Locale.US, "%.1f%%", share * 100)

/** The compact player row: portrait, name, party · chamber · seat, loyalty, latest vote. */
@Composable
private fun PlayerRow(member: Member, state: FollowingState, zone: ZoneId, onOpen: () -> Unit) {
    val colors = Palette
    val share = state.loyalty[member.bioguideId]?.withPartyShare
    val latest = state.records[member.bioguideId]?.firstOrNull()
    Row(
        Modifier.rowSurface(Palette).clickable(role = Role.Button, onClickLabel = "Open their record", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = SpokenMember.followingRow(member, share, latest, zone) }
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        MemberPortrait(member, Modifier.size(30.dp))
        NameBlock(member, memberCaption(member), Modifier.weight(1f))
        if (share != null) {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(percent(share), style = FloorType.display(17f, FloorType.Face.BLACK_ITALIC), color = colors.text)
                Text("with party", style = FloorType.text(9.5f, FontWeight.Medium), color = colors.textMuted)
            }
        }
        latest?.let { PositionChip(it.position, it.choice) }
    }
}

@Composable
private fun RepEditRow(member: Member, hidden: Boolean, onToggle: () -> Unit) {
    val colors = Palette
    Row(
        Modifier.rowSurface(Palette).padding(horizontal = 10.dp, vertical = 8.dp).alpha(if (hidden) 0.75f else 1f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        MemberPortrait(member, Modifier.size(30.dp))
        NameBlock(member, "Pinned from your district", Modifier.weight(1f))
        val shape = RoundedCornerShape(50)
        Text(
            if (hidden) "Hidden" else "Shown",
            style = FloorType.text(11f, FontWeight.Bold),
            color = if (hidden) colors.textMuted else colors.ground,
            modifier = Modifier.clip(shape).background(if (hidden) Color.Transparent else colors.text, shape)
                .border(1.dp, if (hidden) colors.raised else colors.text, shape)
                .clickable(role = Role.Switch, onClick = onToggle)
                .semantics {
                    contentDescription = member.fullName
                    stateDescription = if (hidden) "Hidden" else "Shown"
                }
                .padding(horizontal = 8.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun FollowedEditRow(member: Member, index: Int, count: Int, actions: FollowingActions) {
    val colors = Palette
    Row(
        Modifier.rowSurface(Palette).padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        MemberPortrait(member, Modifier.size(30.dp))
        NameBlock(member, memberCaption(member), Modifier.weight(1f))
        if (index > 0) SmallAction("▲", "Move ${member.fullName} up", colors.textMuted) {
            actions.onUpdate { it.move(FollowKind.MEMBER, member.bioguideId, -1) }
        }
        if (index < count - 1) SmallAction("▼", "Move ${member.fullName} down", colors.textMuted) {
            actions.onUpdate { it.move(FollowKind.MEMBER, member.bioguideId, 1) }
        }
        SmallAction("Unfollow", "Unfollow ${member.fullName}", colors.nay) {
            actions.onUpdate { it.unfollow(FollowKind.MEMBER, member.bioguideId) }
        }
    }
}

@Composable
private fun SmallAction(text: String, spoken: String, color: Color, onClick: () -> Unit) {
    Text(
        text, style = FloorType.text(11f, FontWeight.Bold), color = color,
        modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = spoken }.padding(6.dp),
    )
}

@Composable
private fun NameBlock(member: Member, caption: String, modifier: Modifier) {
    val colors = Palette
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(member.lastName.uppercase(), style = FloorType.display(17f, FloorType.Face.BLACK_ITALIC), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(caption, style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted)
    }
}

// MARK: Bills

private fun LazyListScope.bills(state: FollowingState, actions: FollowingActions) {
    val bills = state.follows.followedBills
    if (bills.isEmpty()) {
        item {
            EmptyCard(
                "FOLLOW A BILL",
                "Search by number (hr 1013, S. 2) or by words. Each step it takes shows here, and its votes in Finals.",
                "FIND BILLS TO FOLLOW", filled = true, onClick = actions.onAdd,
            )
        }
        return
    }
    items(bills, key = { "bill-" + it.id }) { bill ->
        BillRow(bill, onOpen = { actions.onOpenBill(bill.id) }, trailing = {
            FollowPill(on = true, name = bill.citation) { actions.onUpdate { it.unfollow(FollowKind.BILL, bill.id) } }
        })
    }
    item { Text(BillRoad.legend, style = FloorType.text(10f, FontWeight.Medium), color = Palette.textMuted) }
}

// MARK: Topics

private fun LazyListScope.topics(state: FollowingState, actions: FollowingActions) {
    val followed = state.follows.followedTopics
    if (followed.isEmpty()) {
        item {
            EmptyCard(
                "FOLLOW A TOPIC",
                "A topic is one of the 32 policy areas the Congressional Research Service puts every bill in. Follow one to see its bills as they move, and its votes in Finals.",
                "SEARCH TOPICS", filled = false, onClick = actions.onAdd,
            )
        }
    } else {
        items(followed, key = { "topic-$it" }) { name ->
            val topic = state.topic(name)
            TopicRow(name, topic?.let(TopicText::detail), topic?.let(SpokenBill::topicRow) ?: name, onOpen = { actions.onOpenTopic(name) }, trailing = {
                FollowPill(on = true, name = name) { actions.onUpdate { it.unfollow(FollowKind.TOPIC, name) } }
            })
        }
    }
    when (val phase = state.topics) {
        BillsState.Phase.Loading -> item { Spinner("Loading the topics") }
        is BillsState.Phase.Failed -> item { Failed(phase.message, actions.onRetryTopics) }
        is BillsState.Phase.Loaded -> {
            val suggested = state.suggestedTopics
            if (suggested.isNotEmpty()) {
                item { GroupHeader("SUGGESTED", null, modifier = Modifier.padding(top = 8.dp)) }
                items(suggested, key = { "suggested-" + it.name }) { topic ->
                    TopicRow(
                        topic.name, "${app.floor.android.model.Formats.count(topic.bills)} ${if (topic.bills == 1) "bill" else "bills"}",
                        SpokenBill.topicRow(topic), onOpen = { actions.onOpenTopic(topic.name) },
                        trailing = { FollowPill(on = false, name = topic.name) { actions.onUpdate { it.follow(FollowKind.TOPIC, topic.name) } } },
                    )
                }
            }
        }
    }
}

// MARK: Pieces

@Composable
private fun GroupHeader(title: String, trailing: String?, modifier: Modifier = Modifier, action: (() -> Unit)? = null) {
    val colors = Palette
    Row(modifier.fillMaxWidth().padding(horizontal = 2.dp).padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.textMuted, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.weight(1f))
        if (trailing != null) {
            Text(
                trailing, style = FloorType.label(12f),
                color = if (action != null) colors.threshold else colors.textMuted,
                modifier = if (action != null) Modifier.clickable(role = Role.Button, onClick = action) else Modifier,
            )
        }
    }
}

@Composable
private fun EmptyCard(title: String, body: String, button: String, filled: Boolean, onClick: () -> Unit) {
    val colors = Palette
    Column(
        Modifier.dashedPanel(colors.panelBorder, colors.panel, 14.dp, dash = 5f, gap = 4f).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title, style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.textMuted)
        Text(body, style = FloorType.text(13f), color = colors.textSecondary)
        val shape = RoundedCornerShape(9.dp)
        Text(
            button,
            style = FloorType.label(14f).copy(letterSpacing = 0.6.sp),
            color = if (filled) colors.ground else colors.text,
            modifier = Modifier.padding(top = 4.dp).clip(shape)
                .background(if (filled) colors.threshold else Color.Transparent, shape)
                .then(if (filled) Modifier else Modifier.border(1.dp, colors.raised, shape))
                .clickable(role = Role.Button, onClick = onClick)
                .padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

/** The mock's `.mr` row: surface, hairline, 12dp corners. */
private fun Modifier.rowSurface(colors: app.floor.android.design.FloorColors): Modifier {
    val shape = RoundedCornerShape(12.dp)
    return fillMaxWidth().clip(shape).background(colors.panel, shape).border(1.dp, colors.panelBorder, shape)
}
