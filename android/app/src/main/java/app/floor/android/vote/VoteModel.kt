package app.floor.android.vote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.SavedCopy
import app.floor.android.model.VoteDetail
import app.floor.android.model.VoteKindInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** What the vote screen shows: everything it draws, so a test can draw any state. */
data class VoteScreenState(
    val phase: Phase = Phase.Loading,
    /** Set while the vote on screen is a saved copy rather than fresh. */
    val saved: SavedCopy? = null,
    /** "What this vote is", open or folded. Open by default, as on iOS. */
    val explainerOpen: Boolean = true,
    /** Which party's squares the full roll shows; null for the first tab. */
    val rollParty: String? = null,
) {
    sealed interface Phase {
        data object Loading : Phase
        data class Loaded(val detail: VoteDetail) : Phase
        data class Failed(val message: String) : Phase
    }
}

/**
 * Loads one vote with its breakdown (iOS `VoteScreenModel`): the saved copy first, marked as saved,
 * then the network; a failed refresh leaves the saved copy up and says why.
 *
 * [memberIds] is your delegation, asked for in the same request. Android has no district until the
 * "Your three" phase, so the app passes none and the screen draws no "Your members" section, which
 * is what iOS draws for someone with no district and nobody followed.
 *
 * Not ported yet: the bill's level of six on the bill card, which needs the bill model and its
 * road to law (the Bills phase). Until then the card names the bill, as iOS does while the bill
 * has not loaded.
 */
class VoteModel(
    private val api: FloorApi,
    private val voteId: String,
    private val memberIds: List<String> = emptyList(),
) : ViewModel() {
    var state by mutableStateOf(VoteScreenState())
        private set

    private var job: Job? = null

    /** The screen appeared: load unless a fresh vote is already up (iOS `needsRefresh`). */
    fun appear() {
        if (state.phase !is VoteScreenState.Phase.Loaded || state.saved != null) reload()
    }

    /** "Try again", and the first load. */
    fun reload() {
        job?.cancel()
        job = viewModelScope.launch { load() }
    }

    fun toggleExplainer() {
        state = state.copy(explainerOpen = !state.explainerOpen)
    }

    fun selectRollParty(party: String) {
        state = state.copy(rollParty = party)
    }

    /** One pass: saved copy, then the network. Public for tests, which drive it without a scope. */
    suspend fun load() {
        // A vote already on screen stays there while it refreshes, rather than flashing a spinner.
        val onScreen = state.phase is VoteScreenState.Phase.Loaded
        if (!onScreen) state = state.copy(phase = VoteScreenState.Phase.Loading, saved = null)
        val saved = api.savedVote(voteId, memberIds)
        if (saved != null && !onScreen) {
            state = state.copy(
                phase = VoteScreenState.Phase.Loaded(saved.value),
                saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING),
            )
        }
        try {
            val fresh = api.vote(voteId, memberIds)
            state = state.copy(phase = VoteScreenState.Phase.Loaded(fresh), saved = null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            state = when {
                saved != null -> state.copy(
                    phase = VoteScreenState.Phase.Loaded(saved.value),
                    saved = SavedCopy(
                        saved.fetchedAt,
                        if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED,
                    ),
                )
                onScreen -> state
                else -> state.copy(phase = VoteScreenState.Phase.Failed(e.message ?: "Couldn't load this vote."), saved = null)
            }
        }
    }
}

/** What the "Kinds of vote" list shows. */
sealed interface VoteKindsState {
    data object Loading : VoteKindsState
    data class Loaded(val kinds: List<VoteKindInfo>) : VoteKindsState
    data object Failed : VoteKindsState
}

/** The "Kinds of vote" list, from `GET /v1/vote-kinds`: fresh, else the saved copy (iOS `voteKinds()`). */
class VoteKindsModel(private val api: FloorApi) : ViewModel() {
    var state by mutableStateOf<VoteKindsState>(VoteKindsState.Loading)
        private set

    fun appear() {
        if (state is VoteKindsState.Loaded) return
        viewModelScope.launch { load() }
    }

    suspend fun load() {
        state = VoteKindsState.Loading
        state = try {
            VoteKindsState.Loaded(api.voteKinds().kinds)
        } catch (e: CancellationException) {
            throw e
        } catch (_: FloorApiError) {
            api.savedVoteKinds()?.let { VoteKindsState.Loaded(it.value.kinds) } ?: VoteKindsState.Failed
        }
    }
}
