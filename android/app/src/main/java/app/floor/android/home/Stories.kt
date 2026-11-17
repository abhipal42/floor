package app.floor.android.home

import android.icu.text.DateFormat
import android.icu.util.TimeZone
import android.icu.util.ULocale
import app.floor.android.model.MeasureSummary
import app.floor.android.model.MemberPosition
import app.floor.android.model.Outcome
import app.floor.android.model.PartyTotals
import app.floor.android.model.Position
import app.floor.android.model.TopicGroup
import app.floor.android.model.Vote
import app.floor.android.model.VoteStep
import app.floor.android.model.outcomeWord
import app.floor.android.model.recordedOutcome
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Date
import java.util.Locale

/**
 * One story in the Finals feed (iOS `Story`): a bill or nomination with every final on it, oldest
 * first, or a single vote that names no measure. A House rule for a bill in the feed sits in that
 * bill's story.
 */
data class Story(val measure: MeasureSummary?, val steps: List<FeedItem>) {
    val id: String get() = measure?.id ?: steps.first().vote.id

    val latest: FeedItem get() = steps.last()

    /** The latest vote that decided something rather than moved the measure along: the main step. */
    val main: FeedItem? get() = steps.lastOrNull { !VoteStep.isProcedural(it.vote) }

    /** A full card: a measure with at least one vote that was not procedural. Otherwise a mini row. */
    val isFull: Boolean get() = measure != null && main != null

    val topic: TopicGroup get() = TopicGroup.of(measure)
}

/** A week of the feed: its header, its full cards, then its "Also this week" mini rows. */
data class StorySection(val title: String, val alsoTitle: String, val full: List<Story>, val minis: List<Story>)

/** One of your members on a story: their position on the main step, and whether every step matched it. */
data class StoryMember(val position: MemberPosition, val sameOnAll: Int?)

object Stories {
    private val oldest = compareBy<FeedItem>({ it.vote.occurredAtInstant ?: Instant.MIN }, { it.vote.id })

    /**
     * The feed's votes as stories, newest latest vote first. A vote is keyed by its measure; a rule
     * whose [MeasureSummary.forBillId] is a bill in the feed joins that bill; a vote with no measure
     * stands alone.
     */
    fun group(items: List<FeedItem>): List<Story> {
        val measures = items.mapNotNull { it.measure }.associateBy { it.id }
        val byKey = LinkedHashMap<String, MutableList<FeedItem>>()
        for (item in items.distinctBy { it.vote.id }) {
            val m = item.measure
            val key = when {
                m == null -> "vote:${item.vote.id}"
                m.forBillId != null && measures[m.forBillId]?.kind == MeasureSummary.Kind.BILL -> m.forBillId
                else -> m.id
            }
            byKey.getOrPut(key) { mutableListOf() } += item
        }
        return byKey.map { (key, steps) -> Story(measures[key], steps.sortedWith(oldest)) }
            .sortedWith(compareByDescending<Story> { it.latest.vote.occurredAtInstant ?: Instant.MIN }.thenByDescending { it.latest.vote.id })
    }

    /** The first day of [instant]'s week in the reader's zone and locale. */
    private fun weekOf(instant: Instant, zone: ZoneId, locale: Locale): LocalDate =
        instant.atZone(zone).toLocalDate().with(TemporalAdjusters.previousOrSame(WeekFields.of(locale).firstDayOfWeek))

    /**
     * [stories] (newest first) by the week of their latest vote: "This week", "Last week", then
     * "Week of Nov 2". Each week lists its full cards, then its minis.
     */
    fun sections(stories: List<Story>, now: Instant, zone: ZoneId, locale: Locale): List<StorySection> {
        val thisWeek = weekOf(now, zone, locale)
        val weeks = LinkedHashMap<LocalDate?, MutableList<Story>>()
        for (story in stories) {
            val week = story.latest.vote.occurredAtInstant?.let { weekOf(it, zone, locale) }
            weeks.getOrPut(week) { mutableListOf() } += story
        }
        return weeks.map { (week, list) ->
            val (title, also) = when (week) {
                thisWeek -> "This week" to "Also this week"
                thisWeek.minusWeeks(1) -> "Last week" to "Also last week"
                null -> "Undated" to "Also undated"
                else -> "Week of ${format(week.atStartOfDay(zone).toInstant(), zone, locale)}" to "Also that week"
            }
            StorySection(title, also, list.filter { it.isFull }, list.filterNot { it.isFull })
        }
    }

    /** `Nov 12`, in the reader's zone and locale (lesson 69). */
    fun format(instant: Instant, zone: ZoneId, locale: Locale): String {
        val format = DateFormat.getInstanceForSkeleton("MMMd", ULocale.forLocale(locale))
        format.timeZone = TimeZone.getTimeZone(zone.id)
        return format.format(Date.from(instant))
    }

    /** A step's line: `Rule for debate · Nov 12`. */
    fun stepName(vote: Vote, zone: ZoneId, locale: Locale): String =
        listOfNotNull(VoteStep.name(vote), vote.occurredAtInstant?.let { format(it, zone, locale) }).joinToString(" · ")

    /**
     * The verdict chip, from the main step: PASSED HOUSE, PASSED SENATE, CONFIRMED, AGREED TO,
     * FAILED, REJECTED, else the result as recorded, upper-cased.
     */
    fun verdict(vote: Vote): String? {
        val r = vote.result?.lowercase().orEmpty()
        return when (vote.recordedOutcome) {
            Outcome.CARRIED -> when {
                "confirmed" in r -> "CONFIRMED"
                "passed" in r -> "PASSED ${vote.chamber.title.uppercase()}"
                "agreed" in r -> "AGREED TO"
                else -> vote.result?.uppercase()
            }
            Outcome.FAILED -> if ("rejected" in r || "not agreed" in r) "REJECTED" else "FAILED"
            null -> vote.result?.uppercase()
        }
    }

    /** `U.S. Circuit Judge` from `United States Circuit Judge for the Tenth Circuit`. */
    fun positionTitle(position: String): String = position.substringBefore(" for the ").replace("United States", "U.S.")

    /** `Tenth Circuit` from the same; null when the position names no place. */
    fun positionPlace(position: String): String? = position.substringAfter(" for the ", "").takeIf { it.isNotEmpty() }

    /** The band's topic line: the policy area, or `Nomination · Tenth Circuit`. */
    fun topicLine(measure: MeasureSummary): String = when (measure.kind) {
        MeasureSummary.Kind.BILL -> measure.policyArea ?: "Bill"
        MeasureSummary.Kind.NOMINATION -> listOfNotNull("Nomination", measure.position?.let(::positionPlace)).joinToString(" · ")
    }

    /** `H.R. 2102 · Sponsor Bilirakis (R-FL)`, or `U.S. Circuit Judge · PN999-2`. */
    fun citationLine(measure: MeasureSummary): String = when (measure.kind) {
        MeasureSummary.Kind.BILL -> listOfNotNull(
            measure.citation,
            measure.sponsor?.let { "Sponsor ${it.lastName} (${it.party}-${it.state})" },
        ).joinToString(" · ")
        MeasureSummary.Kind.NOMINATION -> listOfNotNull(measure.position?.let(::positionTitle), measure.citation).joinToString(" · ")
    }

    /** A mini row's title: the measure's, or the question's own words for a vote with no measure. */
    fun miniTitle(story: Story): String = story.measure?.title ?: story.latest.vote.question.removePrefix("On the ").removePrefix("On ")

    /** `Fifth Circuit · Cloture agreed Nov 12`, or `Measure not named in the record · Nov 16`. */
    fun miniLine(story: Story, zone: ZoneId, locale: Locale): String {
        val vote = story.latest.vote
        val day = vote.occurredAtInstant?.let { format(it, zone, locale) }
        val measure = story.measure ?: return listOfNotNull("Measure not named in the record", day).joinToString(" · ")
        val where = when (measure.kind) {
            MeasureSummary.Kind.BILL -> measure.citation
            MeasureSummary.Kind.NOMINATION -> measure.position?.let { positionPlace(it) ?: positionTitle(it) } ?: measure.citation
        }
        val what = listOfNotNull(VoteStep.name(vote), vote.outcomeWord?.lowercase(), day).joinToString(" ")
        return "$where · $what"
    }

    /**
     * The main step's party split: yea segments in party colour, then nay segments, each by count,
     * largest first.
     */
    fun split(totals: List<PartyTotals>): List<Triple<String, Position, Int>> {
        val yea = totals.filter { it.yea > 0 }.sortedByDescending { it.yea }.map { Triple(it.party, Position.YEA, it.yea) }
        val nay = totals.filter { it.nay > 0 }.sortedByDescending { it.nay }.map { Triple(it.party, Position.NAY, it.nay) }
        return yea + nay
    }

    /**
     * Your members who voted on any step, in feed order ([only] limits them to these IDs, e.g. your
     * three in "All"): each one's position on the main step (or their latest step when they missed
     * it), and the step count when they voted the same way on every step of two or more.
     */
    fun members(story: Story, only: Set<String>? = null): List<StoryMember> {
        val main = story.main ?: story.latest
        val ids = LinkedHashSet<String>()
        story.steps.forEach { step -> step.positions.forEach { ids += it.member.bioguideId } }
        return ids.filter { only == null || it in only }.mapNotNull { id ->
            val onSteps = story.steps.map { step -> step.positions.firstOrNull { it.member.bioguideId == id } }
            val shown = main.positions.firstOrNull { it.member.bioguideId == id } ?: onSteps.lastOrNull { it != null } ?: return@mapNotNull null
            val same = story.steps.size >= 2 && onSteps.all { it?.position == shown.position }
            StoryMember(shown, if (same) story.steps.size else null)
        }
    }

    private val counts = listOf("zero", "one", "both", "all three", "all four", "all five", "all six", "all seven", "all eight", "all nine", "all ten")

    /** `on all three`, `on both`. */
    fun onAll(steps: Int): String = "on " + (counts.getOrNull(steps) ?: "all $steps")

    /** The score as TalkBack says it: `392 to 18`. */
    fun spokenScore(vote: Vote): String = "${vote.totals.yea} to ${vote.totals.nay}"

    /** What TalkBack reads for a full card: title, verdict, the main score, and your members' votes. */
    fun spoken(story: Story, members: List<StoryMember>): String {
        val main = story.main ?: story.latest
        val parts = mutableListOf(story.measure?.title ?: miniTitle(story))
        verdict(main.vote)?.let { v ->
            parts += v.lowercase().replaceFirstChar(Char::uppercase).replace(" house", " the House").replace(" senate", " the Senate")
        }
        parts += "${VoteStep.name(main.vote)}, ${spokenScore(main.vote)}"
        if (members.isNotEmpty()) {
            parts += members.joinToString(", ") { m ->
                val word = when (m.position.position) {
                    Position.NOT_VOTING -> "did not vote"
                    else -> m.position.position.name.lowercase().replace('_', ' ')
                }
                listOfNotNull(m.position.member.lastName, word, m.sameOnAll?.let(::onAll)).joinToString(" ")
            }
        }
        return parts.joinToString(". ") + "."
    }
}
