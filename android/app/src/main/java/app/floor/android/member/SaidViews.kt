package app.floor.android.member

import android.provider.Settings
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
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
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.bill.open
import app.floor.android.design.FloorColors
import app.floor.android.design.FloorType
import app.floor.android.design.LocalPlaysArrivalAnimations
import app.floor.android.design.Palette
import app.floor.android.design.RemoteImage
import app.floor.android.design.SavedDataNote
import app.floor.android.design.dashedPanel
import app.floor.android.design.panel
import app.floor.android.model.Member
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberSocial
import app.floor.android.model.Post
import app.floor.android.model.Promise
import app.floor.android.model.Promises
import app.floor.android.model.SocialNetwork
import app.floor.android.model.fullName
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Round 13 (the locked mock `floor-said.html`, iOS `SaidView`): Said, the swipe deck of what the
// campaign site promised, quoted exactly; Posts, newest first from the free networks; and Contact's
// official accounts. AI only picks the lines, so every deck carries the AI tag and the archive link.

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
            if (count > 2) Behind(colors, colors.card, 14f, 0.92f, 0.5f)
            if (count > 1) Behind(colors, colors.cardSunken, 7f, 0.96f, 0.8f)
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
private fun androidx.compose.foundation.layout.BoxScope.Behind(colors: FloorColors, fill: Color, drop: Float, scale: Float, opacity: Float) {
    val shape = RoundedCornerShape(18.dp)
    Box(
        Modifier.matchParentSize()
            .graphicsLayer {
                transformOrigin = TransformOrigin(0.5f, 1f)
                translationY = drop.dp.toPx()
                scaleX = scale
                scaleY = scale
                alpha = opacity
            }
            .clip(shape).background(fill, shape).border(1.dp, colors.panelBorder, shape),
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

// MARK: - Posts

@Composable
internal fun PostsContent(load: Load<MemberPosts>, member: Member?, accounts: List<MemberSocial.Account>, zone: ZoneId, locale: Locale, onRetry: () -> Unit) {
    Loading(load, "Loading the posts", onRetry) { value ->
        val name = member?.fullName ?: "This member"
        val posts = value.shown
        // The links-only networks: from the response, else from the member's accounts.
        val linksOnly = value.links.accounts.ifEmpty { accounts.filter { !it.network.readable } }
        if (posts.isEmpty()) {
            if (accounts.any { it.network.readable }) {
                DashedNote("Nothing posted lately", "$name hasn't posted on YouTube, Bluesky or Mastodon in the last 30 days.")
            } else {
                DashedNote("No posts Floor can show", "Floor shows posts from YouTube, Bluesky and Mastodon, and $name has no account there that Floor can read.")
            }
        }
        posts.forEach { PostCard(it, zone, locale) }
        if (linksOnly.isNotEmpty()) LinksOnly(linksOnly)
        Text(
            "Posts as written, newest first, from the networks' public feeds. No counts, no ranking.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = Palette.textMuted, modifier = Modifier.padding(horizontal = 2.dp),
        )
    }
}

/** X, Facebook and Instagram: links, since none lets an app read posts for free. */
@Composable
private fun LinksOnly(accounts: List<MemberSocial.Account>) {
    val colors = Palette
    val context = LocalContext.current
    val names = accounts.map { it.network.title }
    Column(
        Modifier.dashedPanel(colors.raised, Color.Transparent, 12.dp).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            "Also on ${names.dropLast(1).joinToString(", ").let { if (it.isEmpty()) names.last() else "$it and ${names.last()}" }}".uppercase(),
            style = FloorType.label(12f).copy(letterSpacing = 1.2.sp), color = colors.textMuted,
        )
        Text(
            "${if (names.size == 1) "It doesn't" else "They don't"} let apps read posts for free, so ${if (names.size == 1) "it's a link" else "they're links"}.",
            style = FloorType.text(11f, FontWeight.Medium), color = colors.textSecondary,
        )
        accounts.forEach { account ->
            Text(
                "${account.handle} on ${account.network.title} ›", style = FloorType.text(12f, FontWeight.SemiBold), color = colors.yea,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(role = Role.Button) { open(context, account.url) }.padding(vertical = 3.dp),
            )
        }
    }
}

/**
 * One post (the mock's `.post`): the network chip and its time in the reader's zone, the text as
 * posted, a YouTube video's thumbnail, and a link to the original. [byline] names the member on the
 * Following wall, where [compact] cuts long text and leaves out the link line (the card opens it).
 */
@Composable
fun PostCard(post: Post, zone: ZoneId, locale: Locale, byline: String? = null, compact: Boolean = false) {
    val colors = Palette
    val context = LocalContext.current
    val shape = RoundedCornerShape(12.dp)
    val network = post.socialNetwork
    val time = post.whenLabel(zone, locale)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(colors.panel, shape).border(1.dp, colors.panelBorder, shape)
            .clickable(role = Role.Button, onClickLabel = post.openLabel.removeSuffix(" ›")) { open(context, post.url) }
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                listOfNotNull(network?.title, byline).joinToString(" · ").uppercase(),
                style = FloorType.label(10f).copy(letterSpacing = 1.sp), color = colors.text, maxLines = 1,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).background(colors.chip).padding(horizontal = 5.dp, vertical = 3.dp),
            )
            Spacer(Modifier.weight(1f))
            if (time != null) Text(time, style = FloorType.text(10.5f, FontWeight.Bold), color = colors.textMuted)
        }
        if (network == SocialNetwork.YOUTUBE && !compact) {
            val placeholder: @Composable () -> Unit = {
                Text("▶ VIDEO", style = FloorType.label(11f).copy(letterSpacing = 1.1.sp), color = colors.textMuted)
            }
            val thumb = Modifier.fillMaxWidth().height(80.dp).clip(RoundedCornerShape(8.dp))
                .background(Brush.linearGradient(listOf(colors.card, colors.raised)))
            post.mediaUrl?.let { RemoteImage(it, thumb, placeholder) } ?: Box(thumb, contentAlignment = Alignment.Center) { placeholder() }
        }
        post.text?.trim()?.takeIf { it.isNotEmpty() }?.let {
            Text(
                it, style = FloorType.text(12.5f).copy(lineHeight = 17.sp), color = colors.text,
                maxLines = if (compact) 3 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis,
            )
        }
        if (!compact) Text(post.openLabel, style = FloorType.text(10.5f, FontWeight.SemiBold), color = colors.yea)
    }
}

// MARK: - Contact's official accounts

private val SocialNetwork.glyph: String
    get() = when (this) {
        SocialNetwork.X -> "X"
        SocialNetwork.FACEBOOK -> "f"
        SocialNetwork.INSTAGRAM -> "IG"
        SocialNetwork.YOUTUBE -> "▶"
        SocialNetwork.BLUESKY -> "BSKY"
        SocialNetwork.MASTODON -> "M"
    }

private val SocialNetwork.caption: String
    get() = when (this) {
        SocialNetwork.X, SocialNetwork.FACEBOOK, SocialNetwork.INSTAGRAM -> "link only"
        SocialNetwork.BLUESKY -> "verified"
        SocialNetwork.YOUTUBE, SocialNetwork.MASTODON -> "posts in Floor"
    }

/** The grid of a member's official accounts; a tap opens the network's app, or its site. */
@Composable
internal fun OfficialAccounts(member: Member, accounts: List<MemberSocial.Account>) {
    val colors = Palette
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "OFFICIAL ACCOUNTS", style = FloorType.label(11.5f).copy(letterSpacing = 1.1.sp), color = colors.textMuted,
            modifier = Modifier.padding(start = 2.dp, top = 4.dp).semantics { heading() },
        )
        if (accounts.isEmpty()) {
            DashedNote("No accounts listed", "congress-legislators lists no official social accounts for ${member.fullName} yet.")
            return@Column
        }
        accounts.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                row.forEach { account ->
                    val shape = RoundedCornerShape(10.dp)
                    Column(
                        Modifier.weight(1f).clip(shape).background(colors.panel, shape).border(1.dp, colors.panelBorder, shape)
                            .clickable(role = Role.Button) { open(context, account.url) }
                            .clearAndSetSemantics { contentDescription = "${account.network.title}, ${account.handle}, ${account.network.caption}" }
                            .padding(horizontal = 4.dp, vertical = 8.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(account.network.glyph, style = FloorType.label(13f), color = colors.threshold)
                        Text(account.handle, style = FloorType.text(10.5f, FontWeight.SemiBold), color = colors.text, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(account.network.caption, style = FloorType.mono(9.5f), color = colors.textMuted, textAlign = TextAlign.Center)
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        Text(
            "From congress-legislators; Bluesky only when Bluesky verifies it.",
            style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp),
        )
    }
}
