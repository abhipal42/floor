package app.floor.android.week

import android.icu.text.DateFormat
import android.icu.util.TimeZone
import android.icu.util.ULocale
import app.floor.android.home.Stories
import app.floor.android.model.Chamber
import app.floor.android.model.Formats
import app.floor.android.model.Outcome
import app.floor.android.model.RecentVote
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.model.ScheduleItem
import app.floor.android.model.SenateMeeting
import app.floor.android.model.TopicGroup
import app.floor.android.model.VoteStep
import app.floor.android.model.outcome
import app.floor.android.store.FollowState
import java.time.Instant
import java.time.ZoneId
import java.util.Date
import java.util.Locale

/**
 * One headliner on the Week tab (v0.2.59, iOS `WeekView` headliners): a Senate measure the Digest's
 * program names, or a House bill up under a rule, with the line that puts it in context and up to
 * two of the latest real votes on it.
 */
data class Headliner(
    val row: WeekSort.Row,
    val chamber: Chamber,
    /** What the card is called: the bill's title, or the measure it carries (`legislative vehicle for X`). */
    val headline: String,
    /** `Riding on Survivor Justice Tax Prevention Act.`, a program sentence, or `Up under a rule (H.Res. 1665)`. */
    val context: String?,
    /** `Mon ✓ cloture 70–27`: at most two, newest first; none when the feed has no vote on it. */
    val chips: List<String>,
) {
    val item: ScheduleItem get() = row.item
    val topic: TopicGroup get() = TopicGroup.ofPolicyArea(item.policyArea)

    /** `SENATE · IN DEBATE`, `HOUSE · FULL DEBATE`. */
    val label: String get() = if (chamber == Chamber.SENATE) "SENATE · IN DEBATE" else "HOUSE · FULL DEBATE"
}

/** One fast-track tile: a Finals topic group and the House's suspension rows in it. */
data class FastTrackTile(val topic: TopicGroup, val rows: List<WeekSort.Row>) {
    /** Rows still on the list. */
    val count: Int get() = rows.count { !it.pulled }
}

/** The Week tab's pieces, built only from the schedule and the vote feed, apart from the screen so they can be tested. */
object WeekPlan {
    /** `Both chambers in · 17 measures listed`: only what the schedule itself says. */
    fun summary(schedule: Schedule): String {
        val houseIn = schedule.house.inSession == true && schedule.house.items.any { it.removedAt == null }
        val meetings = schedule.senate?.meetings.orEmpty()
        val senateIn = meetings.any { !it.proForma }
        val parts = mutableListOf<String>()
        when {
            houseIn && senateIn -> parts += "Both chambers in"
            else -> {
                parts += if (houseIn) "House list posted" else "No House list posted"
                parts += when {
                    senateIn -> "Senate in"
                    meetings.isNotEmpty() -> "Senate pro forma only"
                    else -> "No Senate meeting posted"
                }
            }
        }
        val listed = (schedule.house.items + schedule.senate?.items.orEmpty())
            .filter { it.removedAt == null }
            .map { it.billId ?: it.label }
            .distinct().size
        if (listed > 0) parts += "$listed ${if (listed == 1) "measure" else "measures"} listed"
        return parts.joinToString(" · ")
    }

    /**
     * The program's sentences. A sentence ends at a period after a lowercase letter, a digit or a
     * bracket and before a capital, so `H.R. 2347`, `S. 4668` and `No. 6883` stay whole.
     */
    fun sentences(program: String): List<String> =
        program.split(Regex("""(?<=[a-z0-9)]\.)\s+(?=[A-Z(])""")).map { it.trim() }.filter { it.isNotEmpty() }

    /** `X` from `<label>, Title (legislative vehicle for X)` in [program], or null when the program says no such thing. */
    fun vehicle(program: String, label: String): String? {
        if (label.isEmpty()) return null
        val match = Regex(Regex.escape(label) + """[^()]*\(legislative vehicle for ([^)]+)\)""").find(program) ?: return null
        return match.groupValues[1].trim().removePrefix("the ").trim()
    }

    /** `H.Res. 1665` from the House's `H. Res. 1665`. */
    fun citation(label: String): String = label.replace(Regex("""\. (?=[A-Z][a-z]+\.)"""), ".")

    /** Senate items the program names, then House bills up under a rule. */
    fun headliners(schedule: Schedule, votes: List<RecentVote>, follows: FollowState, zone: ZoneId, locale: Locale): List<Headliner> {
        val senate = schedule.senate
        val programs = senate?.meetings.orEmpty().mapNotNull { it.program }
        val senateRows = senate?.items.orEmpty()
            .filter { it.removedAt == null }
            .distinctBy { it.billId ?: it.label }
            .filter { item -> programs.any { item.label in it } }
            .map { item ->
                val vehicle = programs.firstNotNullOfOrNull { vehicle(it, item.label) }
                val (headline, context) = if (vehicle != null) {
                    vehicle to "Riding on ${item.title}."
                } else {
                    item.title to programs.flatMap(::sentences).firstOrNull { item.label in it }
                }
                Headliner(row(item, follows), Chamber.SENATE, headline, context, chips(item, votes, schedule.week, zone, locale))
            }
        val house = schedule.house.items
        val houseRows = house.filter { it.category == ScheduleCategory.RULE && it.removedAt == null }.map { item ->
            Headliner(row(item, follows), Chamber.HOUSE, item.title, ruleContext(item, house), chips(item, votes, schedule.week, zone, locale))
        }
        return senateRows + houseRows
    }

    /**
     * `Up under a rule (H.Res. 1665), with Direct Seller and Real Estate Agent Harmonization Act.`:
     * the resolution is the House's `other` item whose title names the bill, and any other listed
     * bill that title names comes along.
     */
    fun ruleContext(item: ScheduleItem, house: List<ScheduleItem>): String {
        val rule = house.firstOrNull { it.category == ScheduleCategory.OTHER && "(${item.label})" in it.title } ?: return "Up under a rule."
        val with = house.filter { it !== item && it.category == ScheduleCategory.RULE && it.removedAt == null && "(${it.label})" in rule.title }
            .map { it.title }
        val base = "Up under a rule (${citation(rule.label)})"
        return if (with.isEmpty()) "$base." else "$base, with ${with.joinToString(" and ")}."
    }

    /** `Mon ✓ cloture 70–27`, `Nov 11 ✓ motion to proceed 62–21`: the two latest votes on the item's bill. */
    fun chips(item: ScheduleItem, votes: List<RecentVote>, week: String, zone: ZoneId, locale: Locale): List<String> {
        val id = item.billId ?: return emptyList()
        val monday = Formats.day(week)
        return votes.filter { it.vote.billId == id || it.measure?.id == id }
            .sortedByDescending { it.vote.occurredAtInstant ?: Instant.MIN }
            .take(2)
            .map { row ->
                val vote = row.vote
                val at = vote.occurredAtInstant
                val day = at?.let {
                    val date = it.atZone(zone).toLocalDate()
                    if (monday != null && !date.isBefore(monday) && date.isBefore(monday.plusDays(7))) weekday(it, zone, locale)
                    else Stories.format(it, zone, locale)
                }
                val mark = when (vote.outcome) {
                    Outcome.CARRIED -> "✓"
                    Outcome.FAILED -> "✗"
                    null -> null
                }
                listOfNotNull(day, mark, VoteStep.name(vote).lowercase(), "${vote.totals.yea}–${vote.totals.nay}").joinToString(" ")
            }
    }

    private fun weekday(instant: Instant, zone: ZoneId, locale: Locale): String {
        val format = DateFormat.getInstanceForSkeleton("EEE", ULocale.forLocale(locale))
        format.timeZone = TimeZone.getTimeZone(zone.id)
        return format.format(Date.from(instant))
    }

    /** Today's meeting in Washington, else the next one, else the last one posted. */
    fun senateNext(senate: Schedule.Senate, now: Instant): SenateMeeting? {
        val today = now.atZone(EASTERN).toLocalDate().toString()
        return senate.meetings.sortedBy { it.date }.let { m -> m.firstOrNull { it.date >= today } ?: m.lastOrNull() }
    }

    /** `TODAY`, or the meeting's weekday: `TUESDAY`. */
    fun meetingDay(meeting: SenateMeeting, now: Instant): String {
        if (meeting.date == now.atZone(EASTERN).toLocalDate().toString()) return "TODAY"
        return Formats.day(meeting.date)?.dayOfWeek?.getDisplayName(java.time.format.TextStyle.FULL, Locale.US)?.uppercase() ?: meeting.date
    }

    /** `10:00` and `AM` in Washington's time, or null when senate.gov gave no time. */
    fun convenes(meeting: SenateMeeting): Pair<String, String>? {
        val at = meeting.convenesAt?.let {
            try {
                Instant.parse(it)
            } catch (_: java.time.format.DateTimeParseException) {
                null
            }
        } ?: return null
        val time = at.atZone(EASTERN)
        return time.format(java.time.format.DateTimeFormatter.ofPattern("h:mm", Locale.US)) to
            time.format(java.time.format.DateTimeFormatter.ofPattern("a", Locale.US))
    }

    /** The House's suspension items as one tile per topic group, the largest first (ties in the table's order). */
    fun fastTrack(items: List<ScheduleItem>, follows: FollowState): List<FastTrackTile> {
        val rows = WeekSort.groups(items.filter { it.category == ScheduleCategory.SUSPENSION }, follows).flatMap { it.rows }
        return rows.groupBy { TopicGroup.ofPolicyArea(it.item.policyArea) }
            .map { (topic, list) -> FastTrackTile(topic, list) }
            .sortedWith(compareByDescending<FastTrackTile> { it.count }.thenBy { it.topic.ordinal })
    }

    /** Everything else the House listed: neither a rule bill nor a suspension (the resolutions that bring bills up, say). */
    fun alsoListed(items: List<ScheduleItem>, follows: FollowState): List<WeekSort.Row> =
        WeekSort.groups(items.filter { it.category == ScheduleCategory.OTHER }, follows).flatMap { it.rows }

    private fun row(item: ScheduleItem, follows: FollowState): WeekSort.Row = WeekSort.groups(listOf(item), follows).first().rows.first()

    private val EASTERN: ZoneId = ZoneId.of("America/New_York")
}
