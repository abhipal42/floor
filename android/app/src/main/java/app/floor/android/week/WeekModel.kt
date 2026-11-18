package app.floor.android.week

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.SavedCopy
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.model.ScheduleItem
import app.floor.android.model.SenateMeeting
import app.floor.android.model.Topic
import app.floor.android.store.FollowState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What the Week tab shows (iOS `WeekModel`). */
data class WeekState(
    val phase: Phase = Phase.Loading,
    val saved: SavedCopy? = null,
    /** Weeks from this one: 0 is this week, 1 next week (the ingest stores both), -1 last week. */
    val offset: Int = 0,
    /** The Monday asked for, `YYYY-MM-DD`. */
    val week: String,
    /** A screen opened from the week: today's Senate content, or fast-track rows. Null for the week itself. */
    val detail: Detail? = null,
) {
    sealed interface Phase {
        data object Loading : Phase
        data class Loaded(val schedule: Schedule) : Phase
        data class Failed(val message: String) : Phase
    }

    sealed interface Detail {
        /** "Program ›": the Senate's meetings, the full programs and the measures they name. */
        data object Senate : Detail

        /** A fast-track tile's rows, or every fast-track row when [topic] is null ("All ›"). */
        data class FastTrack(val topic: app.floor.android.model.TopicGroup?) : Detail
    }

    /** `THIS WEEK`, `NEXT WEEK`, `WEEK OF`. */
    val title: String get() = when (offset) {
        0 -> "THIS WEEK"
        1 -> "NEXT WEEK"
        else -> "WEEK OF"
    }

    /** `Nov 16–20`, from the schedule once loaded, else from the Monday asked for. */
    val range: String get() = (phase as? Phase.Loaded)?.schedule?.weekRange ?: Schedule.weekRange(week)
}

/**
 * The Week tab (round 11, section A of <https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r>): what
 * the House has listed for a week, and when the Senate meets, from `GET /v1/schedule?week=`.
 */
class WeekModel(
    private val api: FloorApi,
    private val now: () -> Instant = Instant::now,
) : ViewModel() {
    var state by mutableStateOf(WeekState(week = Schedule.monday(now())))
        private set

    private var job: Job? = null

    fun appear() {
        if (state.phase !is WeekState.Phase.Loaded || state.saved != null) reload()
    }

    fun reload() {
        job?.cancel()
        job = viewModelScope.launch { load() }
    }

    fun show(offset: Int) {
        if (offset == state.offset) return
        state = state.copy(offset = offset, week = Schedule.monday(now(), offset), detail = null, phase = WeekState.Phase.Loading, saved = null)
        reload()
    }

    /** Opens a screen from the week, or closes it with null. */
    fun open(detail: WeekState.Detail?) {
        state = state.copy(detail = detail)
    }

    suspend fun load() {
        val week = state.week
        val onScreen = state.phase is WeekState.Phase.Loaded
        if (!onScreen) state = state.copy(phase = WeekState.Phase.Loading, saved = null)
        val saved = api.savedSchedule(week)
        if (saved != null && !onScreen) {
            state = state.copy(phase = WeekState.Phase.Loaded(saved.value), saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING))
        }
        val next = try {
            state.copy(phase = WeekState.Phase.Loaded(api.schedule(week)), saved = null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            when {
                saved != null -> state.copy(
                    phase = WeekState.Phase.Loaded(saved.value),
                    saved = SavedCopy(saved.fetchedAt, if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED),
                )
                onScreen -> state
                else -> state.copy(phase = WeekState.Phase.Failed(e.message ?: "Couldn't load the week."))
            }
        }
        // A week arrow tapped meanwhile: this answer is for a week no longer shown.
        if (state.week == week) state = next
    }
}

/** How a week's list is grouped and ordered, apart from the screen so it can be tested (iOS `WeekSort`). */
object WeekSort {
    /** Why an item has the gold edge: a followed bill, or a followed topic by its name. */
    sealed interface Followed {
        data object Bill : Followed
        data class Topic(val name: String) : Followed
    }

    data class Row(val item: ScheduleItem, val followed: Followed? = null) {
        /** Taken off the week's list; kept, dimmed, at the end of its group. */
        val pulled: Boolean get() = item.removedAt != null
        val id: String get() = "${item.categoryRaw}|${item.billId ?: item.label}"
    }

    data class Group(val category: ScheduleCategory, val rows: List<Row>) {
        /** Items still on the list. */
        val count: Int get() = rows.count { !it.pulled }

        val title: String get() = when (category) {
            ScheduleCategory.RULE -> "Debated under a rule"
            ScheduleCategory.SUSPENSION -> "Fast track, needs ⅔"
            ScheduleCategory.OTHER -> "Other items"
        }
    }

    /**
     * The House's groups in the House's order (rule, suspension, other), each led by what you
     * follow — directly, or through a followed topic — then the House's own order, then anything
     * pulled from the list. A group with no rows is left out.
     */
    fun groups(items: List<ScheduleItem>, state: FollowState): List<Group> {
        val topics = state.followedTopics.toSet()
        val rows = items.map { item ->
            val id = item.billId
            val area = item.policyArea?.let { Topic.canonical(it) }
            when {
                id != null && state.isFollowingBill(id) -> Row(item, Followed.Bill)
                area != null && area in topics -> Row(item, Followed.Topic(area))
                else -> Row(item)
            }
        }
        return ScheduleCategory.entries.mapNotNull { category ->
            val mine = rows.filter { it.item.category == category }
            if (mine.isEmpty()) null
            // sortedBy is stable, so the House's order holds within each rank.
            else Group(category, mine.sortedBy { if (it.pulled) 2 else if (it.followed == null) 1 else 0 })
        }
    }

    /** `FOLLOWING · LABOR`: the topic's first word; `FOLLOWING` for a bill. */
    fun tag(followed: Followed?): String? = when (followed) {
        Followed.Bill -> "FOLLOWING"
        is Followed.Topic -> "FOLLOWING · ${followed.name.split(" ").first().uppercase()}"
        null -> null
    }

    /** What a screen reader says for a row. */
    fun spoken(row: Row): String {
        val parts = mutableListOf(row.item.label, row.item.title)
        when (val f = row.followed) {
            Followed.Bill -> parts += "You follow this bill"
            is Followed.Topic -> parts += "In ${f.name}, a topic you follow"
            null -> {}
        }
        if (row.pulled) parts += "Taken off this week's list"
        row.item.latestLine?.let { parts += "Latest: $it" }
        return parts.joinToString(". ")
    }

    /** `Source: House Majority Leader, updated Nov 13`. */
    fun sourceLine(schedule: Schedule): String {
        val updated = schedule.sourceUpdatedAt?.let(::instant)?.atZone(EASTERN)?.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))
        return listOfNotNull("Source: House Majority Leader", updated?.let { "updated $it" }).joinToString(", ")
    }

    /** `Source: senate.gov and the Congressional Record's Daily Digest (172/171)`. */
    fun senateSource(senate: Schedule.Senate): String {
        val issues = senate.meetings.mapNotNull { it.recordIssue }
        return "Source: senate.gov and the Congressional Record's Daily Digest" + if (issues.isEmpty()) "" else " (${issues.joinToString(", ")})"
    }

    /** `Convenes Monday 3:00 PM ET`, in Washington's time; the Digest's heading when senate.gov gave no time. */
    fun convenes(meeting: SenateMeeting): String {
        meeting.convenesAt?.let(::instant)?.let {
            return "Convenes ${it.atZone(EASTERN).format(DateTimeFormatter.ofPattern("EEEE h:mm a", Locale.US))} ET"
        }
        meeting.heading?.let { return "Convenes $it" }
        return "Meets ${app.floor.android.model.Formats.dayText(meeting.date) ?: meeting.date}"
    }

    /** A measure named in a Senate program that Floor has a page for: where its label sits, and its bill. */
    data class Link(val start: Int, val end: Int, val billId: String)

    /** Every place the program names one of [items] with a bill id, in order; the text is left verbatim. */
    fun links(program: String, items: List<ScheduleItem>): List<Link> = items.flatMap { item ->
        val id = item.billId ?: return@flatMap emptyList()
        buildList {
            var from = 0
            while (true) {
                val at = program.indexOf(item.label, from)
                if (at < 0 || item.label.isEmpty()) break
                add(Link(at, at + item.label.length, id))
                from = at + item.label.length
            }
        }
    }.sortedBy { it.start }

    private val EASTERN: ZoneId = ZoneId.of("America/New_York")

    private fun instant(text: String): Instant? = try {
        Instant.parse(text)
    } catch (_: java.time.format.DateTimeParseException) {
        null
    }
}
