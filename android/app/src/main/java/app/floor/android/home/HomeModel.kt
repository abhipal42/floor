package app.floor.android.home

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.Chamber
import app.floor.android.model.RecentVote
import app.floor.android.model.SavedCopy
import app.floor.android.model.VoteState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** What the Finals tab shows: everything the screen draws, so a test can draw any state. */
data class HomeState(
    val phase: Phase = Phase.Loading,
    val filter: Filter = Filter.ALL,
    /** The latest finals for [filter]'s chamber, newest first. */
    val items: List<RecentVote> = emptyList(),
    /** Set while the feed is a saved copy rather than fresh. */
    val saved: SavedCopy? = null,
    /** A pull-to-refresh is running over a feed already on screen. */
    val refreshing: Boolean = false,
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

    /**
     * The feed under the chamber filter. The rows are fetched per chamber; filtering here as well
     * keeps the list right while a new chamber's fetch is in flight or has failed.
     */
    val visibleItems: List<RecentVote>
        get() = filter.chamber?.let { c -> items.filter { it.vote.chamber == c } } ?: items

    /** The most recent final in the feed, for the split-flap board. */
    val latestFinal: RecentVote? get() = items.firstOrNull { it.vote.state == VoteState.FINAL }

    /** What an empty feed says. */
    val emptyFeedMessage: String get() = "No recent votes in this chamber."
}

/**
 * Loads the Finals feed: the latest finals in both chambers, or the one the filter picks
 * (`GET /v1/votes`), as iOS `HomeModel` does for someone who follows nobody yet.
 *
 * The saved copy goes on screen first, marked as saved, then the network answer replaces it; a
 * failed refresh leaves the saved copy up and says why (iOS `revalidate`).
 */
class HomeModel(private val api: FloorApi) : ViewModel() {
    var state by mutableStateOf(HomeState())
        private set

    private var job: Job? = null

    /** How many finals to ask for. */
    private val limit = 40

    /**
     * The tab appeared: load unless a fresh feed is already up, so coming back to a feed that was
     * saved, failed or overtaken tries again (iOS `needsRefresh`).
     */
    fun appear() {
        if (state.phase != HomeState.Phase.Loaded || state.saved != null) reload()
    }

    /** Everything, from scratch: first load, "Try again". */
    fun reload() = launchLoad(refresh = false)

    /** Pull to refresh: the feed stays on screen while it runs. */
    fun refresh() = launchLoad(refresh = true)

    /** A new chamber fetches its own latest finals, rather than filtering both chambers' forty. */
    fun select(filter: HomeState.Filter) {
        if (filter == state.filter) return
        state = state.copy(filter = filter)
        launchLoad(refresh = false)
    }

    private fun launchLoad(refresh: Boolean) {
        job?.cancel()
        job = viewModelScope.launch { load(refresh) }
    }

    /** One pass: saved copy, then the network. Public for tests, which drive it without a scope. */
    suspend fun load(refresh: Boolean = false) {
        val chamber = state.filter.chamber
        val onScreen = state.phase == HomeState.Phase.Loaded
        if (refresh) state = state.copy(refreshing = true)
        if (!onScreen) state = state.copy(phase = HomeState.Phase.Loading, saved = null)

        // The saved copy goes up first, unless this is a refresh of a feed already showing; either
        // way it is what a failed refresh falls back to.
        val saved = api.savedRecentVotes(chamber, limit)
        if (saved != null && !refresh) {
            state = state.copy(
                phase = HomeState.Phase.Loaded,
                items = saved.value.votes,
                saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING),
            )
        }
        try {
            val fresh = api.recentVotes(chamber, limit)
            state = state.copy(phase = HomeState.Phase.Loaded, items = fresh.votes, saved = null, refreshing = false)
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            state = when {
                saved != null -> state.copy(
                    phase = HomeState.Phase.Loaded,
                    items = saved.value.votes,
                    saved = SavedCopy(
                        saved.fetchedAt,
                        if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED,
                    ),
                    refreshing = false,
                )
                // A feed already on screen (a refresh, or a new chamber) stays, filtered here.
                onScreen -> state.copy(refreshing = false)
                else -> state.copy(phase = HomeState.Phase.Failed(e.message ?: "Couldn't load recent votes."), refreshing = false)
            }
        }
    }
}
