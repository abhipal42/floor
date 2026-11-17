package app.floor.android.bills

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.BillListItem
import app.floor.android.model.Chamber
import app.floor.android.model.MembersElect
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import app.floor.android.model.SavedCopy
import app.floor.android.model.SearchResults
import app.floor.android.model.Topic
import app.floor.android.model.TopicFilter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One search over members, bills and topics (iOS `FollowSearchModel`): the Bills tab's and "+ Add"'s. */
data class SearchState(
    val query: String = "",
    /** Null for both chambers: narrows the members only. */
    val chamber: Chamber? = null,
    /** Members-elect and undecided seats matching the same text (`/v1/members?q=`); empty when that fails. */
    val seats: MembersElect = MembersElect(),
    /** The results for [searched]; kept while a newer search loads, so the list doesn't blink. */
    val results: SearchResults? = null,
    /** The text the results are for, or null before any search has finished. */
    val searched: String? = null,
    val loading: Boolean = false,
    val error: String? = null,
) {
    /** A search finished and found nothing at all. */
    val foundNothing: Boolean
        get() = searched != null && error == null && results != null && results.bills.isEmpty() &&
            (results.billNumber || (results.topics.isEmpty() && results.members.isEmpty() && seats.elect.isEmpty() && seats.pending.isEmpty()))

    /**
     * Whether to draw a Members group: words (not a bill number) that found something anywhere. It
     * says so when no member matched but topics or bills did, as the mock does.
     */
    val showsMembers: Boolean get() = results != null && !results.billNumber && !foundNothing && error == null

    /** The topics to list: none when the query was read as a bill number. */
    val topics: List<Topic> get() = if (results?.billNumber == true) emptyList() else results?.topics.orEmpty()

    val bills: List<BillListItem> get() = results?.bills.orEmpty()

    companion object {
        /** What is sent: the query trimmed, or null under two characters or over 100 (the API's bounds). */
        fun normalized(query: String): String? = query.trim().takeIf { it.length in 2..100 }
    }
}

/** What the Bills tab shows: the search, and the 32 topics. */
data class BillsState(
    val topics: Phase = Phase.Loading,
    val saved: SavedCopy? = null,
    val search: SearchState = SearchState(),
) {
    sealed interface Phase {
        data object Loading : Phase
        data class Loaded(val topics: List<Topic>) : Phase
        data class Failed(val message: String) : Phase
    }
}

/**
 * The Bills tab: one search over bills and topics (`GET /v1/search`, a short pause after the last
 * keystroke), and the 32 topics CRS sorts every bill into (`GET /v1/topics`), each opening its page.
 *
 * iOS reaches the same search and topics only through Following's "+ Add"; Android keeps them on
 * the Bills tab too, where a member row opens the member screen. "+ Add" is another of these.
 */
class BillsModel(private val api: FloorApi, private val debounceMillis: Long = 300) : ViewModel() {
    var state by mutableStateOf(BillsState())
        private set

    private var searchJob: Job? = null

    fun appear() {
        if (state.topics !is BillsState.Phase.Loaded || state.saved != null) viewModelScope.launch { loadTopics() }
    }

    fun reloadTopics() {
        viewModelScope.launch { loadTopics() }
    }

    suspend fun loadTopics() {
        val onScreen = state.topics is BillsState.Phase.Loaded
        if (!onScreen) state = state.copy(topics = BillsState.Phase.Loading, saved = null)
        val saved = api.savedTopics()
        if (saved != null && !onScreen) {
            state = state.copy(
                topics = BillsState.Phase.Loaded(saved.value.topics),
                saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING),
            )
        }
        state = try {
            state.copy(topics = BillsState.Phase.Loaded(api.topics().topics), saved = null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            when {
                saved != null -> state.copy(
                    topics = BillsState.Phase.Loaded(saved.value.topics),
                    saved = SavedCopy(
                        saved.fetchedAt,
                        if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED,
                    ),
                )
                onScreen -> state
                else -> state.copy(topics = BillsState.Phase.Failed(e.message ?: "Couldn't load the topics."))
            }
        }
    }

    /** A keystroke: the next one within the pause cancels this search before it sends anything. */
    fun type(query: String) {
        state = state.copy(search = state.search.copy(query = query))
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            if (SearchState.normalized(query) != null) delay(debounceMillis)
            searchNow()
        }
    }

    /** All, Senate or House: narrows the members, and searches again as a keystroke does. */
    fun selectChamber(chamber: Chamber?) {
        state = state.copy(search = state.search.copy(chamber = chamber))
        type(state.search.query)
    }

    /** Searches what is typed straight away, without the pause. */
    suspend fun searchNow() {
        val text = SearchState.normalized(state.search.query)
        if (text == null) {
            state = state.copy(search = SearchState(query = state.search.query, chamber = state.search.chamber))
            return
        }
        val chamber = state.search.chamber
        state = state.copy(search = state.search.copy(loading = true))
        state = try {
            val (found, seats) = coroutineScope {
                // Side by side: the elects ride on `/v1/members?q=`, and its failure is no failure.
                val elect = async {
                    try {
                        api.searchMembers(text, chamber)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: FloorApiError) {
                        null
                    }
                }
                api.search(text, chamber) to elect.await()
            }
            state.copy(
                search = state.search.copy(
                    results = found, seats = MembersElect(seats?.elect.orEmpty(), seats?.pending.orEmpty()),
                    searched = text, error = null, loading = false,
                ),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            state.copy(search = state.search.copy(loading = false, error = e.message ?: "Couldn't search right now."))
        }
    }
}

/** What a topic's page shows. */
data class TopicState(
    val name: String,
    val filter: TopicFilter = TopicFilter.ALL,
    val phase: Phase = Phase.Loading,
    /** Every page loaded so far for [filter], without repeats. */
    val bills: List<BillListItem> = emptyList(),
    /** The topic's counts as the latest page gave them. */
    val topic: Topic? = null,
    /** Null once the last page is in. */
    val nextCursor: String? = null,
    val loadingMore: Boolean = false,
    /** Set when a later page failed; the bills already shown stay. */
    val moreError: String? = null,
    val saved: SavedCopy? = null,
) {
    sealed interface Phase {
        data object Loading : Phase
        data object Loaded : Phase
        data class Failed(val message: String) : Phase
    }

    companion object {
        /** What an empty filter says: `No Health bills have become law this Congress yet.` */
        fun emptyMessage(topic: String, filter: TopicFilter): String = when (filter) {
            TopicFilter.ALL -> "No $topic bills this Congress yet."
            TopicFilter.MOVING -> "No $topic bills have had an action in the last 90 days."
            TopicFilter.LAW -> "No $topic bills have become law this Congress yet."
            TopicFilter.STALLED -> "No $topic bills have gone 90 days without an action."
        }

        /** A bill whose action moved between two page requests can appear on both; it is listed once. */
        fun unique(bills: List<BillListItem>): List<BillListItem> = bills.distinctBy { it.id }
    }
}

/**
 * A topic's bills, newest action first, a page at a time (iOS `TopicPageModel`), filtered All ·
 * Moving · Law · Stalled. The first page of each filter opens on its saved copy and revalidates;
 * later pages are fetched as the list reaches its end. A filter change or reload cancels whatever
 * is out for the list it replaces.
 */
class TopicModel(private val api: FloorApi, name: String) : ViewModel() {
    var state by mutableStateOf(TopicState(name))
        private set

    private var job: Job? = null

    fun appear() {
        if (state.phase != TopicState.Phase.Loaded || state.saved != null) reload()
    }

    fun reload() {
        job?.cancel()
        job = viewModelScope.launch { load() }
    }

    fun select(filter: TopicFilter) {
        if (filter == state.filter) return
        job?.cancel()
        state = TopicState(state.name, filter = filter)
        job = viewModelScope.launch { load() }
    }

    /** The list reached its end: the next page, appended. One at a time. */
    fun loadMore() {
        if (state.phase != TopicState.Phase.Loaded || state.nextCursor == null || state.loadingMore) return
        // While page 1 is a saved copy, its cursor may be stale: wait for the fresh page.
        if (state.saved?.status == SavedCopy.Status.REFRESHING) return
        job = viewModelScope.launch { more() }
    }

    suspend fun load() {
        val name = state.name
        val filter = state.filter
        val onScreen = state.phase == TopicState.Phase.Loaded
        if (!onScreen) state = state.copy(phase = TopicState.Phase.Loading, saved = null)
        val saved = api.savedTopicBills(name, filter)
        if (saved != null && !onScreen) {
            state = state.copy(
                phase = TopicState.Phase.Loaded, topic = saved.value.topic, bills = TopicState.unique(saved.value.bills),
                nextCursor = saved.value.nextCursor, saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING),
            )
        }
        state = try {
            val page = api.topicBills(name, filter)
            state.copy(
                phase = TopicState.Phase.Loaded, topic = page.topic, bills = TopicState.unique(page.bills),
                nextCursor = page.nextCursor, moreError = null, saved = null,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            when {
                saved != null -> state.copy(
                    saved = SavedCopy(
                        saved.fetchedAt,
                        if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED,
                    ),
                )
                onScreen -> state
                else -> state.copy(phase = TopicState.Phase.Failed(e.message ?: "Couldn't load $name."), saved = null)
            }
        }
    }

    suspend fun more() {
        val cursor = state.nextCursor ?: return
        state = state.copy(loadingMore = true, moreError = null)
        state = try {
            val page = api.topicBills(state.name, state.filter, cursor)
            state.copy(
                topic = page.topic, bills = TopicState.unique(state.bills + page.bills), nextCursor = page.nextCursor,
                loadingMore = false,
            )
        } catch (e: CancellationException) {
            state = state.copy(loadingMore = false)
            throw e
        } catch (e: FloorApiError) {
            state.copy(loadingMore = false, moreError = e.message ?: "Couldn't load more bills.")
        }
    }
}
