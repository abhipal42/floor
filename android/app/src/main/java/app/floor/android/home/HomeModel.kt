package app.floor.android.home

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.api.Saved
import app.floor.android.model.Bill
import app.floor.android.model.Chamber
import app.floor.android.model.Delegation
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Member
import app.floor.android.model.MemberPosition
import app.floor.android.model.MemberVote
import app.floor.android.model.MembersElect
import app.floor.android.model.PartyLoyalty
import app.floor.android.model.RecentVote
import app.floor.android.model.SavedCopy
import app.floor.android.model.SeatRow
import app.floor.android.model.StateName
import app.floor.android.model.Topic
import app.floor.android.model.Vote
import app.floor.android.model.VoteState
import app.floor.android.store.FollowKind
import app.floor.android.store.Session
import app.floor.android.store.listItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.time.Instant

/** One card in the feed: a vote, and how each of your members voted on it. */
data class FeedItem(val vote: Vote, val measure: MeasureSummary? = null, val positions: List<MemberPosition> = emptyList()) {
    val id: String get() = vote.id
}

/** Why a card is in the Following feed beyond its member chips: a bill or topic you follow it is on. */
data class FollowMatch(val shown: String, val spoken: String)

/** What the Finals tab shows: everything the screen draws, so a test can draw any state. */
data class HomeState(
    val phase: Phase = Phase.Loading,
    val filter: Filter = Filter.ALL,
    /** The latest finals for [filter]'s chamber, newest first: "All". */
    val items: List<RecentVote> = emptyList(),
    /** Set while any of the feed is a saved copy rather than fresh. */
    val saved: SavedCopy? = null,
    /** A pull-to-refresh is running over a feed already on screen. */
    val refreshing: Boolean = false,
    /** "All" or "Following" (iOS `Scope`); defaults to Following once you follow anything. */
    val scope: Scope = Scope.YOURS,
    /** The votes of your members and of the bills and topics you follow, one card per vote. */
    val yours: List<FeedItem> = emptyList(),
    /** Anything to put in "Following": a member, a bill or a topic. */
    val followsAnything: Boolean = false,
    val followedBills: Set<String> = emptySet(),
    val followedTopics: Set<String> = emptySet(),
    val delegation: Delegation? = null,
    /** Your reps, minus any you hid: the delegation strip. */
    val strip: List<Member> = emptyList(),
    /** Each member's party loyalty, for the rings; a member whose record failed shows no figure. */
    val loyalty: Map<String, PartyLoyalty> = emptyMap(),
    /** Your seats with any changing hands: elects and undecided seats among them. */
    val seats: MembersElect = MembersElect(),
    /** "Couldn't load Cruz's votes." and the like. */
    val unavailableNote: String? = null,
    val billLimitNote: String? = null,
) {
    sealed interface Phase {
        data object Loading : Phase
        data object Loaded : Phase
        data class Failed(val message: String) : Phase
    }

    enum class Filter(val label: String, val chamber: Chamber?) {
        ALL("All", null),
        HOUSE("House", Chamber.HOUSE),
        SENATE("Senate", Chamber.SENATE),
    }

    enum class Scope { ALL, YOURS }

    /** The scope actually shown: "Following" needs something followed. */
    val shownScope: Scope get() = if (followsAnything) scope else Scope.ALL

    /** The feed for the scope: the latest finals carry your members' chips where your feed has them. */
    val scopedItems: List<FeedItem>
        get() = if (shownScope == Scope.YOURS) yours else annotate(items, yours)

    /** The feed under the chamber filter (filtered here too, so it stays right while a fetch is out). */
    val visibleItems: List<FeedItem>
        get() = filter.chamber?.let { c -> scopedItems.filter { it.vote.chamber == c } } ?: scopedItems

    /** The most recent final in the feed, for the split-flap board. */
    val latestFinal: FeedItem? get() = scopedItems.firstOrNull { it.vote.state == VoteState.FINAL }

    /** The strip's rows when a seat is changing hands. */
    val seatRows: List<SeatRow> get() = SeatRow.rows(strip, seats.elect, seats.pending)

    /** What an empty feed says. D.C. and the territories have no senators, so their Senate filter is empty by design. */
    val emptyFeedMessage: String
        get() {
            val d = delegation
            if (filter == Filter.SENATE && shownScope == Scope.YOURS && d != null && d.senators.isEmpty() &&
                yours.none { item -> item.positions.any { it.member.chamber == Chamber.SENATE } }
            ) return "${StateName.full(d.district.state)} has no senators, so there are no Senate votes to show."
            return "No recent votes in this chamber."
        }

    /** Why [item] is in the Following feed: the bills and topics you follow that it is on. */
    fun matches(item: FeedItem): List<FollowMatch> {
        val measure = item.measure ?: return emptyList()
        if (measure.kind != MeasureSummary.Kind.BILL) return emptyList()
        val found = mutableListOf<FollowMatch>()
        if (measure.id in followedBills) found += FollowMatch(measure.citation, "you follow ${measure.citation}")
        measure.policyArea?.takeIf { it in followedTopics }?.let { found += FollowMatch(it, "in $it, a topic you follow") }
        return found
    }

    companion object {
        /** The latest finals as cards, each carrying your members' positions where your feed has that vote. */
        fun annotate(recent: List<RecentVote>, yours: List<FeedItem>): List<FeedItem> {
            val byVote = yours.associateBy { it.vote.id }
            return recent.map { row ->
                val known = byVote[row.vote.id] ?: return@map FeedItem(row.vote, row.measure)
                known.copy(vote = row.vote, measure = known.measure ?: row.measure)
            }
        }

        /** Newest vote first; a vote with no timestamp last; ties by id, so the order is stable. */
        fun newestFirst(items: List<FeedItem>): List<FeedItem> = items.sortedWith(
            compareByDescending<FeedItem> { it.vote.occurredAtInstant ?: Instant.MIN }.thenByDescending { it.vote.id },
        )

        /**
         * Every member's rows grouped by vote, newest first: two senators on one roll call are one
         * card with both chips, in [order] (your reps, then the members you follow).
         */
        fun merge(records: List<Pair<Member, List<MemberVote>>>, order: List<String>): List<FeedItem> {
            val rank = order.withIndex().associate { it.value to it.index }
            val byVote = LinkedHashMap<String, FeedItem>()
            for ((member, rows) in records.sortedBy { rank[it.first.bioguideId] ?: Int.MAX_VALUE }) {
                for (row in rows) {
                    val position = MemberPosition(member, row.position, row.choice)
                    val existing = byVote[row.vote.id]
                    byVote[row.vote.id] = if (existing == null) {
                        FeedItem(row.vote, row.measure, listOf(position))
                    } else if (existing.positions.any { it.member.bioguideId == member.bioguideId }) {
                        existing
                    } else {
                        existing.copy(positions = existing.positions + position, measure = existing.measure ?: row.measure)
                    }
                }
            }
            return newestFirst(byVote.values.toList())
        }

        /** Your members' cards plus the votes on bills and in topics you follow, one card per vote. */
        fun combine(items: List<FeedItem>, extra: List<RecentVote>): List<FeedItem> {
            val byVote = LinkedHashMap(items.associateBy { it.vote.id })
            for (row in extra) {
                val known = byVote[row.vote.id]
                byVote[row.vote.id] = when {
                    known == null -> FeedItem(row.vote, row.measure)
                    known.measure == null -> known.copy(measure = row.measure)
                    known.measure.policyArea == null && row.measure?.id == known.measure.id -> known.copy(measure = known.measure.copy(policyArea = row.measure.policyArea))
                    else -> known
                }
            }
            return newestFirst(byVote.values.toList())
        }

        private fun list(names: List<String>) = if (names.size == 1) names[0] else names.dropLast(1).joinToString(", ") + " and " + names.last()

        fun unavailableNote(members: List<Member>, bills: List<String>): String? {
            val parts = mutableListOf<String>()
            val names = members.map { it.lastName }
            if (names.size == 1) parts += "Couldn't load ${names[0]}'s votes."
            if (names.size > 1) parts += "Couldn't load ${names.size} members' votes: ${list(names)}."
            if (bills.size == 1) parts += "Couldn't load ${bills[0]}."
            if (bills.size > 1) parts += "Couldn't load ${bills.size} bills: ${list(bills)}."
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" ")
        }
    }
}

/**
 * Finals (iOS `HomeModel`): the latest finals in both chambers or the one the filter picks, and
 * beside them "Following": the recent votes of your members (your reps unless hidden, then those you
 * follow), every vote on a bill you follow, and the latest finals in topics you follow, merged one
 * card per vote. Each part opens on its saved copy and revalidates; one that fails leaves the rest.
 *
 * Unlike iOS, which fetches only what a new follow adds, any change to what you follow reloads the
 * lot: simpler, and the requests are the same ones.
 */
class HomeModel(private val api: FloorApi, private val session: Session? = null) : ViewModel() {
    var state by mutableStateOf(HomeState(scope = if (session?.let { followsAnything(it) } == true) HomeState.Scope.YOURS else HomeState.Scope.ALL))
        private set

    /** Each member's recent votes, by Bioguide ID: the Following tab's latest-vote chip. */
    var records by mutableStateOf<Map<String, List<MemberVote>>>(emptyMap())
        private set

    /** Each followed bill as `GET /v1/bills/{id}` last gave it. */
    var billRecords by mutableStateOf<Map<String, Bill>>(emptyMap())
        private set

    private var job: Job? = null
    private var loadedKey: String? = null

    private val limit = 40
    private val perMember = 25

    /** How many followed bills the feed fetches, one request each: the most recently followed. */
    private val billFetchLimit = 20

    /** Changes when what you follow or the chamber does: the tab reloads on it. */
    val syncKey: String
        get() {
            val s = session ?: return state.filter.name
            val follows = s.follows.state
            return listOf(s.yourMembers.map { it.bioguideId }, follows.followedBillIds, follows.followedTopics, listOfNotNull(s.delegation?.district?.name))
                .joinToString("|") { it.sorted().joinToString(",") } + "|" + state.filter.name
        }

    /** The tab appeared, or what you follow changed: load unless a fresh feed for it is already up. */
    fun appear() {
        // Finals and Following both ask; a load for the same follows already out is enough.
        if (job?.isActive == true && launchedKey == syncKey) return
        if (state.phase != HomeState.Phase.Loaded || state.saved != null || loadedKey != syncKey) reload()
    }

    fun reload() = launchLoad(refresh = false)

    fun refresh() = launchLoad(refresh = true)

    fun select(filter: HomeState.Filter) {
        if (filter == state.filter) return
        state = state.copy(filter = filter)
        launchLoad(refresh = false)
    }

    fun selectScope(scope: HomeState.Scope) {
        state = state.copy(scope = scope)
    }

    private var launchedKey: String? = null

    private fun launchLoad(refresh: Boolean) {
        launchedKey = syncKey
        job?.cancel()
        job = viewModelScope.launch { load(refresh) }
    }

    private fun followsAnything(s: Session): Boolean =
        s.yourMembers.isNotEmpty() || s.follows.state.followedBillIds.isNotEmpty() || s.follows.state.followedTopics.isNotEmpty()

    /** One pass: saved copies, then the network. Public for tests, which drive it without a scope. */
    suspend fun load(refresh: Boolean = false) {
        val key = syncKey
        val chamber = state.filter.chamber
        val members = session?.yourMembers.orEmpty()
        val follows = session?.follows?.state
        val billIds = follows?.entries(FollowKind.BILL)?.sortedByDescending { it.followedAt }?.take(billFetchLimit)?.map { it.id }?.toSet()
            ?.let { newest -> follows.followedBillIds.filter { it in newest } }.orEmpty()
        val topics = follows?.followedTopics?.mapNotNull { Topic.canonical(it) }.orEmpty()
        val anything = members.isNotEmpty() || follows?.followedBillIds?.isNotEmpty() == true || topics.isNotEmpty()
        val delegation = session?.delegation
        val onScreen = state.phase == HomeState.Phase.Loaded
        state = state.copy(
            followsAnything = anything,
            followedBills = follows?.followedBillIds?.toSet().orEmpty(),
            followedTopics = follows?.followedTopics?.toSet().orEmpty(),
            delegation = delegation,
            strip = follows?.visibleReps(session.reps).orEmpty(),
            billLimitNote = follows?.let { f ->
                val rest = f.followedBillIds.size - billIds.size
                if (rest > 0) "Finals has votes on your $billFetchLimit most recently followed bills. The other $rest ${if (rest == 1) "is" else "are"} listed as last saved." else null
            },
        )
        if (refresh) state = state.copy(refreshing = true)
        if (!onScreen) state = state.copy(phase = HomeState.Phase.Loading, saved = null)

        // The saved copies go up first, unless this is a refresh of a feed already showing.
        val savedRecent = api.savedRecentVotes(chamber, limit)
        if (!refresh && !onScreen) {
            val savedRecords = members.mapNotNull { m -> api.savedMemberVotes(m.bioguideId, perMember)?.let { m to it } }
            val savedBills = billIds.mapNotNull { api.savedBill(it) }
            val savedTopics = if (topics.isEmpty()) null else api.savedRecentVotes(chamber, limit, topics)
            val any = listOfNotNull<Saved<*>>(savedRecent, savedTopics) + savedRecords.map { it.second } + savedBills
            if (any.isNotEmpty() && (savedRecent != null || !anything || savedRecords.isNotEmpty() || savedBills.isNotEmpty())) {
                records = savedRecords.associate { it.first.bioguideId to it.second.value.votes }
                billRecords = savedBills.associate { it.value.id to it.value }
                state = state.copy(
                    phase = HomeState.Phase.Loaded,
                    items = savedRecent?.value?.votes.orEmpty(),
                    yours = feed(members, billIds, savedTopics?.value?.votes.orEmpty()),
                    saved = SavedCopy(any.minOf { it.fetchedAt }, SavedCopy.Status.REFRESHING),
                )
            }
        }

        var fellBack: Instant? = null
        var offline = false
        fun <T> fallback(e: FloorApiError, saved: Saved<T>?): T? {
            if (saved != null) {
                fellBack = fellBack?.let { minOf(it, saved.fetchedAt) } ?: saved.fetchedAt
                offline = offline || e is FloorApiError.Transport
            }
            return saved?.value
        }
        suspend fun <T> attempt(saved: () -> Saved<T>?, fetch: suspend () -> T): Result<T> = try {
            Result.success(fetch())
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            fallback(e, saved())?.let { Result.success(it) } ?: Result.failure(e)
        }

        val outcome = coroutineScope {
            val votes = members.map { m -> async { m to attempt({ api.savedMemberVotes(m.bioguideId, perMember) }) { api.memberVotes(m.bioguideId, perMember) } } }
            val bills = billIds.map { id -> async { id to attempt({ api.savedBill(id) }) { api.bill(id) } } }
            val topicVotes = async { if (topics.isEmpty()) Result.success(emptyList()) else attempt({ api.savedRecentVotes(chamber, limit, topics) }) { api.recentVotes(chamber, limit, topics) }.map { it.votes } }
            val recent = async { attempt({ savedRecent }) { api.recentVotes(chamber, limit) } }
            Outcome(votes.awaitAll(), bills.awaitAll(), topicVotes.await(), recent.await())
        }
        val loadedVotes = outcome.votes.mapNotNull { (m, r) -> r.getOrNull()?.let { m.bioguideId to it.votes } }.toMap()
        val loadedBills = outcome.bills.mapNotNull { (id, r) -> r.getOrNull()?.let { id to it } }.toMap()
        val failedMembers = outcome.votes.filter { it.second.isFailure }.map { it.first }
        val failedBills = outcome.bills.filter { it.second.isFailure }.map { it.first }
        val recent = outcome.recent.getOrNull()
        val firstError = (outcome.votes.map { it.second } + outcome.bills.map { it.second } + outcome.recent)
            .firstNotNullOfOrNull { it.exceptionOrNull() }
        // Nothing you follow came, and nothing to show instead: that is the feed failing.
        val nothing = (anything && loadedVotes.isEmpty() && loadedBills.isEmpty() && recent == null && (members.isNotEmpty() || billIds.isNotEmpty())) ||
            (!anything && recent == null)
        if (nothing) {
            state = when {
                onScreen || state.phase == HomeState.Phase.Loaded -> state.copy(refreshing = false, saved = state.saved?.let { it.copy(status = if (firstError is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED) })
                else -> state.copy(phase = HomeState.Phase.Failed(firstError?.message ?: "Couldn't load recent votes."), refreshing = false, saved = null)
            }
            return
        }
        records = loadedVotes
        billRecords = loadedBills
        // The saved rows follow the bills, so the Following tab reads right.
        session?.follows?.update { s -> loadedBills.values.fold(s) { acc, bill -> acc.refresh(listItem(bill, acc.entries(FollowKind.BILL).firstOrNull { it.id == bill.id }?.bill)) } }
        val citations = follows?.followedBills?.associate { it.id to it.citation }.orEmpty()
        state = state.copy(
            phase = HomeState.Phase.Loaded,
            items = recent?.votes ?: state.items,
            yours = feed(members, billIds, outcome.topics.getOrNull() ?: emptyList()),
            saved = fellBack?.let { SavedCopy(it, if (offline) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED) },
            refreshing = false,
            unavailableNote = HomeState.unavailableNote(failedMembers, failedBills.map { citations[it] ?: it }),
        )
        loadedKey = key
        loadLoyalty(members)
        loadSeats(delegation)
    }

    private data class Outcome(
        val votes: List<Pair<Member, Result<app.floor.android.model.MemberVotes>>>,
        val bills: List<Pair<String, Result<Bill>>>,
        val topics: Result<List<RecentVote>>,
        val recent: Result<app.floor.android.model.RecentVotes>,
    )

    private fun feed(members: List<Member>, billIds: List<String>, topicRows: List<RecentVote>): List<FeedItem> {
        val memberItems = HomeState.merge(members.mapNotNull { m -> records[m.bioguideId]?.let { m to it } }, members.map { it.bioguideId })
        val billVotes = billIds.mapNotNull { billRecords[it] }.flatMap { bill -> bill.votes.map { RecentVote(it, bill.measure) } }
        return HomeState.combine(memberItems, billVotes + topicRows)
    }

    /** Best-effort: a record that fails to refresh falls back to its saved ring. */
    private suspend fun loadLoyalty(members: List<Member>) {
        val found = coroutineScope {
            members.map { m ->
                async {
                    val detail = try {
                        api.member(m.bioguideId)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: FloorApiError) {
                        api.savedMember(m.bioguideId)?.value
                    }
                    detail?.let { m.bioguideId to it.partyLoyalty }
                }
            }.awaitAll().filterNotNull()
        }
        state = state.copy(loyalty = state.loyalty + found)
    }

    /** Members-elect and undecided seats among your own seats; best effort, saved then fresh. */
    private suspend fun loadSeats(delegation: Delegation?) {
        val district = delegation?.district
        if (district == null) {
            state = state.copy(seats = MembersElect())
            return
        }
        val found = try {
            api.membersElect(district.state)
        } catch (e: CancellationException) {
            throw e
        } catch (_: FloorApiError) {
            api.savedMembersElect(district.state)?.value
        } ?: return
        state = state.copy(seats = found.seats(district.state, district.district))
    }
}
