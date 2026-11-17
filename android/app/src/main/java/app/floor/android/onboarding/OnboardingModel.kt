package app.floor.android.onboarding

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.model.Delegation
import app.floor.android.model.Reps
import app.floor.android.model.StateName
import app.floor.android.model.isDelegate
import app.floor.android.model.title
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** A point, for one request and nothing else. */
data class Coordinate(val latitude: Double, val longitude: Double)

/** One fix from the phone, or null when none came in time. */
fun interface LocationProvider {
    suspend fun current(): Coordinate?
}

/** What the system said about location, as the onboarding screen asked it. */
enum class LocationAccess { PRECISE, APPROXIMATE, DENIED, SERVICES_OFF }

/** What onboarding shows: everything it draws, so a test can draw any state. */
data class OnboardingState(
    val address: String = "",
    val phase: Phase = Phase.Editing,
    val source: Source = Source.ADDRESS,
    val notice: Notice? = null,
    /** Set once location was used here; the mock then stops offering it. */
    val triedLocation: Boolean = false,
) {
    sealed interface Phase {
        data object Editing : Phase
        data object Looking : Phase
        data class Found(val reps: Reps) : Phase
        data class Failed(val message: String) : Phase
    }

    enum class Source { ADDRESS, LOCATION }

    /**
     * The banner above the address field (the LocApp mock), in Android's words. iOS's "restricted"
     * (Screen Time) has no Android counterpart, so it is left out.
     */
    enum class Notice(val title: String, val body: String, val opensSettings: Boolean = false) {
        LOCATION_OFF("Location is off for Floor", "Turn it on in Settings › Apps › Floor › Permissions, or type an address below.", opensSettings = true),
        SERVICES_OFF("Location is off on this phone", "Turn it on in Settings › Location, or type an address below."),
        OUTSIDE_US("That’s not in a U.S. district", "Floor covers the House and Senate, so it needs a U.S. location or address. Type one below."),
        APPROXIMATE(
            "Approximate location",
            "Precise location is off, so the point is only good to a few kilometres and can land in the next district over. Check these are yours.",
        ),
        UNAVAILABLE("Couldn’t find where you are", "Your phone didn’t get a fix in time. Try again, or type an address below."),
    }

    val failure: String? get() = (phase as? Phase.Failed)?.message

    /** "Use my location" is offered until used — or again after a fix that never came. */
    val offersLocation: Boolean
        get() = (phase == Phase.Editing || phase is Phase.Failed) && (!triedLocation || notice == Notice.UNAVAILABLE)

    /** The field hides only while a location lookup runs or shows its result. */
    val showsAddressField: Boolean
        get() = when (phase) {
            Phase.Looking, is Phase.Found -> source == Source.ADDRESS
            else -> true
        }

    companion object {
        /**
         * Why a result deals one card, not three: D.C. and the territories have a delegate and no
         * senators. Null for a state.
         */
        fun singleMemberNote(reps: Reps): String? {
            val member = reps.representative ?: return null
            if (reps.senators.isNotEmpty() || !member.isDelegate) return null
            val place = if (member.state == "DC") "D.C." else StateName.full(member.state)
            val office = member.title.lowercase()
            val article = if (office.first() in "aeiou") "an" else "a"
            return "One, not three: $place has $article $office in the House and no senators. " +
                "${article.replaceFirstChar { it.uppercase() }} $office can’t vote to pass a bill, so ${member.lastName}’s record is amendment votes."
        }
    }
}

/**
 * "Pull your three." (iOS `OnboardingModel`): the district from where you are or from an address,
 * who it resolves to, confirm or try again. The address lives only in the state while the screen is
 * open, a location only for one request; each goes to `/v1/reps` and nowhere else, never stored,
 * logged or cached, and not part of [Delegation].
 */
class OnboardingModel(
    private val api: FloorApi,
    private val location: LocationProvider,
    private val now: () -> Long = System::currentTimeMillis,
) : ViewModel() {
    var state by mutableStateOf(OnboardingState())
        private set

    /** Bumped by every lookup and every edit, so a result that lands after the person moved on is dropped. */
    private var generation = 0

    /** Typing again clears a failure and takes back a result that no longer matches the field. */
    fun type(address: String) {
        state = state.copy(address = address)
        if (state.phase is OnboardingState.Phase.Failed || state.phase is OnboardingState.Phase.Found) edit()
    }

    fun lookUp() = viewModelScope.launch { lookUpNow() }

    suspend fun lookUpNow() {
        if (state.phase == OnboardingState.Phase.Looking) return
        val query = state.address.trim()
        if (query.length < 5) {
            state = state.copy(phase = OnboardingState.Phase.Failed("Enter a street address, city and state."))
            return
        }
        val mine = ++generation
        state = state.copy(source = OnboardingState.Source.ADDRESS, notice = null, phase = OnboardingState.Phase.Looking)
        resolve(mine, outsideUS = null) { api.reps(query) }
    }

    /** The screen asked the system for location and got [access]: take one fix and look it up. */
    fun useLocation(access: LocationAccess) = viewModelScope.launch { useLocationNow(access) }

    suspend fun useLocationNow(access: LocationAccess) {
        if (state.phase == OnboardingState.Phase.Looking) return
        state = state.copy(triedLocation = true, notice = null)
        when (access) {
            LocationAccess.DENIED -> {
                state = state.copy(notice = OnboardingState.Notice.LOCATION_OFF, phase = OnboardingState.Phase.Editing)
                return
            }
            LocationAccess.SERVICES_OFF -> {
                state = state.copy(notice = OnboardingState.Notice.SERVICES_OFF, phase = OnboardingState.Phase.Editing)
                return
            }
            else -> {}
        }
        val mine = ++generation
        state = state.copy(source = OnboardingState.Source.LOCATION, phase = OnboardingState.Phase.Looking)
        val point = try {
            location.current()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        if (mine != generation) return
        if (point == null) {
            state = state.copy(source = OnboardingState.Source.ADDRESS, notice = OnboardingState.Notice.UNAVAILABLE, phase = OnboardingState.Phase.Editing)
            return
        }
        resolve(mine, outsideUS = OnboardingState.Notice.OUTSIDE_US) { api.reps(point.latitude, point.longitude) }
        if (mine == generation && state.phase is OnboardingState.Phase.Found && access == LocationAccess.APPROXIMATE) {
            state = state.copy(notice = OnboardingState.Notice.APPROXIMATE)
        }
    }

    private suspend fun resolve(mine: Int, outsideUS: OnboardingState.Notice?, request: suspend () -> Reps) {
        val outcome = try {
            Result.success(request())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
        if (mine != generation) return
        outcome.onSuccess { reps ->
            state = if (reps.members.isEmpty()) {
                // A district with nobody in it means the member data is behind, not a bad address.
                failed("We found your district but not your representatives. Please try again shortly.")
            } else {
                state.copy(phase = OnboardingState.Phase.Found(reps))
            }
        }.onFailure { error ->
            if (error is FloorApiError.Http && error.status == 404 && outsideUS != null) {
                state = state.copy(source = OnboardingState.Source.ADDRESS, notice = outsideUS, phase = OnboardingState.Phase.Editing)
                return
            }
            // The API phrases its 4xx for people; ours only for transport and decoding failures.
            state = failed((error as? FloorApiError)?.message ?: "Something went wrong. Please try again.")
        }
    }

    private fun failed(message: String) = state.copy(source = OnboardingState.Source.ADDRESS, phase = OnboardingState.Phase.Failed(message))

    /** Accepts the resolved delegation; null if there is nothing to confirm yet. */
    fun confirm(): Delegation? {
        val reps = (state.phase as? OnboardingState.Phase.Found)?.reps ?: return null
        return Delegation.of(reps, now())
    }

    /** Back to the field, keeping what was typed. */
    fun edit() {
        generation++
        state = state.copy(phase = OnboardingState.Phase.Editing, notice = if (state.notice == OnboardingState.Notice.APPROXIMATE) null else state.notice)
    }

    /** "Not your district? Type an address". */
    fun typeAddressInstead() {
        generation++
        state = state.copy(source = OnboardingState.Source.ADDRESS, notice = null, phase = OnboardingState.Phase.Editing)
    }
}
