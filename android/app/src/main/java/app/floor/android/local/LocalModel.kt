package app.floor.android.local

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.member.Load
import app.floor.android.member.revalidate
import app.floor.android.model.District
import app.floor.android.model.Jurisdiction
import app.floor.android.model.LocalHub
import app.floor.android.model.LocalHubs
import app.floor.android.model.LocalRegistry
import app.floor.android.model.StateLegislator
import app.floor.android.store.CityStore
import kotlinx.coroutines.launch

/** Everything the Local tab and the Cities screen draw, so a test can draw any state. */
data class LocalState(
    /** The stored district: its state is the first hub; its state districts find the legislators. */
    val district: District? = null,
    val registry: Load<LocalRegistry> = Load.Loading,
    /** The cities the user saved; null until they first add or remove one. */
    val saved: List<String>? = null,
    /** The hub picked on the switch; null for the first. */
    val selected: String? = null,
    val hubs: Map<String, Load<LocalHub>> = emptyMap(),
    /** The user's state legislators, when the district has its state districts. */
    val legislators: Load<List<StateLegislator>>? = null,
) {
    /** The switch's hubs: the user's state, then the saved cities. */
    val hubList: List<Jurisdiction>
        get() = registry.loaded?.let { LocalHubs.hubs(district?.state, saved, district?.place, it) }.orEmpty()

    val current: Jurisdiction? get() = hubList.firstOrNull { it.id == selected } ?: hubList.firstOrNull()

    /** The cities shown as added on the Cities screen. */
    val cityIds: List<String>
        get() = registry.loaded?.let { LocalHubs.cityIds(saved, district?.place, it) }.orEmpty()

    /** Whether the stored district carries its state legislative districts. */
    val hasStateDistricts: Boolean get() = district?.stateUpper != null || district?.stateLower != null
}

/**
 * The Local tab (v0.2.60, option A): the registry, each hub as it is opened, and the user's state
 * legislators. Saved cities live on the phone ([CityStore]); each response is saved for offline.
 */
class LocalModel(private val api: FloorApi, private val cities: CityStore) : ViewModel() {
    var state by mutableStateOf(LocalState(saved = cities.loadCities()))
        private set

    /** The tab showed, with the district as it now is. */
    fun appear(district: District?) {
        val changed = district != state.district
        state = state.copy(district = district)
        if (changed) state = state.copy(legislators = null)
        if (state.registry.needsRefresh) {
            viewModelScope.launch {
                revalidate(state.registry, api.savedLocal(), "Couldn't load the places Floor covers.", { state = state.copy(registry = it) }) { api.local() }
                showCurrent()
            }
        } else {
            showCurrent()
        }
    }

    fun reload() {
        viewModelScope.launch {
            revalidate(state.registry, api.savedLocal(), "Couldn't load the places Floor covers.", { state = state.copy(registry = it) }) { api.local() }
            state.current?.let { loadHub(it.id, force = true) }
        }
    }

    fun select(id: String) {
        state = state.copy(selected = id)
        showCurrent()
    }

    /** Adds or removes a city on the Cities screen; saved at once. */
    fun toggleCity(id: String) {
        val next = LocalHubs.toggle(state.cityIds, id)
        cities.saveCities(next)
        state = state.copy(saved = next)
    }

    private fun showCurrent() {
        val hub = state.current ?: return
        loadHub(hub.id)
        if (hub.kindValue == Jurisdiction.Kind.STATE) loadLegislators()
    }

    private fun loadHub(id: String, force: Boolean = false) {
        val current = state.hubs[id]
        // Already loading, or loaded fresh: nothing to do.
        if (!force && current != null && (current == Load.Loading || !current.needsRefresh)) return
        val start = current ?: Load.Loading
        state = state.copy(hubs = state.hubs + (id to start))
        viewModelScope.launch {
            revalidate(start,api.savedLocalHub(id), "Couldn't load this hub.", { state = state.copy(hubs = state.hubs + (id to it)) }) {
                api.localHub(id)
            }
        }
    }

    private fun loadLegislators() {
        val district = state.district ?: return
        if (!state.hasStateDistricts || state.legislators != null) return
        val start: Load<List<StateLegislator>> = Load.Loading
        state = state.copy(legislators = start)
        viewModelScope.launch {
            val saved = api.savedStateLegislators(district.state, district.stateUpper, district.stateLower)
                ?.let { app.floor.android.api.Saved(it.value.legislators, it.fetchedAt) }
            revalidate(start, saved, "Couldn't load your state legislators.", { state = state.copy(legislators = it) }) {
                api.stateLegislators(district.state, district.stateUpper, district.stateLower).legislators
            }
        }
    }
}
