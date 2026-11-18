package app.floor.android.local

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.FloorType
import app.floor.android.design.HeadlineRow
import app.floor.android.design.NeedNote
import app.floor.android.design.Palette
import app.floor.android.design.RemoteImage
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SectTitle
import app.floor.android.design.SkewChip
import app.floor.android.design.arenaGround
import app.floor.android.design.dashedPanel
import app.floor.android.design.glass
import app.floor.android.design.heroEdge
import app.floor.android.design.largeText
import app.floor.android.home.TabBarClearance
import app.floor.android.member.Load
import app.floor.android.member.Spinner
import app.floor.android.member.TryAgain
import app.floor.android.model.Jurisdiction
import app.floor.android.model.LocalHub
import app.floor.android.model.LocalHubs
import app.floor.android.model.LocalItem
import app.floor.android.model.News
import app.floor.android.model.StateLegislator
import java.time.ZoneId
import java.util.Locale

/**
 * The Local tab (v0.2.60, the locked option A): LOCAL with "Cities ›", a switch of the user's hubs
 * (their state, then saved cities), and the hub. A state: SIGNED INTO LAW, WAITING ON THE
 * GOVERNOR, IN THE NEWS, YOUR STATE LEGISLATORS. A city: PASSED (with the tally where the record
 * has one) and IN THE NEWS. Empty sections are left out. No state known: a card to look one up.
 */
@Composable
fun LocalScreen(
    state: LocalState,
    zone: ZoneId,
    locale: Locale,
    onOpenCities: () -> Unit,
    onSelect: (String) -> Unit,
    onFindReps: () -> Unit,
    onRetry: () -> Unit,
) {
    val colors = Palette
    Column(
        Modifier
            .fillMaxSize()
            .arenaGround(colors)
            .verticalScroll(rememberScrollState())
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text("LOCAL", style = FloorType.headline(36f), color = colors.text, modifier = Modifier.weight(1f).semantics { heading() })
            Text(
                "Cities ›",
                style = FloorType.text(13f, FontWeight.SemiBold),
                color = colors.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(role = Role.Button, onClick = onOpenCities)
                    .semantics { contentDescription = "Choose cities" }
                    .padding(horizontal = 4.dp, vertical = 6.dp),
            )
        }
        when (val registry = state.registry) {
            Load.Loading -> Spinner("Loading the places Floor covers")
            is Load.Failed -> Failed(registry.message, onRetry)
            is Load.Loaded -> {
                registry.saved?.let { Box(Modifier.padding(top = 8.dp)) { SavedDataNote(it) } }
                if (state.district == null) {
                    NeedAddress(onFindReps)
                }
                val hubs = state.hubList
                val current = state.current
                if (hubs.isNotEmpty() && current != null) {
                    HubSwitch(hubs, current, onSelect)
                    when (val hub = state.hubs[current.id] ?: Load.Loading) {
                        Load.Loading -> Spinner("Loading ${current.name}")
                        is Load.Failed -> Failed(hub.message, onRetry)
                        is Load.Loaded -> {
                            hub.saved?.let { Box(Modifier.padding(top = 10.dp)) { SavedDataNote(it) } }
                            Hub(hub.value, current, state, zone, locale, onFindReps)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Failed(message: String, onRetry: () -> Unit) {
    Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(message, style = FloorType.text(13f), color = Palette.textSecondary)
        TryAgain(onRetry)
    }
}

/** No state known: one card asking for the address (the existing flow). */
@Composable
private fun NeedAddress(onFindReps: () -> Unit) {
    val colors = Palette
    Column(
        Modifier.padding(top = 12.dp).dashedPanel(colors.raised, Color.Transparent, 14.dp).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "Look up your address to see your state's new laws, what waits on the governor, and your state legislators.",
            style = FloorType.text(12.5f).copy(lineHeight = 1.45.em),
            color = colors.textSecondary,
        )
        AddressButton("Find my reps", onFindReps)
    }
}

@Composable
private fun AddressButton(title: String, onClick: () -> Unit) {
    val colors = Palette
    val pill = RoundedCornerShape(10.dp)
    Text(
        title,
        style = FloorType.text(13f, FontWeight.Bold),
        color = colors.ground,
        modifier = Modifier.clip(pill).background(colors.text, pill).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

/** The mock's `.scope`: one pill per hub, the chosen one white; more than three scroll. */
@Composable
private fun HubSwitch(hubs: List<Jurisdiction>, current: Jurisdiction, onSelect: (String) -> Unit) {
    val scroll = hubs.size > 3 || largeText()
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 10.dp, bottom = 2.dp)
            .then(if (scroll) Modifier.horizontalScroll(rememberScrollState()) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        hubs.forEach { hub ->
            val on = hub.id == current.id
            HubPill(hub.name, on, if (scroll) Modifier.widthIn(min = 96.dp) else Modifier.weight(1f)) { onSelect(hub.id) }
        }
    }
}

@Composable
private fun HubPill(name: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Text(
        name,
        style = FloorType.text(12.5f, FontWeight.Bold),
        color = if (on) colors.ground else colors.textSecondary,
        textAlign = TextAlign.Center,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .clip(shape)
            .background(if (on) colors.text else colors.chip, shape)
            .border(1.dp, if (on) colors.text else colors.cardBorder, shape)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { selected = on }
            .padding(horizontal = 10.dp, vertical = 9.dp),
    )
}

@Composable
private fun Hub(hub: LocalHub, jurisdiction: Jurisdiction, state: LocalState, zone: ZoneId, locale: Locale, onFindReps: () -> Unit) {
    val city = jurisdiction.kindValue == Jurisdiction.Kind.CITY
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        LocalHubs.coverageNote(jurisdiction)?.let { CoverageCard(it) }
        val legislators = if (city) null else legislatorsBlock(state)
        if (hub.isEmpty && legislators == null) {
            NeedNote(LocalHubs.nothing(jurisdiction), Modifier.padding(top = 12.dp))
        }
        if (hub.enacted.isNotEmpty()) {
            SectTitle(if (city) "Passed" else "Signed into law")
            hub.enacted.forEach { if (city) PassedCard(it, locale) else EnactedCard(it, locale) }
        }
        if (!city && hub.waiting.isNotEmpty()) {
            SectTitle("Waiting on the governor")
            hub.waiting.forEach { WaitingRow(it) }
        }
        if (hub.news.isNotEmpty()) {
            SectTitle("In the news")
            Column { hub.news.forEach { HeadlineRow(it, zone, locale, showTone = false) } }
        }
        legislators?.invoke(onFindReps)
    }
}

/**
 * YOUR STATE LEGISLATORS for the state hub, or null when the section has nothing to say: the
 * endpoint answered none (no key on the server).
 */
private fun legislatorsBlock(state: LocalState): (@Composable (() -> Unit) -> Unit)? {
    val district = state.district ?: return null
    if (!state.hasStateDistricts) {
        return { onFindReps ->
            SectTitle("Your state legislators")
            val colors = Palette
            Column(
                Modifier.dashedPanel(colors.raised, Color.Transparent, 14.dp).padding(horizontal = 14.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(LocalHubs.lookUpAgain(district.state), style = FloorType.text(12.5f).copy(lineHeight = 1.45.em), color = colors.textSecondary)
                AddressButton("Look up my address", onFindReps)
            }
        }
    }
    val load = state.legislators ?: return null
    if (load is Load.Loaded && load.value.isEmpty()) return null
    return { _ ->
        SectTitle("Your state legislators")
        when (load) {
            Load.Loading -> Spinner("Loading your state legislators", top = 8)
            is Load.Failed -> Text(load.message, style = FloorType.text(12.5f), color = Palette.textSecondary)
            is Load.Loaded -> Column { LocalHubs.ordered(load.value).forEach { LegislatorRow(district.state, it) } }
        }
    }
}

@Composable
private fun CoverageCard(text: String) {
    val colors = Palette
    Text(
        text,
        style = FloorType.text(12.5f).copy(lineHeight = 1.45.em),
        color = colors.textMuted,
        modifier = Modifier.padding(top = 10.dp).fillMaxWidth().glass(colors, RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 12.dp),
    )
}

/** A hero card for a state law: the cite chip and the date, the title in display type, two lines of summary. */
@Composable
private fun EnactedCard(item: LocalItem, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val day = News.day(item.date, locale)
    val url = item.url
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(22.dp), edge = colors.heroEdge())
            .then(if (url != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the bill") { open(context, url) } else Modifier)
            .clearAndSetSemantics {
                contentDescription = listOfNotNull(item.identifier, item.title, statusWord(item), day, item.summary).joinToString(". ")
            }
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SkewChip(item.identifier.ifBlank { item.body }, size = 13f)
            Spacer(Modifier.weight(1f))
            day?.let { Label(it) }
        }
        Text(
            item.title.uppercase(),
            style = FloorType.display(23f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 1.em),
            color = colors.text,
            modifier = Modifier.padding(top = 10.dp),
        )
        item.summary?.let {
            Text(it, style = FloorType.text(12.5f).copy(lineHeight = 1.45.em), color = colors.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        }
    }
}

/**
 * A council matter that passed: the hero card, and the Finals-style score (YES n · PASSED · NO n)
 * when the record has the tally; otherwise the title with its date.
 */
@Composable
private fun PassedCard(item: LocalItem, locale: Locale) {
    val colors = Palette
    val context = LocalContext.current
    val day = News.day(item.date, locale)
    val tally = item.tally
    val url = item.url
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(22.dp), edge = colors.heroEdge())
            .then(if (url != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the record") { open(context, url) } else Modifier)
            .clearAndSetSemantics {
                contentDescription = listOfNotNull(
                    item.identifier, item.title, tally?.let { "Passed, ${it.first} yes, ${it.second} no" } ?: "Passed", day, item.summary,
                ).joinToString(". ")
            }
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SkewChip(item.identifier.ifBlank { item.body }, size = 13f)
            Spacer(Modifier.weight(1f))
            Label(listOfNotNull(item.body.takeIf { it.isNotBlank() }, day).joinToString(" · "))
        }
        Text(
            item.title.uppercase(),
            style = FloorType.display(25f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 1.em),
            color = colors.text,
            modifier = Modifier.padding(top = 10.dp),
        )
        item.summary?.let {
            Text(it, style = FloorType.text(12.5f).copy(lineHeight = 1.45.em), color = colors.textSecondary, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 7.dp))
        }
        if (tally != null) {
            Row(Modifier.fillMaxWidth().padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("YES", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.yea)
                    Text("${tally.first}", style = FloorType.display(52f, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum"), color = colors.yea, maxLines = 1)
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SkewChip("PASSED", background = colors.yea, size = 13f)
                    Text("FINAL", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.textMuted)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.End) {
                    Text("NO", style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = colors.nay)
                    Text("${tally.second}", style = FloorType.display(52f, FloorType.Face.BLACK_ITALIC, scales = false).copy(fontFeatureSettings = "tnum"), color = colors.nay, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun Label(text: String) {
    Text(text.uppercase(), style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp), color = Palette.textMuted, maxLines = 1)
}

private fun statusWord(item: LocalItem): String? = when (item.statusValue) {
    LocalItem.Status.SIGNED -> "Signed into law"
    LocalItem.Status.BECAME_LAW -> "Became law"
    LocalItem.Status.PASSED -> "Passed"
    LocalItem.Status.AWAITING_GOVERNOR -> "Waiting on the governor"
    null -> null
}

/** A glass row: the title, and one line of the summary (or the body). */
@Composable
private fun WaitingRow(item: LocalItem) {
    val colors = Palette
    val context = LocalContext.current
    val url = item.url
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(16.dp))
            .then(if (url != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open the bill") { open(context, url) } else Modifier)
            .clearAndSetSemantics { contentDescription = listOfNotNull(item.title, item.identifier, "Waiting on the governor", item.summary ?: item.body).joinToString(". ") }
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(item.title, style = FloorType.text(14.5f, FontWeight.Bold), color = colors.text)
        Text(item.summary ?: item.body, style = FloorType.text(13f), color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** One state legislator: portrait or initials, the name, the party letter in its colour, the seat. */
@Composable
private fun LegislatorRow(state: String, legislator: StateLegislator) {
    val colors = Palette
    val context = LocalContext.current
    val line = LocalHubs.legislatorLine(state, legislator)
    val url = legislator.url
    Column {
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (url != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open their page") { open(context, url) } else Modifier)
                .clearAndSetSemantics { contentDescription = "${legislator.name}, ${legislator.party.ifBlank { legislator.partyLetter }}, $line" }
                .padding(vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            val initials: @Composable () -> Unit = {
                Text(legislator.initials, style = FloorType.text(11f, FontWeight.Bold, scales = false), color = colors.text)
            }
            val avatar = Modifier.size(34.dp).clip(CircleShape).background(colors.partyTint(legislator.partyLetter))
            val photo = legislator.photoUrl
            if (photo != null) RemoteImage(photo, avatar, initials) else Box(avatar, contentAlignment = Alignment.Center) { initials() }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(legislator.name, style = FloorType.text(14f, FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f, fill = false))
                    Text(legislator.partyLetter, style = FloorType.label(14f), color = colors.party(legislator.partyLetter))
                }
                Text(line, style = FloorType.text(12f), color = colors.textMuted)
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.cardBorder))
    }
}
