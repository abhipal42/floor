package app.floor.android.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.width
import app.floor.android.R
import app.floor.android.design.ChipSwitch
import app.floor.android.design.glass
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Member
import app.floor.android.model.seatCaption
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import androidx.compose.ui.semantics.clearAndSetSemantics
import app.floor.android.design.Appearance
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.arenaGround
import app.floor.android.design.SavedDataNote
import app.floor.android.design.panel

/** Room under every screen for the floating tab bar, so the last card scrolls clear of it. */
val TabBarClearance = 76.dp

/**
 * The Finals tab (iOS `HomeView`): the header, your three with a loyalty ring each (or, while a
 * seat changes hands, the members-elect list), the All / Following switch once you follow
 * anything, then the finals as stories (the locked v0.2.57 mock, option B): one card per bill or
 * nominee by week, newest first, and each week's procedural-only measures as "Also this week" rows.
 * Above the finals, the catch-up entry opens the deck ([CatchUpScreen]).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: HomeState,
    appearance: Appearance,
    onAppearance: (Appearance) -> Unit,
    onFilter: (HomeState.Filter) -> Unit,
    onRetry: () -> Unit,
    onRefresh: () -> Unit,
    onOpenVote: (String) -> Unit,
    /** The reader's zone and locale, passed rather than read inside (lesson 69): the weeks and step dates. */
    zone: ZoneId,
    locale: Locale,
    modifier: Modifier = Modifier,
    /** What "This week" is measured from. */
    now: Instant = Instant.now(),
    /** A story card's band or body: the bill's screen. */
    onOpenBill: (String) -> Unit = {},
    onScope: (HomeState.Scope) -> Unit = {},
    onOpenMember: (Member) -> Unit = {},
    onOpenElect: (String) -> Unit = {},
    /** The header chip: "Find my reps" with no district, else the district, which changes the address. */
    onFindReps: () -> Unit = {},
    /** The round search button: the same search as Following › + Add, any member, bill or topic. */
    onSearch: () -> Unit = {},
    /** Deck cards seen this session: the catch-up entry's segments. */
    seenInDeck: Set<String> = emptySet(),
    /** The catch-up entry: the deck, on its own screen. */
    onCatchUp: () -> Unit = {},
) {
    val colors = Palette
    PullToRefreshBox(
        isRefreshing = state.refreshing,
        onRefresh = onRefresh,
        modifier = modifier
            .fillMaxSize()
            .arenaGround(colors),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Header(state.delegation?.district?.name, appearance, onAppearance, onFindReps, onSearch)
            DelegationStrip(state, onOpenMember, onOpenElect)
            if (state.followsAnything) {
                ChipSwitch(
                    HomeState.Scope.entries, state.shownScope, { if (it == HomeState.Scope.ALL) "ALL" else "FOLLOWING" }, onScope, size = 13f,
                    spoken = { if (it == HomeState.Scope.ALL) "All finals" else "Finals on members, bills and topics you follow" },
                )
            }
            when (val phase = state.phase) {
                HomeState.Phase.Loading -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        color = colors.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(22.dp).semantics { contentDescription = "Loading recent votes" },
                    )
                }
                is HomeState.Phase.Failed -> Failure(phase.message, onRetry)
                HomeState.Phase.Loaded -> {
                    state.saved?.let { SavedDataNote(it) }
                    state.unavailableNote?.let { Text(it, style = FloorType.text(12f), color = colors.textMuted) }
                    if (state.shownScope == HomeState.Scope.YOURS) state.billLimitNote?.let { Text(it, style = FloorType.text(12f), color = colors.textMuted) }
                    val deck = state.deck
                    if (deck.isNotEmpty()) CatchUpEntry(deck, seenInDeck, onCatchUp)
                    FinalsHeader(state.filter, state.shownScope == HomeState.Scope.YOURS, onFilter)
                    val stories = state.stories
                    if (stories.isEmpty()) {
                        Text(state.emptyFeedMessage, style = FloorType.body(), color = colors.textMuted)
                    } else {
                        val chipMembers = state.chipMembers
                        Stories.sections(stories, now, zone, locale).forEach { section ->
                            if (section.full.isNotEmpty()) {
                                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                    StorySectionLabel(section.title)
                                    section.full.forEach { story ->
                                        StoryCard(
                                            story = story,
                                            members = Stories.members(story, chipMembers),
                                            zone = zone,
                                            locale = locale,
                                            onOpen = {
                                                // A nomination has no screen of its own yet, so its card opens the confirmation vote.
                                                val measure = story.measure
                                                if (measure?.kind == MeasureSummary.Kind.BILL) onOpenBill(measure.id)
                                                else onOpenVote((story.main ?: story.latest).vote.id)
                                            },
                                            onOpenVote = { onOpenVote(it.id) },
                                        )
                                    }
                                }
                            }
                            if (section.minis.isNotEmpty()) {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    StorySectionLabel(if (section.full.isEmpty()) section.title else section.alsoTitle)
                                    section.minis.forEach { StoryMini(it, zone, locale) { vote -> onOpenVote(vote.id) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        // The status bar gets a ground to sit on rather than letting cards scroll under the clock.
        Box(
            Modifier
                .fillMaxWidth()
                .windowInsetsTopHeight(WindowInsets.statusBars)
                .background(colors.groundGlow.copy(alpha = 0.94f)),
        )
    }
}

@Composable
private fun Header(
    district: String?,
    appearance: Appearance,
    onAppearance: (Appearance) -> Unit,
    onFindReps: () -> Unit,
    onSearch: () -> Unit,
) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "FLOOR",
            style = FloorType.headline(34f),
            color = colors.text,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.weight(1f))
        Text(
            district ?: "Find my reps",
            style = FloorType.text(12f, FontWeight.SemiBold),
            color = colors.textSecondary,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(colors.text.copy(alpha = 0.08f))
                .clickable(role = Role.Button, onClick = onFindReps)
                .semantics { contentDescription = district?.let { "District $it. Change your address" } ?: "Find your representative and senators" }
                .padding(horizontal = 10.dp, vertical = 6.dp),
        )
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(colors.text.copy(alpha = 0.08f))
                .clickable(role = Role.Button, onClick = onSearch)
                .semantics { contentDescription = "Search members, bills and topics" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(R.drawable.ic_search), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(8.dp))
        AppearanceMenu(appearance, onAppearance)
    }
}

private fun Appearance.icon(): Int = when (this) {
    Appearance.SYSTEM -> R.drawable.ic_appearance_system
    Appearance.LIGHT -> R.drawable.ic_appearance_light
    Appearance.DARK -> R.drawable.ic_appearance_dark
}

/** The round button at the top right: System, Light or Dark (iOS `AppearanceMenu`). */
@Composable
private fun AppearanceMenu(appearance: Appearance, onAppearance: (Appearance) -> Unit) {
    val colors = Palette
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(colors.text.copy(alpha = 0.08f))
                .clickable(role = Role.Button) { open = true }
                .semantics {
                    contentDescription = "Appearance"
                    stateDescription = appearance.label
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(appearance.icon()), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = colors.panel) {
            Appearance.entries.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            option.label,
                            style = FloorType.text(15f, if (option == appearance) FontWeight.SemiBold else FontWeight.Normal),
                            color = colors.text,
                        )
                    },
                    leadingIcon = { Icon(painterResource(option.icon()), contentDescription = null, tint = colors.textSecondary) },
                    onClick = {
                        open = false
                        onAppearance(option)
                    },
                    modifier = Modifier.semantics { selected = option == appearance },
                )
            }
        }
    }
}

@Composable
private fun FinalsHeader(filter: HomeState.Filter, yours: Boolean, onFilter: (HomeState.Filter) -> Unit) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(if (yours) "YOUR FINALS" else "FINALS", style = FloorType.headline(26f), color = colors.text, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.weight(1f))
        Row(
            Modifier
                .clip(RoundedCornerShape(9.dp))
                .background(colors.panel)
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            HomeState.Filter.entries.forEach { option ->
                val on = option == filter
                Text(
                    option.label,
                    style = FloorType.text(12f, FontWeight.SemiBold, scales = false),
                    color = if (on) colors.ground else colors.textSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(7.dp))
                        .background(if (on) colors.text else colors.panel)
                        .clickable(role = Role.Tab) { onFilter(option) }
                        .semantics { selected = on }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun Failure(message: String, onRetry: () -> Unit) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, style = FloorType.body(), color = colors.textSecondary)
        Text(
            "Try again",
            style = FloorType.text(15f, FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clickable(role = Role.Button, onClick = onRetry),
        )
    }
}

/** Your reps with a loyalty ring each; while a seat of yours changes hands, the members-elect list. */
@Composable
private fun DelegationStrip(state: HomeState, onOpenMember: (Member) -> Unit, onOpenElect: (String) -> Unit) {
    val rows = state.seatRows
    if (app.floor.android.model.SeatRow.changing(rows)) {
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            rows.forEach { row ->
                when (row) {
                    is app.floor.android.model.SeatRow.Sitting -> app.floor.android.design.SeatMemberRow(row.member, row.leavingOn, onOpen = { onOpenMember(row.member) })
                    is app.floor.android.model.SeatRow.Elect -> app.floor.android.design.ElectRow(row.elect) { onOpenElect(row.elect.id) }
                    is app.floor.android.model.SeatRow.Pending -> app.floor.android.design.PendingSeatCard(row.seat)
                }
            }
        }
        return
    }
    if (state.strip.isEmpty()) return
    val large = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.5f
    val card: @Composable (Member, Modifier) -> Unit = { member, modifier -> DelegationCard(member, state.loyalty[member.bioguideId]?.withPartyShare, modifier) { onOpenMember(member) } }
    if (large) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) { state.strip.forEach { card(it, Modifier.fillMaxWidth()) } }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { state.strip.forEach { card(it, Modifier.weight(1f)) } }
    }
}

@Composable
private fun DelegationCard(member: Member, share: Double?, modifier: Modifier, onOpen: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier
            .glass(colors, shape)
            .clickable(role = Role.Button, onClickLabel = "Open their record", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = app.floor.android.model.SpokenMember.delegationCard(member, share) }
            .padding(vertical = 10.dp, horizontal = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        app.floor.android.design.Ring(share, colors.yea, 3.dp, Modifier.size(50.dp)) {
            app.floor.android.design.MemberPortrait(member, Modifier.size(40.dp))
        }
        Text(member.lastName.uppercase(), style = FloorType.label(16f), color = colors.text, maxLines = 1)
        Text(member.seatCaption, style = FloorType.text(10f), color = colors.textMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
