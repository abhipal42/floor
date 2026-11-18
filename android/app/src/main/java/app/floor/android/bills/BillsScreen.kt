package app.floor.android.bills

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import app.floor.android.design.SkewChip
import app.floor.android.design.heroEdge
import app.floor.android.design.outcome
import app.floor.android.home.HomeState
import app.floor.android.home.Stories
import app.floor.android.model.outcome
import app.floor.android.model.outcomeWord
import java.time.ZoneId
import java.util.Locale
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import app.floor.android.R
import app.floor.android.design.BillRow
import app.floor.android.design.glass
import app.floor.android.design.FloorType
import app.floor.android.design.Notice
import app.floor.android.design.Palette
import app.floor.android.design.arenaGround
import app.floor.android.design.SavedDataNote
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance

/**
 * The Bills tab (v0.2.59, "Your picks" of the locked mock; iOS `BillsView`): what your members voted
 * on and where it stands, as a ledger of progress cards in topic sections ([Ledger]), filtered All ·
 * Passed · Blocked. Above it, Android keeps its search over members, bills and topics (see
 * [BillsModel]); while something is typed the results take the ledger's place, drawn as iOS's
 * "+ Add" sheet draws them. The 32 topics are reached from that search and from Following › Topics.
 */
@Composable
fun BillsScreen(
    state: BillsState,
    ledger: LedgerState,
    onQuery: (String) -> Unit,
    onSubmit: () -> Unit,
    onRetry: () -> Unit,
    onOpenBill: (String) -> Unit,
    onOpenTopic: (String) -> Unit,
    /** The reader's zone and locale, passed rather than read inside (lesson 69): the cards' dates. */
    zone: ZoneId,
    locale: Locale,
    modifier: Modifier = Modifier,
    onLedgerFilter: (LedgerFilter) -> Unit = {},
    onChamber: (app.floor.android.model.Chamber?) -> Unit = {},
    onOpenMember: (app.floor.android.model.Member) -> Unit = {},
    onOpenElect: (String) -> Unit = {},
    follow: FollowActions? = null,
) {
    val colors = Palette
    val search = state.search
    val searching = SearchState.normalized(search.query) != null
    LazyColumn(
        modifier
            .fillMaxSize()
            .arenaGround(colors)
            .windowInsetsPadding(WindowInsets.statusBars),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance,
        ),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("BILLS", style = FloorType.headline(36f), color = colors.text, modifier = Modifier.semantics { heading() })
                Text("What your members voted on, and where it stands.", style = FloorType.text(13f), color = colors.textMuted)
            }
        }
        item { SearchField(search, onQuery, onSubmit) }
        if (searching || search.searched != null) {
            item { ChamberSwitch(search.chamber, onChamber) }
            searchResults(search, follow, onOpenBill, onOpenTopic, onOpenMember, onOpenElect)
        } else {
            item { LedgerSwitch(ledger.filter, onLedgerFilter) }
            ledger.saved?.let { item { SavedDataNote(it) } }
            when (val phase = ledger.phase) {
                HomeState.Phase.Loading -> item { Spinner("Loading the bills") }
                is HomeState.Phase.Failed -> item { Failed(phase.message, onRetry) }
                HomeState.Phase.Loaded -> {
                    val sections = Ledger.sections(ledger.items, ledger.filter)
                    if (sections.isEmpty()) {
                        item { Text(ledger.emptyMessage, style = FloorType.body(), color = colors.textMuted, modifier = Modifier.padding(top = 6.dp)) }
                    }
                    sections.forEach { section ->
                        item(key = "section-${section.topic}") {
                            Text(
                                section.topic.title.uppercase(),
                                style = FloorType.display(19f),
                                color = colors.topicText(section.topic),
                                modifier = Modifier.padding(top = 14.dp, bottom = 2.dp).semantics { heading() },
                            )
                        }
                        items(section.cards, key = { "bill-" + it.measure.id }) { card ->
                            LedgerCardView(card, zone, locale) { onOpenBill(card.measure.id) }
                        }
                    }
                }
            }
        }
    }
}

/** All · Passed · Blocked (the mock's `.seg`), no counts. */
@Composable
private fun LedgerSwitch(filter: LedgerFilter, onFilter: (LedgerFilter) -> Unit) {
    val colors = Palette
    Row(
        Modifier.fillMaxWidth().padding(top = 4.dp).clip(RoundedCornerShape(11.dp)).background(colors.chip).padding(3.dp),
    ) {
        LedgerFilter.entries.forEach { option ->
            val on = option == filter
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) colors.raised else Color.Transparent)
                    .clickable(role = Role.Tab) { onFilter(option) }
                    .semantics { selected = on }
                    .padding(vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(option.label, style = FloorType.text(12f, FontWeight.Bold), color = if (on) colors.text else colors.textMuted, maxLines = 1)
            }
        }
    }
}

/**
 * One bill (Bills A's card): the topic's 4dp left edge, the cite chip and `DEFENSE · NOV 12`, the
 * title and CRS's lead, the progress track, and a footer with the latest vote's kind, the party
 * split, the score and the stamp; the bill's rules fold into a muted line under it.
 */
@Composable
private fun LedgerCardView(card: LedgerCard, zone: ZoneId, locale: Locale, onOpen: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(22.dp)
    val vote = card.latest.vote
    val track = Ledger.track(card)
    val day = vote.occurredAtInstant?.let { Stories.format(it, zone, locale) }
    val party = Ledger.partyLine(card.latest)
    val rules = Ledger.ruleLine(card.rules, zone, locale)
    val spoken = listOfNotNull(
        card.measure.citation, card.title, Ledger.spokenTrack(card),
        listOfNotNull(Ledger.voteKind(vote), vote.outcomeWord?.lowercase(), Stories.spokenScore(vote), day).joinToString(", "),
        party, rules?.removePrefix("+ "),
    ).joinToString(". ")
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .glass(colors, shape, edge = colors.heroEdge())
            .clickable(role = Role.Button, onClickLabel = "Open the bill", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = spoken },
    ) {
        Box(Modifier.padding(vertical = 14.dp).width(4.dp).fillMaxHeight().clip(RoundedCornerShape(topEnd = 3.dp, bottomEnd = 3.dp)).background(colors.topic(card.topic)))
        Column(Modifier.weight(1f).padding(start = 11.dp, end = 15.dp, top = 15.dp, bottom = 14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SkewChip(card.measure.citation, size = 13f)
                Spacer(Modifier.weight(1f).width(8.dp))
                Text(
                    listOfNotNull(card.topic.title, day).joinToString(" · ").uppercase(),
                    style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp),
                    color = colors.textMuted,
                    maxLines = 1,
                )
            }
            Text(card.title, style = FloorType.text(16.5f, FontWeight.Bold).copy(lineHeight = 20.sp), color = colors.text, modifier = Modifier.padding(top = 8.dp))
            if (card.ruleFor == null) {
                card.measure.summaryLead?.let {
                    Text(it, style = FloorType.text(13f).copy(lineHeight = 19.sp), color = colors.textSecondary, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 5.dp))
                }
            }
            track?.let { Track(it) }
            Box(Modifier.padding(top = 12.dp).fillMaxWidth().height(1.dp).background(colors.cardBorder))
            Row(Modifier.padding(top = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(Ledger.voteKind(vote), style = FloorType.text(12f, FontWeight.SemiBold), color = colors.textSecondary)
                    party?.let { Text(it, style = FloorType.text(11.5f), color = colors.textMuted, modifier = Modifier.padding(top = 2.dp)) }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "${vote.totals.yea}–${vote.totals.nay}",
                        style = FloorType.display(24f, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum"),
                        color = colors.outcome(vote.outcome),
                    )
                    vote.outcomeWord?.let { SkewChip(it, background = colors.outcome(vote.outcome), size = 13f) }
                }
            }
            rules?.let { Text(it, style = FloorType.text(11.5f), color = colors.textMuted, modifier = Modifier.padding(top = 8.dp)) }
        }
    }
}

/** Dots joined by lines, green when done, a ring on the furthest, the nay colour where it stopped; a label under each. */
@Composable
private fun Track(steps: List<TrackStep>) {
    val colors = Palette
    fun fill(state: TrackStep.State) = when (state) {
        TrackStep.State.DONE, TrackStep.State.CURRENT -> colors.yea
        TrackStep.State.STOPPED -> colors.nay
        TrackStep.State.AHEAD -> colors.raised
    }
    Column(Modifier.padding(top = 13.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            steps.forEachIndexed { i, step ->
                if (i > 0) {
                    val reached = step.state == TrackStep.State.DONE || step.state == TrackStep.State.CURRENT
                    Box(Modifier.weight(1f).height(2.dp).background(if (reached) colors.yea else colors.raised))
                }
                Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
                    if (step.state == TrackStep.State.CURRENT) Box(Modifier.size(18.dp).clip(CircleShape).background(colors.yea.copy(alpha = 0.25f)))
                    Box(Modifier.size(10.dp).clip(CircleShape).background(fill(step.state)))
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 2.dp)) {
            steps.forEachIndexed { i, step ->
                Text(
                    step.label,
                    style = FloorType.text(10.5f, FontWeight.SemiBold),
                    color = when (step.state) {
                        TrackStep.State.STOPPED -> colors.nay
                        TrackStep.State.AHEAD -> colors.textMuted
                        else -> colors.textSecondary
                    },
                    maxLines = 1,
                    textAlign = when (i) {
                        0 -> TextAlign.Start
                        steps.lastIndex -> TextAlign.End
                        else -> TextAlign.Center
                    },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
internal fun SearchField(search: SearchState, onQuery: (String) -> Unit, onSubmit: () -> Unit) {
    val colors = Palette
    val focus = LocalFocusManager.current
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .glass(colors, shape)
            .padding(horizontal = 11.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(painterResource(R.drawable.ic_search), contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f)) {
            val style = FloorType.text(15f, FontWeight.Medium)
            if (search.query.isEmpty()) {
                Text("Members, bills, topics, or a bill number", style = style, color = colors.textMuted, maxLines = 1)
            }
            BasicTextField(
                value = search.query,
                onValueChange = onQuery,
                singleLine = true,
                textStyle = style.copy(color = colors.text),
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search,
                ),
                keyboardActions = KeyboardActions(onSearch = {
                    focus.clearFocus()
                    onSubmit()
                }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search members, bills and topics" },
            )
        }
        if (search.loading) {
            CircularProgressIndicator(color = colors.accent, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        }
        if (search.query.isNotEmpty()) {
            Icon(
                painterResource(R.drawable.ic_clear),
                contentDescription = "Clear search",
                tint = colors.textMuted,
                modifier = Modifier
                    .size(20.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(role = Role.Button) { onQuery("") },
            )
        }
    }
}

@Composable
internal fun Spinner(description: String) {
    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = Palette.accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp).semantics { contentDescription = description },
        )
    }
}

/** A failed load in a panel, with Try again (iOS's topic page and Bills tab). */
@Composable
internal fun Failed(message: String, onRetry: () -> Unit) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, style = FloorType.body(), color = colors.textSecondary)
        Text(
            "Try again",
            style = FloorType.text(15f, FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onRetry).padding(vertical = 4.dp),
        )
    }
}
