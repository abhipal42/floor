package app.floor.android.member

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import app.floor.android.bill.open
import app.floor.android.design.FloorType
import app.floor.android.design.MemberPortrait
import app.floor.android.design.OpenArrow
import app.floor.android.design.Palette
import app.floor.android.design.RemoteImage
import app.floor.android.design.glass
import app.floor.android.design.heroEdge
import app.floor.android.design.mark
import app.floor.android.model.Member
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberSocial
import app.floor.android.model.Post
import app.floor.android.model.PostParts
import app.floor.android.model.SocialNetwork
import app.floor.android.model.fullName
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

// Posts, rebuilt (Arena, v0.2.58; the mock's `.post`): who said it first (portrait, the network's
// badge, name, party, handle and time), then the text as posted, then its video, photo or link
// card, then "Thread" when it opens one. Tapping the card opens the post on its network.

/** The lines under a member's posts, on the full list. */
const val POSTS_NOTE = "Posts as written, newest first, from the networks' public feeds. No counts, no ranking."

/**
 * A member's full posts list ("All ›" on the member page): the account marks, every post in full,
 * and the note. [now] says which posts are today's (their time alone), in the reader's [zone].
 */
@Composable
internal fun PostsContent(
    load: Load<MemberPosts>,
    member: Member?,
    accounts: List<MemberSocial.Account>,
    now: Instant,
    zone: ZoneId,
    locale: Locale,
    onRetry: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (accounts.isNotEmpty()) AccountMarks(accounts)
        when (load) {
            Load.Loading -> Spinner("Loading the posts", top = 40)
            is Load.Failed -> Column(Modifier.glass(Palette, RoundedCornerShape(16.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(load.message, style = FloorType.text(13f), color = Palette.textSecondary)
                TryAgain(onRetry)
            }
            is Load.Loaded -> {
                load.saved?.let { app.floor.android.design.SavedDataNote(it) }
                val posts = load.value.shown
                if (posts.isEmpty()) NoPosts(member, accounts)
                posts.forEach { PostCard(it, member, accounts, now, zone, locale) }
                Text(POSTS_NOTE, style = FloorType.text(10.5f, FontWeight.Medium), color = Palette.textMuted, modifier = Modifier.padding(horizontal = 2.dp))
            }
        }
    }
}

/** The one line a member with no posts to show gets. */
@Composable
internal fun NoPosts(member: Member?, accounts: List<MemberSocial.Account>) {
    val name = member?.fullName ?: "This member"
    if (accounts.any { it.network.readable }) {
        DashedNote("Nothing posted lately", "$name hasn't posted on YouTube, Bluesky or Mastodon in the last 30 days.")
    } else {
        DashedNote("No posts Floor can show", "Floor shows posts from YouTube, Bluesky and Mastodon, and $name has no account there that Floor can read.")
    }
}

/** The networks Floor reads first, then the links-only ones (round 13 polish). */
private val MARK_ORDER = listOf(
    SocialNetwork.BLUESKY, SocialNetwork.YOUTUBE, SocialNetwork.MASTODON,
    SocialNetwork.X, SocialNetwork.INSTAGRAM, SocialNetwork.FACEBOOK,
)

/**
 * The top of Posts: a circle per account the member has, its network's mark; a green dot on the
 * ones whose posts Floor shows. A tap opens the network's app, or its site. Too many to fit
 * scrolls sideways.
 */
@Composable
internal fun AccountMarks(accounts: List<MemberSocial.Account>) {
    val colors = Palette
    val context = LocalContext.current
    val sorted = accounts.sortedBy { MARK_ORDER.indexOf(it.network) }
    val gap = 6.dp
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val slot = (maxWidth - gap * (sorted.size - 1)) / sorted.size
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(gap)) {
            sorted.forEach { account ->
                val network = account.network
                val spoken = if (network.readable) "${network.title}, ${account.handle}, posts shown in Floor"
                    else "${network.title}, ${account.handle}, opens ${network.title}"
                Column(
                    Modifier.widthIn(min = slot).clip(RoundedCornerShape(10.dp))
                        .clickable(role = Role.Button) { open(context, account.url) }
                        .clearAndSetSemantics { contentDescription = spoken }
                        .padding(vertical = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(Modifier.size(46.dp)) {
                        Box(
                            Modifier.fillMaxSize().clip(CircleShape).background(colors.card).border(1.dp, colors.panelBorder, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(network.mark, contentDescription = null, tint = colors.text, modifier = Modifier.size(18.dp))
                        }
                        if (network.readable) {
                            Box(
                                Modifier.align(Alignment.TopEnd).offset(x = 2.dp, y = (-2).dp).size(12.dp)
                                    .clip(CircleShape).background(colors.ground).padding(2.dp).clip(CircleShape).background(colors.yea),
                            )
                        }
                    }
                }
            }
        }
    }
}

/** The tallest a post's photo or thumbnail draws, so a big image never fills the screen. */
private val POST_MEDIA_MAX = 220.dp

/**
 * One post (the mock's `.post`). [member] draws the portrait, name and party chip; [accounts] give
 * the handle when the page has them. [clip] cuts the text at five lines with "More" (the member
 * page); the full list and Following › Posts show it all.
 */
@Composable
fun PostCard(
    post: Post,
    member: Member?,
    accounts: List<MemberSocial.Account>,
    now: Instant,
    zone: ZoneId,
    locale: Locale,
    modifier: Modifier = Modifier,
    clip: Boolean = false,
) {
    val colors = Palette
    val context = LocalContext.current
    val shape = RoundedCornerShape(20.dp)
    val network = post.socialNetwork
    val link = PostParts.link(post)
    val thread = PostParts.thread(post)
    val openLabel = PostParts.openLabel(post)
    val byline = listOfNotNull(PostParts.handle(post, accounts), PostParts.time(post, now, zone, locale)).joinToString(" · ")
    val text = (link?.textWithout ?: post.text)?.trim()?.takeIf { it.isNotEmpty() }
    Column(
        modifier
            .fillMaxWidth()
            .glass(colors, shape, fill = Brush.verticalGradient(listOf(colors.postTop, colors.postBottom)), edge = colors.heroEdge())
            .clickable(role = Role.Button, onClickLabel = openLabel) { open(context, post.url) }
            .semantics(mergeDescendants = true) {},
    ) {
        Row(
            Modifier.padding(start = 14.dp, end = 14.dp, top = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Avatar(member, network)
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(
                        member?.fullName ?: network?.title ?: "Post",
                        style = FloorType.text(14.5f, FontWeight.Bold), color = colors.text,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                    )
                    member?.let { m ->
                        Text(
                            "${m.party}-${m.state}",
                            style = FloorType.text(10f, FontWeight.ExtraBold), color = colors.partyInk(m.party),
                            maxLines = 1,
                            modifier = Modifier.clip(RoundedCornerShape(4.dp)).background(colors.partyTint(m.party)).padding(horizontal = 5.dp, vertical = 1.dp),
                        )
                    }
                }
                if (byline.isNotEmpty()) {
                    Text(byline, style = FloorType.text(12f), color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Box(
                Modifier.size(30.dp).clip(CircleShape).background(colors.chip)
                    .clickable(role = Role.Button) { open(context, post.url) }
                    .semantics { contentDescription = openLabel },
                contentAlignment = Alignment.Center,
            ) {
                Icon(OpenArrow, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(13.dp))
            }
        }
        if (text != null) PostText(text, clip)
        else Box(Modifier.height(12.dp))
        val media = post.mediaUrl
        when {
            link != null && media != null -> LinkCard(media, link.domain, link.path)
            network == SocialNetwork.YOUTUBE -> Media(media, video = true)
            media != null -> Media(media, video = false)
        }
        if (thread != null) {
            Text(thread, style = FloorType.text(11.5f, FontWeight.Bold), color = colors.textMuted, modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 12.dp))
        }
    }
}

/** The 40dp portrait with the network's logo badged at its bottom right, in the network's colour. */
@Composable
private fun Avatar(member: Member?, network: SocialNetwork?) {
    val colors = Palette
    Box(Modifier.size(40.dp)) {
        if (member != null) {
            MemberPortrait(member, Modifier.size(40.dp))
        } else {
            Box(Modifier.size(40.dp).clip(CircleShape).background(colors.chip))
        }
        if (network != null) {
            // An 18dp badge with a 2dp ring in the card's colour (the mock's `box-shadow: 0 0 0 2px`).
            Box(
                Modifier.align(Alignment.BottomEnd).offset(x = 5.dp, y = 5.dp).size(22.dp).clip(CircleShape).background(colors.postTop),
                contentAlignment = Alignment.Center,
            ) {
                Icon(network.mark, contentDescription = null, tint = colors.network(network), modifier = Modifier.size(12.dp))
            }
        }
    }
}

/** 15sp at 1.45 line height; [clip] cuts at five lines and offers "More" (the card opens the rest). */
@Composable
private fun PostText(text: String, clip: Boolean) {
    val colors = Palette
    var cut by remember(text) { mutableStateOf(false) }
    Column(Modifier.padding(start = 14.dp, end = 14.dp, top = 9.dp, bottom = 12.dp)) {
        Text(
            text,
            style = FloorType.text(15f).copy(lineHeight = 1.45.em),
            color = colors.text,
            maxLines = if (clip) 5 else Int.MAX_VALUE,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { cut = it.hasVisualOverflow },
        )
        if (clip && cut) Text("More", style = FloorType.text(15f, FontWeight.SemiBold), color = colors.accent)
    }
}

/** A photo, or a YouTube video's thumbnail with a centred play button: full width, 16:9, at most 220dp. */
@Composable
private fun Media(url: String?, video: Boolean) {
    val colors = Palette
    BoxWithConstraints(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, bottom = 14.dp)) {
        val frame = Modifier.fillMaxWidth().height(minOf(maxWidth * 9f / 16f, POST_MEDIA_MAX)).clip(RoundedCornerShape(14.dp)).background(colors.chip)
        Box(frame, contentAlignment = Alignment.Center) {
            if (url != null) RemoteImage(url, Modifier.fillMaxSize()) {}
            if (video) PlayButton()
        }
    }
}

/** The mock's `.play i`: a 54dp dark disc with a white ring and a white triangle. */
@Composable
private fun PlayButton() {
    val colors = Palette
    val ink = colors.playInk
    Box(
        Modifier.size(54.dp).clip(CircleShape).background(colors.playScrim).border(1.5.dp, colors.playRing, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(width = 16.dp, height = 20.dp).offset(x = 2.dp)) {
            val path = Path().apply {
                moveTo(0f, 0f)
                lineTo(size.width, size.height / 2)
                lineTo(0f, size.height)
                close()
            }
            drawPath(path, ink)
        }
    }
}

/** A link the post names: its image at 96dp on the left, then the domain and the URL as posted. */
@Composable
private fun LinkCard(image: String, domain: String, path: String) {
    val colors = Palette
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp).fillMaxWidth().height(IntrinsicSize.Min).heightIn(min = 84.dp)
            .clip(shape).border(1.dp, colors.cardBorder, shape),
    ) {
        RemoteImage(image, Modifier.width(96.dp).fillMaxHeight().background(colors.chip)) {}
        Column(Modifier.weight(1f).padding(horizontal = 12.dp, vertical = 10.dp).align(Alignment.CenterVertically), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(domain, style = FloorType.text(11f, FontWeight.SemiBold), color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(path, style = FloorType.text(13f, FontWeight.Bold).copy(lineHeight = 1.3.em), color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

