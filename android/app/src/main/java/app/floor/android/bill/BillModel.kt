package app.floor.android.bill

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.api.Saved
import app.floor.android.model.Bill
import app.floor.android.model.BillAnalysis
import app.floor.android.model.BillShare
import app.floor.android.model.Delegation
import app.floor.android.model.Member
import app.floor.android.model.MemberPosition
import app.floor.android.model.Position
import app.floor.android.model.Vote
import app.floor.android.model.MemberContact
import app.floor.android.model.SavedCopy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** The AI section at the top of the bill, which loads after the bill itself (iOS `AnalysisPhase`). */
sealed interface AnalysisPhase {
    /** Asked for and not answered yet: the skeleton. */
    data object Loading : AnalysisPhase

    /** No analysis, but the bill has a CRS summary: the section is left out, promising nothing. */
    data object Hidden : AnalysisPhase

    /** No analysis and no CRS summary to write one from: the "No summary yet" card. */
    data object NoSummary : AnalysisPhase

    data class Loaded(val analysis: AIAnalysis) : AnalysisPhase

    /** The request failed with nothing saved to fall back to. */
    data object Failed : AnalysisPhase

    companion object {
        /** What a response (null: "none yet") draws for [bill]. */
        fun of(bill: Bill, analysis: BillAnalysis?): AnalysisPhase {
            val shown = analysis?.let(AIAnalysis::of)
            if (shown != null && shown.groups.isNotEmpty()) return Loaded(shown)
            return if (bill.summary.isNullOrBlank()) NoSummary else Hidden
        }
    }
}

/** One of your members on a bill: the latest roll call in their chamber, and their position on it. */
data class MemberOnBill(val member: Member, val vote: Vote?, val position: Position?, val choice: String?)

/** What the bill screen shows: everything it draws, so a test can draw any state. */
data class BillScreenState(
    val phase: Phase = Phase.Loading,
    val saved: SavedCopy? = null,
    val analysis: AnalysisPhase = AnalysisPhase.Loading,
    /** The citation chip whose paragraph is open, by [AIAnalysis.Citation.id]. One at a time. */
    val openCitation: String? = null,
    /** On this week's floor list, if it is: the "On the floor this week" banner. */
    val listing: FloorListing? = null,
    /** What Share sends, from the API; null until it answers (Share then builds its own). */
    val share: BillShare? = null,
    /** "Your members on this bill": each of your members and how they voted on its latest roll call in their chamber. */
    val yourMembers: List<MemberOnBill> = emptyList(),
) {
    sealed interface Phase {
        data object Loading : Phase
        data class Loaded(val bill: Bill) : Phase
        data class Failed(val message: String) : Phase
    }

    /** The bill's facts as Speak up and the fallback share line say them. */
    fun facts(bill: Bill): BillFacts = BillFacts.of(bill, listing)

    /** The link and line Share sends: the API's, else [ShareFallback]'s. */
    fun shareText(bill: Bill): String {
        val url = share?.url ?: ShareFallback.url(bill)
        val text = share?.text ?: ShareFallback.text(facts(bill))
        return "$text $url"
    }
}

/**
 * Loads one bill (iOS `BillScreenModel`): the saved copy first, marked as saved, then the network.
 * Then, best-effort, its AI analysis, this week's schedule (for the banner) and its share line,
 * each fresh or else saved; a bill whose extras can't be had still shows.
 *
 * [delegation] is who Speak up writes to; without one the sheet says to set a district first. [members]
 * are your members: each one's position on the bill's latest roll call in their chamber is asked
 * for best-effort (`?members=`), for "Your members on this bill".
 */
class BillModel(
    private val api: FloorApi,
    private val billId: String,
    val delegation: Delegation? = null,
    private val members: List<Member> = emptyList(),
) : ViewModel() {
    var state by mutableStateOf(BillScreenState())
        private set

    private var job: Job? = null

    fun appear() {
        if (state.phase !is BillScreenState.Phase.Loaded || state.saved != null) reload()
    }

    fun reload() {
        job?.cancel()
        job = viewModelScope.launch { load() }
    }

    /** The AI section's Try again: back to the skeleton straight away, then the whole load again. */
    fun retryAnalysis() {
        state = state.copy(analysis = AnalysisPhase.Loading, openCitation = null)
        reload()
    }

    /** Opens a citation's paragraph, or closes it if it is the one already open. */
    fun toggleCitation(id: String) {
        state = state.copy(openCitation = if (state.openCitation == id) null else id)
    }

    /** A member's office contact, for Speak up: fresh, else saved. */
    suspend fun contact(member: Member): MemberContact? = try {
        api.member(member.bioguideId).contact
    } catch (e: CancellationException) {
        throw e
    } catch (_: FloorApiError) {
        api.savedMember(member.bioguideId)?.value?.contact
    }

    suspend fun load() {
        val onScreen = state.phase is BillScreenState.Phase.Loaded
        if (!onScreen) state = state.copy(phase = BillScreenState.Phase.Loading, analysis = AnalysisPhase.Loading, saved = null)
        val saved = api.savedBill(billId)
        if (saved != null && !onScreen) {
            state = state.copy(
                phase = BillScreenState.Phase.Loaded(saved.value),
                saved = SavedCopy(saved.fetchedAt, SavedCopy.Status.REFRESHING),
            )
            applySavedExtras(saved.value)
        }
        val fresh = try {
            api.bill(billId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            state = when {
                saved != null -> state.copy(
                    phase = BillScreenState.Phase.Loaded(saved.value),
                    saved = SavedCopy(
                        saved.fetchedAt,
                        if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED,
                    ),
                    // A saved bill whose analysis was never saved either: say so rather than spin.
                    analysis = if (state.analysis == AnalysisPhase.Loading) AnalysisPhase.Failed else state.analysis,
                )
                onScreen -> state
                else -> state.copy(phase = BillScreenState.Phase.Failed(e.message ?: "Couldn't load this bill."), saved = null)
            }
            return
        }
        state = state.copy(phase = BillScreenState.Phase.Loaded(fresh), saved = null)
        loadAnalysis(fresh)
        val schedule = bestEffort({ api.schedule() }, { api.savedSchedule() })
        val share = bestEffort({ api.billShare(billId) }, { api.savedBillShare(billId) })
        state = state.copy(
            listing = schedule?.let { FloorListing.of(it, billId) } ?: state.listing,
            share = share ?: state.share,
        )
        loadYourMembers(fresh)
    }

    private suspend fun loadYourMembers(bill: Bill) {
        if (members.isEmpty()) return
        // Newest first, so the first per chamber is its latest.
        val latest = bill.votes.groupBy { it.chamber }.mapValues { it.value.first() }
        val positions = mutableMapOf<String, MemberPosition>()
        for (vote in latest.values) {
            val ids = members.filter { it.chamber == vote.chamber }.map { it.bioguideId }.take(10)
            if (ids.isEmpty()) continue
            bestEffort({ api.vote(vote.id, ids) }, { api.savedVote(vote.id, ids) })?.positions?.forEach { positions[it.member.bioguideId] = it }
        }
        state = state.copy(yourMembers = members.map { m ->
            val found = positions[m.bioguideId]
            MemberOnBill(m, latest[m.chamber], found?.position, found?.choice)
        })
    }

    /** The saved pass: whatever of the analysis, schedule and share line was saved. */
    private fun applySavedExtras(bill: Bill) {
        val analysis = api.savedBillAnalysis(billId)
        state = state.copy(
            analysis = analysis?.let { AnalysisPhase.of(bill, it.value) } ?: state.analysis,
            listing = api.savedSchedule()?.value?.let { FloorListing.of(it, billId) },
            share = api.savedBillShare(billId)?.value,
        )
    }

    private suspend fun loadAnalysis(bill: Bill) {
        val result: Result<BillAnalysis?> = try {
            Result.success(api.billAnalysis(billId))
        } catch (e: CancellationException) {
            throw e
        } catch (e: FloorApiError) {
            api.savedBillAnalysis(billId)?.let { Result.success(it.value) } ?: Result.failure(e)
        }
        result.onSuccess { found ->
            val next = AnalysisPhase.of(bill, found)
            // An open chip belongs to the analysis it was opened on.
            val keepOpen = next == state.analysis
            state = state.copy(analysis = next, openCitation = if (keepOpen) state.openCitation else null)
        }.onFailure {
            // A refresh that fails keeps whatever the screen already shows.
            if (state.analysis == AnalysisPhase.Loading) state = state.copy(analysis = AnalysisPhase.Failed)
        }
    }

    private suspend fun <T> bestEffort(fresh: suspend () -> T, saved: () -> Saved<T>?): T? = try {
        fresh()
    } catch (e: CancellationException) {
        throw e
    } catch (_: FloorApiError) {
        saved()?.value
    }
}
