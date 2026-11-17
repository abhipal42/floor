package app.floor.android.widget

import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.home.RECORD_LIMIT
import app.floor.android.model.Chamber
import app.floor.android.model.Delegation
import app.floor.android.model.District
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Member
import app.floor.android.model.MemberVote
import app.floor.android.model.Position
import app.floor.android.model.StateName
import app.floor.android.model.Vote
import app.floor.android.model.VoteKind
import app.floor.android.model.VoteState
import app.floor.android.model.chip
import app.floor.android.model.isDelegate
import app.floor.android.model.outcomeWord
import app.floor.android.model.questionKind
import app.floor.android.model.title
import app.floor.android.store.FollowState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// What the two home-screen widgets show (iOS `WidgetFeed`, `WidgetSnapshot`, `WidgetText`), apart
// from Glance so it can be tested on the recorded responses. The widgets are drawing only.
//
// Left out on Android, by design for now: the medium widget's member pick (iOS's Edit Widget
// menu; here it is always your reps, else the first three you follow) and a separate saved
// snapshot (the widget reads and writes the app's own response cache instead, so a failed refresh
// shows what the app or the last refresh saw).

/** Who the widgets show: your district's members (minus any you hid), then everyone you follow. */
data class WidgetMembers(
    /** Seat only, never the county. Null with no district. */
    val district: District?,
    /** Your reps, not hidden: representative first, then senators by surname. */
    val reps: List<Member>,
    /** Members you follow, in your order. */
    val followed: List<Member>,
) {
    /** Reps then followed, without repeats: one row each. */
    val all: List<Member> get() = (reps + followed).distinctBy { it.bioguideId }

    val isEmpty: Boolean get() = all.isEmpty()

    companion object {
        fun of(delegation: Delegation?, follows: FollowState = FollowState()): WidgetMembers {
            val members = delegation?.members.orEmpty()
            return WidgetMembers(
                district = delegation?.district?.copy(countyFips = null),
                reps = follows.visibleReps(members).sortedWith(compareBy({ if (it.chamber == Chamber.HOUSE) 0 else 1 }, { it.lastName })),
                // A rep is a rep, also when followed: hidden wins (`FollowState.yourMembers`).
                followed = follows.followed(members),
            )
        }
    }
}

/** Everything the widgets draw: small shows [latestFinal], medium up to three of [rows] ([mediumRows]). */
data class WidgetSnapshot(
    val district: District?,
    val members: List<Member>,
    /** Which of [members] are your own reps (not hidden): the medium widget's rows. */
    val repIds: List<String>,
    val latestFinal: Final?,
    val rows: List<Row>,
    /** When the oldest of the records shown was fetched. */
    val fetchedAt: Instant,
) {
    data class Call(val member: Member, val position: Position, val choice: String?)

    /** The newest final vote any of your members took part in, and one of them on it. */
    data class Final(val vote: Vote, val measure: MeasureSummary?, val call: Call)

    /** One member and their most recent vote; [unavailable] when their record did not load at all. */
    data class Row(val member: Member, val latest: MemberVote?, val unavailable: Boolean = false)

    /** Your reps, up to three; with no reps, the first three you follow. */
    val mediumRows: List<Row>
        get() {
            val reps = rows.filter { it.member.bioguideId in repIds }
            return (reps.ifEmpty { rows }).take(MEDIUM_COUNT)
        }

    companion object {
        const val MEDIUM_COUNT = 3

        /** From each member's record, newest first as the API returns it; a member absent from [records] did not load. */
        fun make(who: WidgetMembers, records: Map<String, List<MemberVote>>, fetchedAt: Instant): WidgetSnapshot {
            val members = who.all
            val rows = members.map { Row(it, records[it.bioguideId]?.firstOrNull(), unavailable = it.bioguideId !in records) }
            var latest: Final? = null
            for (member in members) {
                for (row in records[member.bioguideId].orEmpty()) {
                    if (row.vote.state != VoteState.FINAL) continue
                    // Strictly newer only, so on a vote several members share, the first in order —
                    // your rep, then your senators, then whoever you follow — keeps it.
                    if (latest == null || isNewer(row.vote, latest.vote)) {
                        latest = Final(row.vote, row.measure, Call(member, row.position, row.choice))
                    }
                }
            }
            return WidgetSnapshot(who.district, members, who.reps.map { it.bioguideId }, latest, rows, fetchedAt)
        }

        /** Newer by when it closed; a vote with no timestamp is never newer than one with. */
        private fun isNewer(a: Vote, b: Vote): Boolean {
            val l = a.occurredAtInstant
            val r = b.occurredAtInstant
            return when {
                l != null && r != null -> l > r
                l != null -> true
                else -> false
            }
        }
    }
}

/** What one refresh produced. */
sealed interface WidgetContent {
    /** No district and nobody followed in the app yet. */
    data object NoMembers : WidgetContent
    data class Loaded(val snapshot: WidgetSnapshot) : WidgetContent
    /** Nothing loaded, fresh or saved. */
    data object Failed : WidgetContent
}

object WidgetFeed {
    /** Every 30 minutes at most, as iOS asks WidgetKit (`updatePeriodMillis`, Android's floor too). */
    const val REFRESH_MINUTES = 30

    /**
     * Each member's record through the route and the response cache the app uses: fetched fresh,
     * else the copy the app (or the last refresh) saved. A member with neither is a row marked
     * unavailable; only when no member has either does the load fail.
     */
    suspend fun load(api: FloorApi, members: WidgetMembers, now: Instant = Instant.now()): WidgetContent {
        if (members.isEmpty) return WidgetContent.NoMembers
        val gate = Semaphore(6)
        val fetched = coroutineScope {
            members.all.map { member ->
                async {
                    gate.withPermit {
                        val record = try {
                            api.memberVotes(member.bioguideId, RECORD_LIMIT).votes to now
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: FloorApiError) {
                            api.savedMemberVotes(member.bioguideId, RECORD_LIMIT)?.let { it.value.votes to it.fetchedAt }
                        }
                        member.bioguideId to record
                    }
                }
            }.map { it.await() }
        }
        val records = fetched.mapNotNull { (id, record) -> record?.let { id to it } }.toMap()
        if (records.isEmpty()) return WidgetContent.Failed
        val oldest = records.values.minOf { it.second }
        return WidgetContent.Loaded(WidgetSnapshot.make(members, records.mapValues { it.value.first }, oldest))
    }
}

/** The words the widgets print and speak (iOS `WidgetText`). */
object WidgetText {
    fun chip(position: Position, choice: String?): String = position.chip(choice)

    /** The measure's citation, else `Speaker ballot` or the kind of question. */
    fun citation(vote: Vote, measure: MeasureSummary?): String =
        measure?.citation ?: if (vote.kind == VoteKind.ELECTION) "Speaker ballot" else vote.questionKind

    /** `PASSED`, `AGREED`, `CONFIRMED`, `FAILED`; a Speaker ballot says whether it elected anyone. */
    fun resultWord(vote: Vote): String? {
        if (vote.kind == VoteKind.ELECTION) {
            if (vote.state != VoteState.FINAL) return null
            return if (vote.electedSpeaker == null) "NO ONE ELECTED" else "ELECTED"
        }
        return vote.outcomeWord
    }

    /** `Passed 295–128`, `Johnson elected 216`, `Jeffries led 212`, `Voting now`. */
    fun resultLine(vote: Vote): String {
        when (vote.state) {
            VoteState.SCHEDULED -> return "Scheduled"
            VoteState.OPEN -> return "Voting now"
            VoteState.FINAL -> {}
        }
        if (vote.kind == VoteKind.ELECTION) {
            vote.electedSpeaker?.let { return "${it.name} elected ${it.total}" }
            vote.leadingCandidate?.let { return "${it.name} led ${it.total}" }
            return "Speaker ballot"
        }
        val word = vote.outcomeWord?.let { it.take(1) + it.drop(1).lowercase() } ?: "Final"
        return "$word ${vote.totals.yea}–${vote.totals.nay}"
    }

    /** `Your members · TX-37` for your reps; `Your delegate · DC` for a lone delegate; else `Your members`. */
    fun header(snapshot: WidgetSnapshot): String {
        val shown = snapshot.mediumRows.map { it.member }
        val district = snapshot.district
        if (district == null || shown.isEmpty() || shown.map { it.bioguideId } != snapshot.repIds.take(WidgetSnapshot.MEDIUM_COUNT)) {
            return "Your members"
        }
        return header(shown, district)
    }

    fun header(members: List<Member>, district: District): String {
        val who = if (members.size == 1 && members[0].isDelegate) "Your ${members[0].title.lowercase()}" else "Your members"
        return "$who · ${district.name}"
    }

    /** Under a lone delegate's row: why there is one member, not two that failed to load. */
    fun loneMemberNote(snapshot: WidgetSnapshot): String? {
        val only = snapshot.mediumRows.map { it.member }.singleOrNull() ?: return null
        if (!only.isDelegate || snapshot.repIds != listOf(only.bioguideId)) return null
        return "${StateName.full(only.state)} has no senators. ${only.title}s vote on amendments, not on passage."
    }

    fun smallHeader(vote: Vote): String = "Final · ${vote.chamber.title}"

    /** Which colour a big number is printed in: yea, nay, or the text colour for a candidate. */
    enum class Side { YEA, NAY }

    data class Score(val value: Int, val label: String, val side: Side?)

    /** Yea and nay, or a Speaker ballot's two leaders; a one-candidate ballot has no right-hand number. */
    fun score(vote: Vote): Pair<Score, Score?> {
        if (vote.kind == VoteKind.ELECTION) {
            val top = vote.candidates.sortedByDescending { it.total }
            val first = top.firstOrNull()?.let { Score(it.total, it.name, null) } ?: Score(0, "", null)
            return first to top.getOrNull(1)?.let { Score(it.total, it.name, null) }
        }
        return Score(vote.totals.yea, "Yea", Side.YEA) to Score(vote.totals.nay, "Nay", Side.NAY)
    }

    val staleAfter: Duration = Duration.ofHours(2)

    /** `As of 3:40 PM` (earlier today) or `As of Nov 12`, once more than two hours old; else null. */
    fun asOf(fetchedAt: Instant, now: Instant, zone: ZoneId = ZoneId.systemDefault()): String? {
        if (Duration.between(fetchedAt, now) <= staleAfter) return null
        val at = fetchedAt.atZone(zone)
        val pattern = if (at.toLocalDate() == now.atZone(zone).toLocalDate()) "h:mm a" else "MMM d"
        return "As of ${at.format(DateTimeFormatter.ofPattern(pattern, Locale.US))}"
    }

    /** `Nov 11`. */
    fun day(vote: Vote, zone: ZoneId = ZoneId.systemDefault()): String? =
        vote.occurredAtInstant?.atZone(zone)?.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))

    /** `H.R. 1013 · Passed 295–128`, or why there is nothing. */
    fun detail(row: WidgetSnapshot.Row): String {
        if (row.unavailable) return "Couldn't load their votes"
        val latest = row.latest ?: return "No recorded votes yet"
        return "${citation(latest.vote, latest.measure)} · ${resultLine(latest.vote)}"
    }

    /** "Latest final, House. H.R. 1013. Passed, 295 to 128. Doggett voted nay." */
    fun smallLabel(final: WidgetSnapshot.Final): String {
        val vote = final.vote
        val parts = mutableListOf("Latest final, ${vote.chamber.title}", citation(vote, final.measure))
        if (vote.kind == VoteKind.ELECTION) {
            parts += resultLine(vote)
        } else {
            val word = resultWord(vote)?.let { it.take(1) + it.drop(1).lowercase() } ?: "Final"
            parts += "$word, ${vote.totals.yea} to ${vote.totals.nay}"
        }
        parts += spoken(final.call.member, final.call.position, final.call.choice)
        return parts.joinToString(". ") + "."
    }

    /** "Doggett voted nay on H.R. 1013, Passed 295 to 128, Nov 11." */
    fun rowLabel(row: WidgetSnapshot.Row, zone: ZoneId = ZoneId.systemDefault()): String {
        if (row.unavailable) return "${row.member.lastName}: couldn't load their votes."
        val latest = row.latest ?: return "${row.member.lastName} has no recorded votes yet."
        val what = citation(latest.vote, latest.measure)
        val result = resultLine(latest.vote).replace("–", " to ")
        return listOfNotNull("${spoken(row.member, latest.position, latest.choice)} on $what", result, day(latest.vote, zone))
            .joinToString(", ") + "."
    }

    private fun spoken(member: Member, position: Position, choice: String?): String {
        val name = member.lastName
        return when (position) {
            Position.YEA -> "$name voted yea"
            Position.NAY -> "$name voted nay"
            Position.PRESENT -> "$name voted present"
            Position.NOT_VOTING -> "$name did not vote"
            Position.CANDIDATE -> "$name voted for ${choice ?: "a candidate"}"
        }
    }
}
