package app.floor.android.store

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.floor.android.model.Bill
import app.floor.android.model.BillListItem
import app.floor.android.model.LossyList
import app.floor.android.model.Member
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.ZoneId

// What you follow, kept on the phone only (iOS `Follows.swift`). No account and no address: your
// reps are not in here (they come from the saved district), only the ids of any you hid.
//
// Left out on Android, by design for now: the alert switches and "A vote opened" (alerts need push,
// which needs FCM: not in this app yet), and the iCloud merge with its tombstones (no cloud sync).

@Serializable
enum class FollowKind {
    @SerialName("member") MEMBER,
    @SerialName("bill") BILL,
    @SerialName("topic") TOPIC,
}

/** One thing you follow; a member or bill carries its public record as last seen, to name it offline. */
@Serializable
data class FollowEntry(
    val kind: FollowKind,
    val id: String,
    /** Epoch milliseconds. */
    val followedAt: Long = 0,
    val member: Member? = null,
    val bill: BillListItem? = null,
) {
    val key: String get() = "${kind.name.lowercase()}:$id"
}

object LossyEntries : LossyList<FollowEntry>(FollowEntry.serializer())

/** Everything the Following tab keeps: what you follow, in your order, and which of your reps you hid. */
@Serializable
data class FollowState(
    /** Display order per kind; following adds to the front. */
    @Serializable(with = LossyEntries::class) val entries: List<FollowEntry> = emptyList(),
    /** Bioguide IDs of your own reps you hid: they are your district, hidden rather than unfollowed. */
    val hiddenReps: List<String> = emptyList(),
) {
    fun contains(kind: FollowKind, id: String) = entries.any { it.kind == kind && it.id == id }

    fun entries(kind: FollowKind) = entries.filter { it.kind == kind }

    /** Follows something, newest first; already followed, it stays put and its record is refreshed. */
    fun follow(kind: FollowKind, id: String, member: Member? = null, bill: BillListItem? = null, at: Long = System.currentTimeMillis()): FollowState {
        val index = entries.indexOfFirst { it.kind == kind && it.id == id }
        if (index >= 0) {
            val old = entries[index]
            return copy(entries = entries.toMutableList().also { it[index] = old.copy(member = member ?: old.member, bill = bill ?: old.bill) })
        }
        return copy(entries = listOf(FollowEntry(kind, id, at, member, bill)) + entries)
    }

    fun unfollow(kind: FollowKind, id: String) = copy(entries = entries.filterNot { it.kind == kind && it.id == id })

    /** Moves one of a kind's entries by [by] places within that kind; other kinds keep theirs. */
    fun move(kind: FollowKind, id: String, by: Int): FollowState {
        val mine = entries(kind).toMutableList()
        val from = mine.indexOfFirst { it.id == id }
        if (from < 0) return this
        val to = (from + by).coerceIn(0, mine.size - 1)
        mine.add(to, mine.removeAt(from))
        val next = mine.iterator()
        return copy(entries = entries.map { if (it.kind == kind) next.next() else it })
    }

    // Members

    /** Followed members with a record, in your order. */
    val followedMembers: List<Member> get() = entries(FollowKind.MEMBER).mapNotNull { it.member }

    fun isFollowing(member: String) = contains(FollowKind.MEMBER, member)

    // Bills

    val followedBills: List<BillListItem> get() = entries(FollowKind.BILL).mapNotNull { it.bill }

    val followedBillIds: List<String> get() = entries(FollowKind.BILL).map { it.id }

    fun isFollowingBill(id: String) = contains(FollowKind.BILL, id)

    /** A fresher row for a bill you follow; a bill you don't is left alone. */
    fun refresh(bill: BillListItem): FollowState {
        val index = entries.indexOfFirst { it.kind == FollowKind.BILL && it.id == bill.id }
        if (index < 0) return this
        return copy(entries = entries.toMutableList().also { it[index] = it[index].copy(bill = bill) })
    }

    // Topics

    val followedTopics: List<String> get() = entries(FollowKind.TOPIC).map { it.id }

    fun isFollowingTopic(name: String) = contains(FollowKind.TOPIC, name)

    // Your reps

    fun isHidden(rep: String) = rep in hiddenReps

    fun setHidden(rep: String, hidden: Boolean) = copy(hiddenReps = hiddenReps.filterNot { it == rep } + if (hidden) listOf(rep) else emptyList())

    /** After "Change address": the old reps' hidden flags would name the old district. */
    fun forgetReps(ids: List<String>) = copy(hiddenReps = hiddenReps.filterNot { it in ids })

    fun visibleReps(reps: List<Member>) = reps.filter { !isHidden(it.bioguideId) }

    /** Followed members who are not your reps: the Following group on the tab. */
    fun followed(reps: List<Member>): List<Member> {
        val ids = reps.map { it.bioguideId }.toSet()
        return followedMembers.filter { it.bioguideId !in ids }
    }

    /**
     * Your reps (minus any you hid) then everyone you follow, without repeats: who "your members"
     * means in the feed, on the vote and bill screens. A rep is a rep, never also a followed member.
     */
    fun yourMembers(reps: List<Member>): List<Member> =
        (visibleReps(reps) + followed(reps)).distinctBy { it.bioguideId }

    /** Your district was just found: anyone you followed who is one of its members is a rep now. */
    fun adoptReps(ids: List<String>) = copy(entries = entries.filterNot { it.kind == FollowKind.MEMBER && it.id in ids })
}

/** Where [FollowState] is kept between launches. */
interface FollowStore {
    fun loadFollows(): FollowState
    fun saveFollows(state: FollowState)
}

class InMemoryFollowStore(private var stored: FollowState = FollowState()) : FollowStore {
    override fun loadFollows() = stored
    override fun saveFollows(state: FollowState) {
        stored = state
    }
}

/** The follow list as the screens see it: the state, saved on every change. */
class Follows(private val store: FollowStore) {
    var state by mutableStateOf(store.loadFollows())
        private set

    fun update(change: (FollowState) -> FollowState) {
        val next = change(state)
        if (next == state) return
        state = next
        store.saveFollows(next)
    }

    fun toggle(member: Member) = update {
        if (it.isFollowing(member.bioguideId)) it.unfollow(FollowKind.MEMBER, member.bioguideId)
        else it.follow(FollowKind.MEMBER, member.bioguideId, member = member)
    }

    fun toggle(bill: BillListItem) = update {
        if (it.isFollowingBill(bill.id)) it.unfollow(FollowKind.BILL, bill.id) else it.follow(FollowKind.BILL, bill.id, bill = bill)
    }

    fun toggleTopic(name: String) = update {
        if (it.isFollowingTopic(name)) it.unfollow(FollowKind.TOPIC, name) else it.follow(FollowKind.TOPIC, name)
    }

    /** A bill's fresh record: if you follow it, its saved row becomes this. */
    fun refresh(record: Bill) = update { state ->
        val saved = state.entries(FollowKind.BILL).firstOrNull { it.id == record.id }?.bill
        state.refresh(listItem(record, saved))
    }

    fun adopt(delegation: app.floor.android.model.Delegation) = update { it.adoptReps(delegation.memberIds) }
}

/**
 * A bill's record as its list row (iOS `BillListItem(bill:keeping:)`), keeping from [saved] what an
 * older response lacks. Stalled: unsettled with no action in 90 days, in Washington's calendar.
 */
fun listItem(bill: Bill, saved: BillListItem? = null, today: LocalDate = LocalDate.now(ZoneId.of("America/New_York"))): BillListItem {
    val stalled = when {
        bill.stage?.isSettled == true -> false
        else -> bill.latestAction?.on?.let { app.floor.android.model.Formats.day(it) }?.isBefore(today.minusDays(90)) ?: true
    }
    return BillListItem(
        id = bill.id, congress = bill.congress, type = bill.type, number = bill.number, citation = bill.citation,
        label = bill.label ?: saved?.label ?: bill.displayTitle, title = bill.title, policyArea = bill.policyArea,
        stageRaw = bill.stageRaw ?: saved?.stageRaw, stalled = stalled, latestAction = bill.latestAction,
        hasFloorVote = bill.votes.isNotEmpty(),
    )
}
