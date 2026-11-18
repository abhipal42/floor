package app.floor.android.member

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.design.BlockHeader
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SectionSwitch
import app.floor.android.design.cssGradient
import app.floor.android.design.glass
import app.floor.android.design.panel
import app.floor.android.home.Stories
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Funding
import app.floor.android.model.Member
import app.floor.android.model.MemberFunding
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberVote
import app.floor.android.model.MoneyFormat
import app.floor.android.model.Position
import app.floor.android.model.Promise
import app.floor.android.model.Promises
import app.floor.android.model.RecordFacts
import app.floor.android.model.RecordStats
import app.floor.android.model.TopicGroup
import app.floor.android.model.VoteKind
import app.floor.android.model.fullName
import app.floor.android.model.outcomeWord
import app.floor.android.vote.TopBar
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/** Follow on a member's hero: whether you follow them, whether they are your own rep, and the toggle. */
data class MemberFollow(val following: Boolean, val isRep: Boolean, val onToggle: () -> Unit)

/**
 * One member (iOS `RepScreenView`, the locked "one scroll", option B, drawn in Arena): the party
 * hero with the record's three figures and the last 40 calls, the sticky jump chips, then Votes,
 * Said, Posts, Money and Contact in one scroll. Each section but Contact opens its full content on
 * its own screen ([MemberState.page]): today's Votes (rings, the grid, the readout), Said's swipe
 * deck, the full posts list, and Money's Funding and Disclosures. Money is organizations only,
 * never an individual donor. [now] says which posts are today's, in the reader's [zone].
 */
@Composable
fun MemberScreen(
    state: MemberState,
    back: String,
    zone: ZoneId,
    locale: Locale,
    onBack: () -> Unit,
    onOpen: (MemberSection?) -> Unit,
    onMoneySegment: (MoneySegment) -> Unit,
    onSelectCall: (Int) -> Unit,
    onRetry: () -> Unit,
    onRetryMoney: () -> Unit,
    onRetryDisclosures: () -> Unit,
    onOpenVote: (String) -> Unit,
    follow: MemberFollow? = null,
    onPromise: (Int) -> Unit = {},
    onOpenTopic: (String) -> Unit = {},
    onRetryPromises: () -> Unit = {},
    onRetryPosts: () -> Unit = {},
    now: Instant = Instant.now(),
) {
    val page = state.page
    val record = state.record
    if (page != null) {
        BackHandler { onOpen(null) }
        Page(state, page, zone, locale, now, { onOpen(null) }, onMoneySegment, onSelectCall, onRetry, onRetryMoney, onRetryDisclosures, onOpenVote, onPromise, onOpenTopic, onRetryPromises, onRetryPosts)
        return
    }
    if (record !is Load.Loaded) {
        val colors = Palette
        Column(Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
            TopBar(back = back, onBack = onBack)
            when (record) {
                is Load.Failed -> Column(
                    Modifier.fillMaxWidth().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(record.message, style = FloorType.body(), color = colors.textSecondary)
                    TryAgain(onRetry)
                }
                else -> Spinner("Loading this member")
            }
        }
        return
    }
    OneScroll(state, record, back, zone, locale, now, onBack, onOpen, onRetryMoney, onOpenVote, follow, onPromise, onRetryPromises, onRetryPosts)
}

/** Which sections have something to show: a chip and a block each. Contact always does. */
internal fun visibleSections(state: MemberState): List<MemberSection> {
    val record = state.record.loaded
    val calls = record?.votes.orEmpty()
    val accounts = record?.detail?.accounts.orEmpty()
    return MemberSection.entries.filter { section ->
        when (section) {
            MemberSection.RECORD -> calls.isNotEmpty()
            MemberSection.SAID -> state.promises.loaded?.state != Promises.Status.UNCHECKED
            MemberSection.POSTS -> accounts.isNotEmpty() || state.posts.loaded?.shown?.isNotEmpty() != false
            MemberSection.MONEY, MemberSection.CONTACT -> true
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OneScroll(
    state: MemberState,
    record: Load.Loaded<MemberRecord>,
    back: String,
    zone: ZoneId,
    locale: Locale,
    now: Instant,
    onBack: () -> Unit,
    onOpen: (MemberSection?) -> Unit,
    onRetryMoney: () -> Unit,
    onOpenVote: (String) -> Unit,
    follow: MemberFollow?,
    onPromise: (Int) -> Unit,
    onRetryPromises: () -> Unit,
    onRetryPosts: () -> Unit,
) {
    val colors = Palette
    val detail = record.value.detail
    val member = detail.member
    val votes = record.value.votes
    val stats = remember(votes) { RecordStats(votes) }
    val sections = visibleSections(state)
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    // The chips stick under the status bar once the hero has scrolled away.
    val stuck by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    val active by remember(sections) {
        derivedStateOf {
            val items = list.layoutInfo.visibleItemsInfo
            val header = items.firstOrNull { it.key == "jump" }?.let { it.offset + it.size } ?: 0
            items.firstOrNull { item -> item.key is String && (item.key as String).startsWith("section-") && item.offset + item.size > header + 1 }
                ?.let { item -> sections.firstOrNull { "section-${it.name}" == item.key } }
                ?: sections.firstOrNull()
        }
    }
    val eyebrow = heroEyebrow(member, follow?.isRep == true, follow?.following == true)
    val figures = HeroFigures.of(detail.partyLoyalty.withPartyShare, stats)
    LazyColumn(
        Modifier.fillMaxSize().background(colors.ground),
        state = list,
        contentPadding = PaddingValues(bottom = 32.dp + TabBarClearance),
    ) {
        item(key = "hero") {
            MemberHero(
                member, eyebrow, heroSubtitle(member), heroSpoken(member, eyebrow, figures), back, onBack,
                trailing = follow?.takeIf { !it.isRep }?.let { f -> { HeroFollow(member, f.following, f.onToggle) } },
            ) {
                HeroStats(figures)
                HeroStreak(stats, zone, locale, onOpenVote)
            }
        }
        stickyHeader(key = "jump") {
            JumpChips(sections, active, stuck) { section ->
                val index = 2 + sections.indexOf(section)
                val header = list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == "jump" }?.size ?: with(density) { 52.dp.roundToPx() }
                scope.launch { list.animateScrollToItem(index, -header) }
            }
        }
        record.saved?.let { saved -> item(key = "saved") { Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)) { SavedDataNote(saved) } } }
        sections.forEach { section ->
            item(key = "section-${section.name}") {
                Column(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    when (section) {
                        MemberSection.RECORD -> VotesBlock(member, votes, stats, zone, locale, { onOpen(MemberSection.RECORD) }, onOpenVote)
                        MemberSection.SAID -> SaidBlock(state.promises, member, locale, onRetryPromises) { index ->
                            index?.let(onPromise)
                            onOpen(MemberSection.SAID)
                        }
                        MemberSection.POSTS -> PostsBlock(state.posts, member, detail.accounts, now, zone, locale, onRetryPosts) { onOpen(MemberSection.POSTS) }
                        MemberSection.MONEY -> MoneyBlock(state.money, member, onRetryMoney) { onOpen(MemberSection.MONEY) }
                        MemberSection.CONTACT -> Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            BlockHeader("Contact")
                            ContactRows(member, detail.contact)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Votes

/** `Confirmed 51–46 · Nov 16`: the result in a word, the score, the day. */
internal fun voteLine(call: MemberVote, zone: ZoneId, locale: Locale): String {
    val vote = call.vote
    val word = vote.outcomeWord?.lowercase()?.replaceFirstChar { it.uppercase() }
    val score = if (vote.kind == VoteKind.QUESTION) "${vote.totals.yea}–${vote.totals.nay}" else null
    val result = listOfNotNull(word, score).joinToString(" ").ifEmpty { null }
    return listOfNotNull(result, vote.occurredAtInstant?.let { Stories.format(it, zone, locale) }).joinToString(" · ")
}

/** A vote row's title: the bill or nominee, else the question's own words. */
internal fun voteTitle(call: MemberVote): String =
    call.measure?.title ?: call.vote.question.removePrefix("On the ").removePrefix("On ")

@Composable
private fun VotesBlock(
    member: Member,
    votes: List<MemberVote>,
    stats: RecordStats,
    zone: ZoneId,
    locale: Locale,
    onAll: () -> Unit,
    onOpenVote: (String) -> Unit,
) {
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        BlockHeader("Votes", "All ${stats.calls.size} ›", "All ${stats.calls.size} votes", onAll)
        votes.take(3).forEach { VoteRow(member, it, zone, locale) { onOpenVote(it.vote.id) } }
        RecordFacts.didYouKnow(member, votes, zone)?.let { text -> DidYouKnow(text) }
    }
}

/** The mock's `.vr`: the topic's colour, the title, the result line, and how the member voted. */
@Composable
private fun VoteRow(member: Member, call: MemberVote, zone: ZoneId, locale: Locale, onOpen: () -> Unit) {
    val colors = Palette
    val title = voteTitle(call)
    val line = voteLine(call, zone, locale)
    val sided = call.sidedWithOutcome
    val position = when (call.position) {
        Position.CANDIDATE -> (call.choice ?: "Ballot").uppercase()
        Position.NOT_VOTING -> "DNV"
        else -> call.position.name
    }
    val tone = when (call.position) {
        Position.YEA -> colors.yea
        Position.NAY -> colors.nay
        else -> colors.textMuted
    }
    val spoken = "$title. $line. ${member.lastName} " + when (call.position) {
        Position.NOT_VOTING -> "did not vote."
        Position.CANDIDATE -> "voted for ${call.choice ?: "a candidate"}."
        else -> "voted ${call.position.name.lowercase()}" + when (sided) {
            true -> ", on the winning side."
            false -> ", on the losing side."
            null -> "."
        }
    }
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .glass(colors, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClickLabel = "Open the vote", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = spoken }
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(Modifier.width(5.dp).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(colors.topic(TopicGroup.of(call.measure))))
        Column(Modifier.weight(1f)) {
            Text(title, style = FloorType.text(13.5f, FontWeight.Bold), color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(line, style = FloorType.text(11.5f), color = colors.textMuted)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(position, style = FloorType.display(19f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 1.em), color = tone, maxLines = 1)
            sided?.let { Text(if (it) "won" else "lost", style = FloorType.text(10.5f), color = colors.textMuted) }
        }
    }
}

@Composable
private fun DidYouKnow(text: String) {
    val colors = Palette
    val label: @Composable () -> Unit = {
        Text("DID YOU KNOW", style = FloorType.display(15f, FloorType.Face.BLACK_ITALIC), color = colors.threshold, maxLines = 1)
    }
    if (largeText()) {
        Column(Modifier.panel(colors).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            label()
            Text(text, style = FloorType.text(13f), color = colors.textSecondary)
        }
    } else {
        Row(Modifier.panel(colors).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            label()
            Text(text, style = FloorType.text(13f), color = colors.textSecondary, modifier = Modifier.weight(1f))
        }
    }
}

// MARK: - Said

/** The one line a campaign with no promises to show gets on the one scroll; null when it has some. */
internal fun saidLine(said: Promises, member: Member): String? {
    val year = said.electionYear?.toString()
    return when (said.state) {
        Promises.Status.PROMISES -> null
        Promises.Status.NO_PLATFORM -> "${member.lastName}'s ${year?.let { "$it " } ?: ""}campaign site listed no issues."
        Promises.Status.NO_SITE -> "The FEC lists no website for the campaign that won ${member.fullName} this seat${year?.let { " in $it" } ?: ""}."
        Promises.Status.NO_SNAPSHOT -> "The Internet Archive has no copy of ${said.siteHost ?: "the campaign site"} from before election day${year?.let { " $it" } ?: ""}."
        Promises.Status.UNCHECKED -> "Floor hasn't read ${member.fullName}'s campaign site yet."
    }
}

@Composable
private fun SaidBlock(load: Load<Promises>, member: Member, locale: Locale, onRetry: () -> Unit, onOpen: (Int?) -> Unit) {
    val colors = Palette
    val said = load.loaded
    val count = said?.promises?.size ?: 0
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
            said?.state == Promises.Status.PROMISES ->
                BlockHeader("Said", "$count ${if (count == 1) "promise" else "promises"} ›", "All $count promises", { onOpen(null) })
            said?.state == Promises.Status.NO_PLATFORM -> BlockHeader("Said", "The page ›", "Open the archived page", { onOpen(null) })
            else -> BlockHeader("Said")
        }
        when (load) {
            Load.Loading -> Spinner("Loading what the campaign said", top = 8)
            is Load.Failed -> FailedLine(load.message, onRetry)
            is Load.Loaded -> saidLine(load.value, member)?.let { Text(it, style = FloorType.text(12.5f), color = colors.textSecondary) }
        }
    }
    if (said?.state == Promises.Status.PROMISES) {
        val rail = rememberLazyListState()
        LazyRow(
            state = rail,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 2.dp, bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            flingBehavior = rememberSnapFlingBehavior(rail, SnapPosition.Start),
        ) {
            itemsIndexed(said.promises) { index, promise -> PromiseCard(promise, said.electionYear) { onOpen(index) } }
        }
        val archived = said.archivedDay(locale)
        Text(
            "$PROMISES_AI_NOTE From ${said.siteHost ?: "the campaign site"}${archived?.let { ", as the Internet Archive kept it on $it" } ?: ""}.",
            style = FloorType.text(10.5f, FontWeight.Medium),
            color = colors.textMuted,
            modifier = Modifier.padding(horizontal = 18.dp),
        )
    }
}

/** The mock's `.pc`: the topic and the year's site, the headline, the exact quote, and the AI chip. */
@Composable
private fun PromiseCard(promise: Promise, year: Int?, onOpen: () -> Unit) {
    val colors = Palette
    val topic = promise.floorTopic ?: promise.heading?.trim()?.takeIf { it.isNotEmpty() } ?: "Promise"
    val where = year?.let { "$it site" } ?: "Campaign site"
    Column(
        Modifier
            .width(236.dp)
            .glass(colors, RoundedCornerShape(16.dp), fill = cssGradient(160.0, listOf(colors.promiseTop, colors.promiseBottom), listOf(0f, 1f)))
            .clickable(role = Role.Button, onClickLabel = "Open the promises", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = "$topic, $where. “${promise.quote}” Picked by AI." }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Text("$topic · $where".uppercase(), style = FloorType.text(9.5f, FontWeight.ExtraBold).copy(letterSpacing = 1.2.sp), color = colors.textSecondary, maxLines = 2) // textMuted is 4.38:1 on light promiseTop; iOS matches
        Text(promise.headline.uppercase(), style = FloorType.display(19f).copy(lineHeight = 1.05.em), color = colors.text)
        Text(promise.quote, style = FloorType.text(12.5f).copy(lineHeight = 1.42.em), color = colors.textSecondary)
        Text(
            "AI PICKED",
            style = FloorType.text(9f, FontWeight.ExtraBold).copy(letterSpacing = 1.sp),
            color = colors.aiInk,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(colors.ai).padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

// MARK: - Posts

@Composable
private fun PostsBlock(
    load: Load<MemberPosts>,
    member: Member,
    accounts: List<app.floor.android.model.MemberSocial.Account>,
    now: Instant,
    zone: ZoneId,
    locale: Locale,
    onRetry: () -> Unit,
    onAll: () -> Unit,
) {
    val posts = load.loaded?.shown.orEmpty()
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        BlockHeader("Posts", if (posts.isNotEmpty()) "All ›" else null, "All of ${member.lastName}'s posts", onAll)
        if (accounts.isNotEmpty()) AccountMarks(accounts)
        when (load) {
            Load.Loading -> Spinner("Loading the posts", top = 8)
            is Load.Failed -> FailedLine(load.message, onRetry)
            is Load.Loaded -> {
                if (posts.isEmpty()) NoPosts(member, accounts)
                posts.take(2).forEach { PostCard(it, member, accounts, now, zone, locale, clip = true) }
            }
        }
    }
}

// MARK: - Money

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MoneyBlock(load: Load<MemberFunding>, member: Member, onRetry: () -> Unit, onDetails: () -> Unit) {
    val colors = Palette
    val funding = load.loaded?.funding
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        BlockHeader("Money", if (load is Load.Loaded) "Details ›" else null, "Funding and disclosures", onDetails)
        when (load) {
            Load.Loading -> Spinner("Loading ${member.lastName}'s FEC figures", top = 8)
            is Load.Failed -> FailedLine(load.message, onRetry)
            is Load.Loaded -> if (funding == null) {
                Text(load.value.noFilings.second, style = FloorType.text(12.5f), color = colors.textSecondary)
            } else {
                val cash = funding.cashOnHand
                val tiles: @Composable (Modifier, Modifier) -> Unit = { a, b ->
                    MoneyTile("Raised · ${funding.cycle}", MoneyFormat.total(funding.receipts), "Raised ${MoneyFormat.spoken(funding.receipts)}", a)
                    MoneyTile(
                        "Cash on hand", cash?.let(MoneyFormat::total) ?: "—",
                        cash?.let { "Cash on hand ${MoneyFormat.spoken(it)}" } ?: "No cash-on-hand figure", b,
                    )
                }
                if (largeText()) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { tiles(Modifier.fillMaxWidth(), Modifier.fillMaxWidth()) }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { tiles(Modifier.weight(1f), Modifier.weight(1f)) }
                }
                Text(funding.period, style = FloorType.text(11f), color = colors.textMuted)
                val parts = Funding.Part.entries.zip(app.floor.android.design.Tones.moneyBar.map { it.color(colors.isDark) })
                val base = funding.shareBase
                Row(
                    Modifier.fillMaxWidth().height(12.dp).clip(RoundedCornerShape(6.dp)).clearAndSetSemantics { },
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    parts.forEach { (part, color) ->
                        val share = if (base > 0) (funding.shown(part) / base).toFloat() else 0f
                        if (share > 0f) Box(Modifier.weight(share).fillMaxHeight().background(color))
                    }
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    parts.forEach { (part, color) ->
                        Row(
                            Modifier.clearAndSetSemantics { contentDescription = "${part.label}: ${funding.percent(part)}" },
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            Box(Modifier.size(8.dp).clip(RoundedCornerShape(2.dp)).background(color))
                            Text("${part.label} · ${funding.percent(part)}", style = FloorType.text(11.5f), color = colors.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MoneyTile(label: String, value: String, spoken: String, modifier: Modifier) {
    val colors = Palette
    Column(
        modifier.glass(colors, RoundedCornerShape(16.dp)).clearAndSetSemantics { contentDescription = spoken }.padding(12.dp),
    ) {
        Text(label.uppercase(), style = FloorType.text(9.5f, FontWeight.ExtraBold).copy(letterSpacing = 1.1.sp), color = colors.textMuted, maxLines = 1)
        Text(
            value,
            style = FloorType.display(30f, FloorType.Face.BLACK_ITALIC).copy(fontFeatureSettings = "tnum"),
            color = colors.text, maxLines = 1, modifier = Modifier.padding(top = 4.dp),
        )
    }
}

/** A section that couldn't load: the API's sentence and Try again, on one line's worth of room. */
@Composable
private fun FailedLine(message: String, onRetry: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(message, style = FloorType.text(12.5f), color = Palette.textSecondary, modifier = Modifier.weight(1f))
        TryAgain(onRetry)
    }
}

// MARK: - A section on its own screen

@Composable
private fun Page(
    state: MemberState,
    page: MemberSection,
    zone: ZoneId,
    locale: Locale,
    now: Instant,
    onClose: () -> Unit,
    onMoneySegment: (MoneySegment) -> Unit,
    onSelectCall: (Int) -> Unit,
    onRetry: () -> Unit,
    onRetryMoney: () -> Unit,
    onRetryDisclosures: () -> Unit,
    onOpenVote: (String) -> Unit,
    onPromise: (Int) -> Unit,
    onOpenTopic: (String) -> Unit,
    onRetryPromises: () -> Unit,
    onRetryPosts: () -> Unit,
) {
    val colors = Palette
    val member = state.member
    val title = when (page) {
        MemberSection.RECORD -> "Votes"
        MemberSection.SAID -> "Said"
        MemberSection.POSTS -> "Posts"
        MemberSection.MONEY -> "Money"
        MemberSection.CONTACT -> "Contact"
    }
    Column(Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = member?.lastName ?: "Member", onBack = onClose)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Column(Modifier.semantics(mergeDescendants = true) {}) {
                member?.let { Text(it.fullName.uppercase(), style = FloorType.label(13f).copy(letterSpacing = 1.2.sp), color = colors.textMuted) }
                BlockHeader(title)
            }
            when (page) {
                MemberSection.RECORD -> RecordPage(state, zone, onSelectCall, onRetry, onOpenVote)
                MemberSection.SAID -> SaidContent(state.promises, member, state.promise, locale, onPromise, onOpenTopic, onRetryPromises)
                MemberSection.POSTS -> PostsContent(state.posts, member, state.record.loaded?.detail?.accounts.orEmpty(), now, zone, locale, onRetryPosts)
                MemberSection.MONEY -> {
                    SectionSwitch(MoneySegment.entries, state.moneySegment, { it.title }, onMoneySegment)
                    if (state.moneySegment == MoneySegment.FUNDING) MoneyContent(state.money, member, onRetryMoney)
                    else DisclosuresContent(state.disclosures, member, onRetryDisclosures)
                }
                MemberSection.CONTACT -> state.record.loaded?.let { ContactRows(it.detail.member, it.detail.contact) }
            }
        }
    }
}

/** "All 40 ›": the three rings, the last-40 grid with its readout, and the computed "did you know". */
@Composable
private fun RecordPage(state: MemberState, zone: ZoneId, onSelectCall: (Int) -> Unit, onRetry: () -> Unit, onOpenVote: (String) -> Unit) {
    val colors = Palette
    when (val record = state.record) {
        Load.Loading -> Spinner("Loading this member")
        is Load.Failed -> Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(record.message, style = FloorType.text(13f), color = colors.textSecondary)
            TryAgain(onRetry)
        }
        is Load.Loaded -> {
            val detail = record.value.detail
            val votes = record.value.votes
            val stats = RecordStats(votes)
            record.saved?.let { SavedDataNote(it) }
            Rings(detail.partyLoyalty, stats, detail.member)
            Grid(stats, state.selectedCall, zone, onSelectCall, onOpenVote)
            RecordFacts.didYouKnow(detail.member, votes, zone)?.let { DidYouKnow(it) }
        }
    }
}
