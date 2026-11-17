package app.floor.android.store

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.floor.android.model.Delegation
import app.floor.android.model.Member

/**
 * Who you are to Floor, on this phone only: your district (if you gave one) and what you follow.
 * One per app; every screen reads its members from here.
 */
class Session(private val store: DelegationStore, followStore: FollowStore) {
    var delegation by mutableStateOf(store.load())
        private set

    val follows = Follows(followStore)

    /** Onboarding is up: first launch with no district and no skip, or "Change address". */
    var onboarding by mutableStateOf(delegation == null && !store.skipped())
        private set

    /** Onboarding opened from inside the app, so it can be closed without choosing. */
    var changingAddress by mutableStateOf(false)
        private set

    /** Your district's members, as onboarding found them; empty with no district. */
    val reps: List<Member> get() = delegation?.members.orEmpty()

    /** Your reps (minus any you hid) then everyone you follow. */
    val yourMembers: List<Member> get() = follows.state.yourMembers(reps)

    /** A district found: saved, the old reps' hidden flags forgotten, and anyone followed who is a rep now adopted. */
    fun finish(next: Delegation) {
        delegation?.let { old -> follows.update { it.forgetReps(old.memberIds) } }
        store.save(next)
        follows.adopt(next)
        delegation = next
        onboarding = false
        changingAddress = false
    }

    fun skip() {
        store.setSkipped(true)
        onboarding = false
    }

    /** "Change address" or "Find my reps": onboarding again, closable. */
    fun findReps() {
        changingAddress = true
        onboarding = true
    }

    fun closeOnboarding() {
        onboarding = false
        changingAddress = false
    }
}
