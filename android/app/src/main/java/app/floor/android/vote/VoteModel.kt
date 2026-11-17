package app.floor.android.vote

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.Bill
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Member
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
    /**
     * The bill this vote was on, loaded after the vote so the screen never waits on it: the bill
     * card's level of six. Null for a nomination, or a bill that could not be had fresh or saved.
     */
    val bill: Bill? = null,
    /** Your members (reps unless hidden, then those you follow): "Your members" and its other-chamber note. */
    val members: List<Member> = emptyList(),
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
 * [members] are your members, their positions asked for in the same request (`?members=`, at most
 * ten). With none (no district, nobody followed) the screen draws no "Your members", as iOS.
 *
 * The bill the vote was on follows, best-effort (fresh, else saved), for the card's level of six;
 * until it lands the card names the bill, as iOS does.
 */
class VoteModel(
    private val api: FloorApi,
    private val voteId: String,
    members: List<Member> = emptyList(),
) : ViewModel() {
    private val memberIds = members.take(10).map { it.bioguideId }

    var state by mutableStateOf(VoteScreenState(members = members))
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
                bill = billId(saved.value)?.let { api.savedBill(it)?.value } ?: state.bill,
            )
        }
        try {
            val fresh = api.vote(voteId, memberIds)
            state = state.copy(phase = VoteScreenState.Phase.Loaded(fresh), saved = null)
            val billId = billId(fresh) ?: return
            val bill = try {
                api.bill(billId)
            } catch (e: CancellationException) {
                throw e
            } catch (_: FloorApiError) {
                api.savedBill(billId)?.value
            }
            if (bill != null) state = state.copy(bill = bill)
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

private fun billId(detail: VoteDetail): String? =
    detail.measure?.takeIf { it.kind == MeasureSummary.Kind.BILL }?.id

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
