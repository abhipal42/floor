package app.floor.android.model

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// v0.2.60: a member's headlines of the week, grouped into stories by the AI, and the polls that name
// them (`GET /v1/members/{id}/news`). Decoded leniently: a field the API leaves out, or a tone or
// status this version doesn't know, reads as null rather than failing the page.

/** How a headline frames the member, as the AI read it; [OFFICE] is their own office's (or another .gov). */
enum class Tone(val raw: String) {
    FAVORABLE("favorable"), NEUTRAL("neutral"), CRITICAL("critical"), OFFICE("office");

    companion object {
        fun of(raw: String?): Tone? = entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/** Headlines by tone. [office] is never counted in a bar or a summary. */
@Serializable
data class ToneCounts(val favorable: Int = 0, val neutral: Int = 0, val critical: Int = 0, val office: Int = 0) {
    /** What the bar and the summary count: everything but the office's own. */
    val counted: Int get() = favorable + neutral + critical

    /**
     * The tone bar's segments, left to right (favorable, neutral, critical), each its share of the
     * counted headlines; a tone with none has no segment. Empty when nothing is counted.
     */
    val bar: List<Pair<Tone, Float>>
        get() {
            val total = counted
            if (total <= 0) return emptyList()
            return listOf(Tone.FAVORABLE to favorable, Tone.NEUTRAL to neutral, Tone.CRITICAL to critical)
                .filter { it.second > 0 }
                .map { (tone, n) -> tone to n.toFloat() / total }
        }

    /** `1 favorable, 7 neutral, 4 critical`. */
    val line: String get() = "$favorable favorable, $neutral neutral, $critical critical"

    /** The bar for TalkBack: `Coverage tone: 1 favorable, 5 neutral, 3 critical`. */
    val spoken: String get() = "Coverage tone: $line"
}

@Serializable
data class NewsWindow(val from: String? = null, val to: String? = null)

/** A group of two or more headlines about one event; [title] is the AI's, in neutral wording. */
@Serializable
data class NewsStory(
    val id: String,
    val title: String,
    val tone: ToneCounts = ToneCounts(),
    val headlineIds: List<String> = emptyList(),
    /** Not in the v0.2.60 contract: read should the API add one, else the chip shortens [title]. */
    val shortTitle: String? = null,
) {
    /** The filter chip's name: [shortTitle], else the title cut at a word to fit a chip. */
    val chipTitle: String get() = shortTitle?.takeIf { it.isNotBlank() } ?: News.shorten(title)
}

@Serializable
data class Headline(
    val id: String,
    val title: String,
    val source: String = "",
    val url: String = "",
    val publishedAt: String? = null,
    /** `favorable`, `neutral`, `critical`, `office`; null (or anything else) when it was not AI-read. */
    private val tone: String? = null,
    val storyId: String? = null,
) {
    val toneValue: Tone? get() = Tone.of(tone)

    val publishedInstant: Instant? get() = publishedAt?.let { runCatching { Instant.parse(it) }.getOrNull() }

    /** `The Hill · Nov 17`, in the reader's zone. */
    fun sourceLine(zone: ZoneId, locale: Locale): String =
        listOfNotNull(source.takeIf { it.isNotBlank() }, publishedInstant?.let { News.day(it, zone, locale) }).joinToString(" · ")

    /** TalkBack: the title, the source, the day and the tone. */
    fun spoken(zone: ZoneId, locale: Locale): String = listOfNotNull(
        title,
        source.takeIf { it.isNotBlank() },
        publishedInstant?.let { News.day(it, zone, locale) },
        when (toneValue) {
            Tone.FAVORABLE -> "favorable coverage"
            Tone.NEUTRAL -> "neutral coverage"
            Tone.CRITICAL -> "critical coverage"
            Tone.OFFICE -> "from their office"
            null -> null
        },
    ).joinToString(", ")
}

/** One side of a poll, worded as the pollster worded it. */
@Serializable
data class PollShare(val label: String, val pct: Double)

@Serializable
data class Poll(
    val id: String,
    val pollster: String,
    val fieldedFrom: String? = null,
    val fieldedTo: String? = null,
    val population: String? = null,
    val sampleSize: Int? = null,
    val positive: PollShare,
    val negative: PollShare,
    val other: PollShare? = null,
    val url: String = "",
) {
    /** `Economist/YouGov · Nov 13–16 · U.S. adults`. */
    fun header(locale: Locale): String =
        listOfNotNull(pollster, News.fieldDates(fieldedFrom, fieldedTo, locale), population?.takeIf { it.isNotBlank() }).joinToString(" · ")

    /**
     * The bar's three segments as shares of 100: positive, the middle (the poll's own [other], else
     * what is left unreported), negative. The middle is null when there is nothing between them.
     */
    val bar: Triple<Float, Float, Float>
        get() {
            val middle = other?.pct ?: (100 - positive.pct - negative.pct).coerceAtLeast(0.0)
            return Triple(positive.pct.toFloat(), middle.toFloat(), negative.pct.toFloat())
        }

    /** TalkBack: the header, then each share. */
    fun spoken(locale: Locale): String = (
        listOf(header(locale)) +
            listOfNotNull(positive, other, negative).map { "${News.percent(it.pct)} ${it.label}" }
        ).joinToString(". ") + ". Opens the poll's release."
}

private object LossyStories : LossyList<NewsStory>(NewsStory.serializer())
private object LossyHeadlines : LossyList<Headline>(Headline.serializer())
private object LossyPolls : LossyList<Poll>(Poll.serializer())

/** `GET /v1/members/{id}/news`: the week's headlines, the AI's stories and tone, and the polls. */
@Serializable
data class MemberNews(
    val memberId: String = "",
    val checkedAt: String? = null,
    val window: NewsWindow? = null,
    /** Null when no headline in the window was AI-read. */
    val tone: ToneCounts? = null,
    @Serializable(with = LossyStories::class) val stories: List<NewsStory> = emptyList(),
    @Serializable(with = LossyHeadlines::class) val headlines: List<Headline> = emptyList(),
    @Serializable(with = LossyPolls::class) val polls: List<Poll> = emptyList(),
) {
    /** Nothing to show: no headlines and no polls, so the member page leaves the section out. */
    val isEmpty: Boolean get() = headlines.isEmpty() && polls.isEmpty()

    /** Read by the AI: the tone summary and the bars show, and the stories are its groups. */
    val aiRead: Boolean get() = tone != null

    /** The stories that still have headlines here, biggest first, as the API orders them. */
    val shownStories: List<NewsStory>
        get() = if (!aiRead) emptyList() else stories.filter { storyHeadlines(it).size >= 2 }

    /** A story's headlines, newest first. */
    fun storyHeadlines(story: NewsStory): List<Headline> {
        val ids = story.headlineIds.toSet()
        return newestFirst(headlines.filter { it.storyId == story.id || it.id in ids })
    }

    /** Headlines in no shown story, newest first. */
    val otherHeadlines: List<Headline>
        get() {
            val inStories = shownStories.flatMap { storyHeadlines(it) }.map { it.id }.toSet()
            return newestFirst(headlines.filter { it.id !in inStories })
        }

    /** The page's filter chips: All, one per story, and Other; just All when there are no stories. */
    val filters: List<NewsFilter>
        get() {
            val stories = shownStories
            if (stories.isEmpty()) return listOf(NewsFilter.All)
            val other = otherHeadlines.size
            return listOf(NewsFilter.All) +
                stories.map { NewsFilter.Story(it.id, "${it.chipTitle} · ${storyHeadlines(it).size}") } +
                (if (other > 0) listOf(NewsFilter.Other("Other · $other")) else emptyList())
        }

    /** `12 headlines this week`; the AI READ chip and its counts follow when [tone] is present. */
    val countLine: String
        get() = "${headlines.size} ${if (headlines.size == 1) "headline" else "headlines"} this week"

    /** The whole summary for TalkBack. */
    val spokenSummary: String
        get() = if (headlines.isEmpty()) "No headlines this week." else countLine + (tone?.let { ". AI read: ${it.line}." } ?: ".")

    companion object {
        /** What an API without the route, or before its migration, reads as. */
        const val NONE_BODY = """{"headlines":[],"stories":[],"polls":[]}"""

        private fun newestFirst(list: List<Headline>) = list.sortedByDescending { it.publishedInstant ?: Instant.EPOCH }
    }
}

/** A filter chip on the News page. */
sealed interface NewsFilter {
    val label: String

    data object All : NewsFilter {
        override val label = "All"
    }

    data class Story(val id: String, override val label: String) : NewsFilter

    data class Other(override val label: String) : NewsFilter
}

/** Words shared by the news, the polls and the Local tab. */
object News {
    /** `Nov 17`. */
    fun day(instant: Instant, zone: ZoneId, locale: Locale): String =
        DateTimeFormatter.ofPattern("MMM d", locale).withZone(zone).format(instant)

    /** `Nov 11` from `2026-11-11`. */
    fun day(date: String?, locale: Locale): String? =
        date?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }?.let { DateTimeFormatter.ofPattern("MMM d", locale).format(it) }

    /** `Nov 13–16`, `Oct 28 – Nov 2`, or one day. */
    fun fieldDates(from: String?, to: String?, locale: Locale): String? {
        val a = from?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        val b = to?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        val month = DateTimeFormatter.ofPattern("MMM d", locale)
        return when {
            a == null && b == null -> null
            a == null || b == null || a == b -> month.format(a ?: b)
            a.month == b.month && a.year == b.year -> "${month.format(a)}–${b.dayOfMonth}"
            else -> "${month.format(a)} – ${month.format(b)}"
        }
    }

    /** `22%`, `22.5%`. */
    fun percent(pct: Double): String =
        if (pct == pct.roundToInt().toDouble()) "${pct.roundToInt()}%" else String.format(Locale.US, "%.1f%%", pct)

    /** A story title cut at a word to fit a chip: at most [max] characters, with an ellipsis. */
    fun shorten(title: String, max: Int = 24): String {
        val t = title.trim()
        if (t.length <= max) return t
        val cut = t.take(max - 1).substringBeforeLast(' ').ifBlank { t.take(max - 1) }
        return cut.trimEnd(',', ';', ':', '·', ' ') + "…"
    }

    /** "Each poll opens its release. Only polls that name <name> are shown." */
    fun pollsFootnote(name: String) = "Each poll opens its release. Only polls that name $name are shown."

    fun noPolls(name: String) = "No published poll has named $name in the last 90 days."

    const val NO_HEADLINES = "No headlines this week."
}
