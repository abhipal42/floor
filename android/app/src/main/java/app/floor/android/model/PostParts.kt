package app.floor.android.model

import java.net.URI
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// The rebuilt post card's parts (Arena, v0.2.58; iOS `PostParts`): what the card reads off a post
// as posted. Nothing here fetches anything: a link card is built from the post's own text and image.

/** A link a post's text names: `billboard.com`, and `billboard.com/pro/congress…`. */
data class PostLink(val domain: String, val path: String, val textWithout: String)

object PostParts {
    /**
     * A URL in running text: with a scheme, starting `www.`, or a bare domain followed by a path
     * (so "U.S." or "e.g." never count). Bluesky prints long links cut short with `...`.
     */
    private val url = Regex(
        """(?:https?://[^\s]+|www\.[^\s]+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/[^\s]*)""",
        RegexOption.IGNORE_CASE,
    )

    /** `(1/2)` at the very end: the first post of a numbered thread. */
    private val numbered = Regex("""\(1/(\d+)\)\s*$""")

    /** `1/` at the very end: a thread whose length isn't said. */
    private val opener = Regex("""(?:^|\s)1/\s*$""")

    /**
     * The link card, when the text names a URL and the post has an image (the image is the link's
     * preview). The URL comes out of the text the card prints, since the card shows it.
     */
    fun link(post: Post): PostLink? {
        if (post.mediaUrl == null || post.socialNetwork == SocialNetwork.YOUTUBE) return null
        val text = post.text ?: return null
        val match = url.findAll(text).lastOrNull() ?: return null
        val cut = match.value.endsWith("...") || match.value.endsWith("…")
        val raw = match.value.trimEnd('.', ',', ')', '"', '”', '…').let { if (cut) "$it…" else it }
        val bare = raw.replace(Regex("^https?://", RegexOption.IGNORE_CASE), "").removePrefix("www.").removePrefix("WWW.")
        val domain = bare.substringBefore('/').lowercase()
        if (!domain.contains('.')) return null
        val rest = (text.substring(0, match.range.first) + text.substring(match.range.last + 1)).trim()
        return PostLink(domain, bare, rest)
    }

    /** `Thread · 2 posts` under a post ending `(1/2)`; `Thread` under one ending `1/`. Nothing else. */
    fun thread(post: Post): String? {
        val text = post.text?.trimEnd() ?: return null
        numbered.find(text)?.let { m -> m.groupValues[1].toIntOrNull()?.takeIf { it >= 2 }?.let { return "Thread · $it posts" } }
        return if (opener.containsMatchIn(text)) "Thread" else null
    }

    /**
     * The account under the name: the member's own handle on the post's network when the page
     * has it, else what the post's own link names (Bluesky's `profile/<handle>`, Mastodon's `@user`).
     */
    fun handle(post: Post, accounts: List<MemberSocial.Account> = emptyList()): String? {
        val network = post.socialNetwork ?: return null
        // A YouTube channel ID (`/channel/UC…`) is not a handle anyone would recognise.
        accounts.firstOrNull { it.network == network && "/channel/" !in it.url }?.handle?.let { return "@" + it.removePrefix("@") }
        val uri = runCatching { URI(post.url) }.getOrNull() ?: return null
        val parts = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
        return when (network) {
            SocialNetwork.BLUESKY -> parts.getOrNull(parts.indexOf("profile") + 1)?.takeIf { parts.contains("profile") }?.let { "@$it" }
            SocialNetwork.MASTODON -> parts.firstOrNull { it.startsWith("@") }
            SocialNetwork.YOUTUBE -> parts.firstOrNull { it.startsWith("@") }
            else -> null
        }
    }

    /** `10:16 AM` today, else `Nov 16 · 6:06 PM`, in the reader's zone and locale (lesson 69). */
    fun time(post: Post, now: Instant, zone: ZoneId, locale: Locale): String? {
        val at = post.postedInstant?.atZone(zone) ?: return null
        val sameDay = at.toLocalDate() == now.atZone(zone).toLocalDate()
        return at.format(DateTimeFormatter.ofPattern(if (sameDay) "h:mm a" else "MMM d · h:mm a", locale))
    }

    /** A day divider: `Today`, `Yesterday`, else `Thu, Nov 13`, in the reader's zone and locale. */
    fun day(day: LocalDate, today: LocalDate, locale: Locale): String = when (day) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> day.format(DateTimeFormatter.ofPattern("EEE, MMM d", locale))
    }

    /** [posts] (newest first) under their day dividers; an undated post sits under "Undated". */
    fun byDay(posts: List<Post>, now: Instant, zone: ZoneId, locale: Locale): List<Pair<String, List<Post>>> {
        val today = now.atZone(zone).toLocalDate()
        val days = LinkedHashMap<LocalDate?, MutableList<Post>>()
        posts.forEach { days.getOrPut(it.postedInstant?.atZone(zone)?.toLocalDate()) { mutableListOf() } += it }
        return days.map { (d, list) -> (d?.let { day(it, today, locale) } ?: "Undated") to list }
    }

    /** What the round arrow says: `Open on Bluesky`, `Watch on YouTube`. */
    fun openLabel(post: Post): String = post.openLabel.removeSuffix(" ›")
}
