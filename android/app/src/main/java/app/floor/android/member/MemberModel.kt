package app.floor.android.member

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.api.FloorApiError
import app.floor.android.api.Saved
import app.floor.android.model.Disclosures
import app.floor.android.model.ElectProfile
import app.floor.android.model.Member
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberFunding
import app.floor.android.model.MemberPosts
import app.floor.android.model.Promises
import app.floor.android.model.MemberVote
import app.floor.android.model.SavedCopy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/** One thing a screen loads: loading, loaded (perhaps a saved copy), or failed with a sentence. */
sealed interface Load<out T> {
    data object Loading : Load<Nothing>
    data class Loaded<T>(val value: T, val saved: SavedCopy? = null) : Load<T>
    data class Failed(val message: String) : Load<Nothing>

    val loaded: T? get() = (this as? Loaded<T>)?.value

    /** Not loaded fresh yet: the screen loads again when it reappears (iOS `needsRefresh`). */
    val needsRefresh: Boolean get() = this !is Loaded<*> || this.saved != null
}

/**
 * The saved copy, then the network (iOS `revalidate`): with nothing on screen the saved copy goes
 * up first, marked as saved; the fresh answer replaces it; a failure leaves the saved copy (or what
 * was on screen) up and says why, or fails with the API's sentence.
 */
suspend fun <T> revalidate(current: Load<T>, saved: Saved<T>?, fallback: String, set: (Load<T>) -> Unit, fetch: suspend () -> T) {
    val onScreen = current is Load.Loaded
    if (!onScreen) set(saved?.let { Load.Loaded(it.value, SavedCopy(it.fetchedAt, SavedCopy.Status.REFRESHING)) } ?: Load.Loading)
    try {
        set(Load.Loaded(fetch()))
    } catch (e: CancellationException) {
        throw e
    } catch (e: FloorApiError) {
        when {
            saved != null -> set(
                Load.Loaded(
                    saved.value,
                    SavedCopy(saved.fetchedAt, if (e is FloorApiError.Transport) SavedCopy.Status.OFFLINE else SavedCopy.Status.REFRESH_FAILED),
                ),
            )
            onScreen -> {}
            else -> set(Load.Failed(e.message ?: fallback))
        }
    }
}

/** The member screen's switch: Votes · Said · Posts · Money · Contact (round 13). */
enum class MemberSection(val title: String) {
    RECORD("Votes"), SAID("Said"), POSTS("Posts"), MONEY("Money"), CONTACT("Contact");

    companion object {
        /** A member-elect's: no campaign promises or posts are gathered for them. */
        val elect = listOf(RECORD, MONEY, CONTACT)
    }
}

/** Money's own switch: Funding · Disclosures. */
enum class MoneySegment(val title: String) { FUNDING("Funding"), DISCLOSURES("Disclosures") }

/** A member's record: who they are, their party loyalty, and their recent votes. */
data class MemberRecord(val detail: MemberDetail, val votes: List<MemberVote>)

/** Everything the member screen draws, so a test can draw any state. */
data class MemberState(
    val record: Load<MemberRecord> = Load.Loading,
    val money: Load<MemberFunding> = Load.Loading,
    val disclosures: Load<Disclosures> = Load.Loading,
    val promises: Load<Promises> = Load.Loading,
    val posts: Load<MemberPosts> = Load.Loading,
    /** The promise on top of the Said deck. */
    val promise: Int = 0,
    val section: MemberSection = MemberSection.RECORD,
    val moneySegment: MoneySegment = MoneySegment.FUNDING,
    /** The grid square picked, oldest-first index; null for the latest. */
    val selectedCall: Int? = null,
) {
    /** Who this is, from whichever of the record or the money has loaded. */
    val member: Member? get() = record.loaded?.detail?.member ?: money.loaded?.member
}

/**
 * One member (iOS `RepScreenModel`, `MoneyModel`, `DisclosuresModel`): the record with its last 40
 * votes; Money's funding and disclosures load only when first shown. Each is saved for offline.
 */
class MemberModel(private val api: FloorApi, private val id: String, private val limit: Int = 40) : ViewModel() {
    var state by mutableStateOf(MemberState())
        private set

    private var job: Job? = null

    fun appear() {
        if (state.record.needsRefresh) reload()
        showing()
    }

    fun reload() {
        job?.cancel()
        job = viewModelScope.launch { loadRecord() }
    }

    fun select(section: MemberSection) {
        state = state.copy(section = section)
        showing()
    }

    fun selectMoney(segment: MoneySegment) {
        state = state.copy(moneySegment = segment)
        showing()
    }

    fun selectCall(index: Int) {
        state = state.copy(selectedCall = index)
    }

    fun selectPromise(index: Int) {
        state = state.copy(promise = index)
    }

    fun reloadMoney() = viewModelScope.launch { loadMoney() }

    fun reloadPromises() = viewModelScope.launch { loadPromises() }

    fun reloadPosts() = viewModelScope.launch { loadPosts() }

    fun reloadDisclosures() = viewModelScope.launch { loadDisclosures() }

    /** Said, Posts and Money's halves load the first time they are on screen. */
    private fun showing() {
        if (state.section == MemberSection.SAID && state.promises.needsRefresh) reloadPromises()
        if (state.section == MemberSection.POSTS && state.posts.needsRefresh) reloadPosts()
        if (state.section != MemberSection.MONEY) return
        if (state.moneySegment == MoneySegment.FUNDING && state.money.needsRefresh) reloadMoney()
        if (state.moneySegment == MoneySegment.DISCLOSURES && state.disclosures.needsRefresh) reloadDisclosures()
    }

    suspend fun loadRecord() {
        val saved = api.savedMember(id)?.let { detail ->
            api.savedMemberVotes(id, limit)?.let { votes -> Saved(MemberRecord(detail.value, votes.value.votes), minOf(detail.fetchedAt, votes.fetchedAt)) }
        }
        revalidate(state.record, saved, "Couldn't load this member.", { state = state.copy(record = it) }) {
            coroutineScope {
                val detail = async { api.member(id) }
                val votes = async { api.memberVotes(id, limit) }
                MemberRecord(detail.await(), votes.await().votes)
            }
        }
    }

    suspend fun loadMoney() {
        revalidate(state.money, api.savedFunding(id), "Couldn't load the FEC figures.", { state = state.copy(money = it) }) { api.funding(id) }
    }

    suspend fun loadPromises() {
        revalidate(state.promises, api.savedPromises(id), "Couldn't load what the campaign said.", { state = state.copy(promises = it) }) {
            api.promises(id)
        }
    }

    suspend fun loadPosts() {
        revalidate(state.posts, api.savedMemberPosts(id), "Couldn't load the posts.", { state = state.copy(posts = it) }) { api.memberPosts(id) }
    }

    suspend fun loadDisclosures() {
        revalidate(state.disclosures, api.savedDisclosures(id), "Couldn't load the disclosures.", { state = state.copy(disclosures = it) }) {
            api.disclosures(id)
        }
    }
}

/** What the member-elect screen draws. A null profile: the API's 404, no longer listed. */
data class ElectState(
    val profile: Load<ElectProfile?> = Load.Loading,
    val section: MemberSection = MemberSection.RECORD,
    val moneySegment: MoneySegment = MoneySegment.FUNDING,
)

/** One member-elect's profile (iOS `ElectScreenModel`): `/v1/members-elect/{id}`, saved for offline. */
class ElectModel(private val api: FloorApi, private val id: String) : ViewModel() {
    var state by mutableStateOf(ElectState())
        private set

    fun appear() {
        if (state.profile.needsRefresh) reload()
    }

    fun reload() = viewModelScope.launch { load() }

    fun select(section: MemberSection) {
        state = state.copy(section = section)
    }

    fun selectMoney(segment: MoneySegment) {
        state = state.copy(moneySegment = segment)
    }

    suspend fun load() {
        revalidate(state.profile, api.savedMemberElect(id), "Couldn't load this member-elect.", { state = state.copy(profile = it) }) {
            api.memberElect(id)
        }
    }
}
