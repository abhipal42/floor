package app.floor.android.model

import kotlinx.serialization.Serializable
import java.net.URI
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale

// Round 13 of the contract: `GET /v1/members/{id}/promises`, `/posts`, `GET /v1/posts?members=`, and
// the member's `social` handles. Decoded leniently: an unknown status reads as unchecked, an unknown
// network or an unreadable element is dropped alone, and a missing field is null.

private fun instant(text: String?): Instant? = text?.let {
    try {
        Instant.parse(it)
    } catch (_: DateTimeParseException) {
        null
    }
}

/** A member's official accounts, as handles (congress-legislators, plus Bluesky only when Bluesky verifies it). */
@Serializable
data class MemberSocial(
    val twitter: String? = null,
    val facebook: String? = null,
    val instagram: String? = null,
    val youtube: String? = null,
    val youtubeId: String? = null,
    val mastodon: String? = null,
    val bluesky: String? = null,
) {
    /** One account the Contact grid shows: the network, the handle as printed, and where a tap goes. */
    data class Account(val network: SocialNetwork, val handle: String, val url: String)

    /** Every account there is, in the grid's order: X, Facebook, Instagram, YouTube, Bluesky, Mastodon. */
    val accounts: List<Account>
        get() = listOfNotNull(
            twitter.clean()?.let { Account(SocialNetwork.X, "@${it.removePrefix("@")}", SocialNetwork.X.url(it)) },
            facebook.clean()?.let { Account(SocialNetwork.FACEBOOK, it, SocialNetwork.FACEBOOK.url(it)) },
            instagram.clean()?.let { Account(SocialNetwork.INSTAGRAM, it, SocialNetwork.INSTAGRAM.url(it)) },
            // A legacy user name links as youtube.com/<name>; a member with only a channel ID, as /channel/<id>.
            youtube.clean()?.let { Account(SocialNetwork.YOUTUBE, it, SocialNetwork.YOUTUBE.url(it)) }
                ?: youtubeId.clean()?.let { Account(SocialNetwork.YOUTUBE, it, "https://www.youtube.com/channel/$it") },
            bluesky.clean()?.let { Account(SocialNetwork.BLUESKY, it.removePrefix("@"), SocialNetwork.BLUESKY.url(it)) },
            mastodon.clean()?.let { handle -> SocialNetwork.MASTODON.url(handle).takeIf { it.isNotEmpty() }?.let { Account(SocialNetwork.MASTODON, handle, it) } },
        )

    private fun String?.clean(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
}

/** The networks a member's accounts are on. [readable]: Floor can show its posts (free, public APIs). */
enum class SocialNetwork(val title: String, val readable: Boolean) {
    X("X", false), FACEBOOK("Facebook", false), INSTAGRAM("Instagram", false),
    YOUTUBE("YouTube", true), BLUESKY("Bluesky", true), MASTODON("Mastodon", true);

    /** The account's page, which the network's app opens when it is installed. */
    fun url(handle: String): String {
        val h = handle.trim().removePrefix("@")
        return when (this) {
            X -> "https://x.com/$h"
            FACEBOOK -> "https://www.facebook.com/$h"
            INSTAGRAM -> "https://www.instagram.com/$h"
            YOUTUBE -> "https://www.youtube.com/$h"
            BLUESKY -> "https://bsky.app/profile/$h"
            // `@user@instance.social` → `https://instance.social/@user`.
            MASTODON -> h.split("@").takeIf { it.size == 2 && it.all(String::isNotEmpty) }?.let { (user, host) -> "https://$host/@$user" } ?: ""
        }
    }

    companion object {
        /** The posts' `network` field (`youtube`, `bluesky`, `mastodon`), or null for one this build doesn't know. */
        fun of(raw: String): SocialNetwork? = entries.firstOrNull { it.name.equals(raw.trim(), ignoreCase = true) }
    }
}

// MARK: - Promises

/** One promise: the site's own heading, the verbatim quote, the clause of it the deck prints big, and its Floor topic. */
@Serializable
data class Promise(
    val heading: String? = null,
    val quote: String,
    val headline: String,
    val topic: String? = null,
) {
    /** The topic, if it is one of the 32: the card's link to its page. */
    val floorTopic: String? get() = topic?.let(Topic::canonical)
}

private object LossyPromises : LossyList<Promise>(Promise.serializer())

/** `GET /v1/members/{id}/promises`: what the campaign site said in the race that won this term. */
@Serializable
data class Promises(
    /** `promises`, `no_platform`, `no_site`, `no_snapshot`, `unchecked`; anything else reads as unchecked. */
    private val status: String = "unchecked",
    val electionYear: Int? = null,
    val siteUrl: String? = null,
    val snapshotUrl: String? = null,
    val snapshotAt: String? = null,
    val pageUrl: String? = null,
    @Serializable(with = LossyPromises::class) val promises: List<Promise> = emptyList(),
) {
    enum class Status { PROMISES, NO_PLATFORM, NO_SITE, NO_SNAPSHOT, UNCHECKED }

    /** What the screen draws. Promises with none to show is a site that listed none. */
    val state: Status
        get() = when (status.trim().lowercase()) {
            "promises" -> if (promises.isEmpty()) Status.NO_PLATFORM else Status.PROMISES
            "no_platform" -> Status.NO_PLATFORM
            "no_site" -> Status.NO_SITE
            "no_snapshot" -> Status.NO_SNAPSHOT
            else -> Status.UNCHECKED
        }

    val snapshotInstant: Instant? get() = instant(snapshotAt)

    /** `Oct 12, 2024`: the archive copy's day, in Washington (where the race's calendar is). */
    fun archivedDay(locale: Locale): String? =
        snapshotInstant?.atZone(WASHINGTON)?.format(DateTimeFormatter.ofPattern("MMM d, yyyy", locale))

    /** `elissaslotkin.org`, the campaign site's host. */
    val siteHost: String? get() = host(siteUrl ?: snapshotUrl?.substringAfter("/http", "")?.let { "http$it" })

    companion object {
        /** What a 404 stands for: an API without the route has not looked. */
        const val UNCHECKED_BODY = """{"status":"unchecked"}"""
        private val WASHINGTON: ZoneId = ZoneId.of("America/New_York")

        fun host(url: String?): String? = url?.let { runCatching { URI(it).host }.getOrNull() }?.removePrefix("www.")
    }
}

// MARK: - Posts

/** One post as it was posted (YouTube: the video's title), with a link to the original. */
@Serializable
data class Post(
    val id: String,
    private val network: String,
    val postedAt: String? = null,
    val text: String? = null,
    val url: String,
    val mediaUrl: String? = null,
    /** On the wall only. */
    val memberId: String? = null,
) {
    val socialNetwork: SocialNetwork? get() = SocialNetwork.of(network)
    val postedInstant: Instant? get() = instant(postedAt)

    /** `Nov 16 · 5:01 PM` in [zone]. */
    fun whenLabel(zone: ZoneId, locale: Locale): String? =
        postedInstant?.atZone(zone)?.format(DateTimeFormatter.ofPattern("MMM d · h:mm a", locale))

    /** `Open on Bluesky ›`, `Watch on YouTube ›`. */
    val openLabel: String
        get() = if (socialNetwork == SocialNetwork.YOUTUBE) "Watch on YouTube ›" else "Open on ${socialNetwork?.title ?: "the network"} ›"
}

/** Only posts on a network Floor can show, newest first whatever order they came in. */
private fun List<Post>.shown(): List<Post> =
    filter { it.socialNetwork?.readable == true }.sortedByDescending { it.postedInstant ?: Instant.EPOCH }

private object LossyPosts : LossyList<Post>(Post.serializer())

/** Where a member's links-only accounts are: full URLs (a bare handle is still accepted). */
@Serializable
data class PostLinks(val x: String? = null, val facebook: String? = null, val instagram: String? = null) {
    val accounts: List<MemberSocial.Account>
        get() = listOfNotNull(
            x?.let { account(SocialNetwork.X, it) },
            facebook?.let { account(SocialNetwork.FACEBOOK, it) },
            instagram?.let { account(SocialNetwork.INSTAGRAM, it) },
        )

    private fun account(network: SocialNetwork, value: String): MemberSocial.Account? {
        val v = value.trim().takeIf { it.isNotEmpty() } ?: return null
        val url = if (v.startsWith("http")) v else network.url(v)
        val handle = if (v.startsWith("http")) v.trimEnd('/').substringAfterLast('/') else v.removePrefix("@")
        return MemberSocial.Account(network, if (network == SocialNetwork.X) "@$handle" else handle, url)
    }
}

/** `GET /v1/members/{id}/posts`: newest first, at most 30, and the networks that are links only. */
@Serializable
data class MemberPosts(
    @Serializable(with = LossyPosts::class) private val posts: List<Post> = emptyList(),
    val links: PostLinks = PostLinks(),
) {
    val shown: List<Post> get() = posts.shown()

    companion object {
        const val NONE_BODY = """{"posts":[]}"""
    }
}

/** `GET /v1/posts?members=`: the wall, and the members whose accounts are all links-only. */
@Serializable
data class PostsWall(
    @Serializable(with = LossyPosts::class) private val posts: List<Post> = emptyList(),
    val unreadable: List<String> = emptyList(),
) {
    val shown: List<Post> get() = posts.shown()

    companion object {
        const val NONE_BODY = """{"posts":[],"unreadable":[]}"""

        /** The API's cap on `?members=`. */
        const val MAX_MEMBERS = 12
    }
}
