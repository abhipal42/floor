package app.floor.android.store

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.floor.android.api.FloorApi
import app.floor.android.model.Delegation
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** Where the district is kept between launches. Only the district and its members: never the address. */
interface DelegationStore {
    fun load(): Delegation?
    fun save(delegation: Delegation)
    fun clear()

    /** "Skip, I'll pick members myself": onboarding is not shown again until asked for. */
    fun skipped(): Boolean
    fun setSkipped(skipped: Boolean)
}

/**
 * The Local tab's saved cities, by registry id, on this phone only. Null until the user first adds
 * or removes one: until then the tab shows their own place's city ([app.floor.android.model.LocalHubs.cityIds]).
 */
interface CityStore {
    fun loadCities(): List<String>?
    fun saveCities(ids: List<String>)
}

class InMemoryCityStore(private var stored: List<String>? = null) : CityStore {
    override fun loadCities() = stored
    override fun saveCities(ids: List<String>) {
        stored = ids
    }
}

class InMemoryDelegationStore(private var stored: Delegation? = null, private var skip: Boolean = false) : DelegationStore {
    override fun load() = stored
    override fun save(delegation: Delegation) {
        stored = delegation
    }
    override fun clear() {
        stored = null
    }
    override fun skipped() = skip
    override fun setSkipped(skipped: Boolean) {
        skip = skipped
    }
}

private val Context.floorStore: DataStore<Preferences> by preferencesDataStore(name = "floor")

/**
 * The district and the follow list in Jetpack DataStore, as JSON, on this device only (excluded from
 * backup with the rest of the app's files). Read once at launch, before any screen, as iOS reads its
 * `UserDefaults`; written in the background on every change, in order.
 */
class DeviceStore(context: Context) : DelegationStore, FollowStore, CityStore {
    private val store = context.applicationContext.floorStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
    private var prefs: Preferences = runBlocking { store.data.first() }

    private fun write(block: (androidx.datastore.preferences.core.MutablePreferences) -> Unit) {
        scope.launch { store.edit(block) }
    }

    // An unreadable record reads as "not set", rather than failing to launch.
    override fun load(): Delegation? = prefs[DELEGATION]?.let {
        try {
            FloorApi.json.decodeFromString(Delegation.serializer(), it)
        } catch (_: Exception) {
            null
        }
    }

    override fun save(delegation: Delegation) {
        val text = FloorApi.json.encodeToString(Delegation.serializer(), delegation)
        prefs = prefs.toMutablePreferences().apply { this[DELEGATION] = text }
        write { it[DELEGATION] = text }
    }

    override fun clear() {
        prefs = prefs.toMutablePreferences().apply { remove(DELEGATION) }
        write { it.remove(DELEGATION) }
    }

    override fun skipped() = prefs[SKIPPED] ?: false

    override fun setSkipped(skipped: Boolean) {
        prefs = prefs.toMutablePreferences().apply { this[SKIPPED] = skipped }
        write { it[SKIPPED] = skipped }
    }

    override fun loadFollows(): FollowState = prefs[FOLLOWS]?.let {
        try {
            FloorApi.json.decodeFromString(FollowState.serializer(), it)
        } catch (_: Exception) {
            null
        }
    } ?: FollowState()

    override fun saveFollows(state: FollowState) {
        val text = FloorApi.json.encodeToString(FollowState.serializer(), state)
        prefs = prefs.toMutablePreferences().apply { this[FOLLOWS] = text }
        write { it[FOLLOWS] = text }
    }

    override fun loadCities(): List<String>? = prefs[CITIES]?.let {
        try {
            FloorApi.json.decodeFromString(ListSerializer(String.serializer()), it)
        } catch (_: Exception) {
            null
        }
    }

    override fun saveCities(ids: List<String>) {
        val text = FloorApi.json.encodeToString(ListSerializer(String.serializer()), ids)
        prefs = prefs.toMutablePreferences().apply { this[CITIES] = text }
        write { it[CITIES] = text }
    }

    private companion object {
        val CITIES = stringPreferencesKey("local.cities.v1")
        val DELEGATION = stringPreferencesKey("delegation.v1")
        val FOLLOWS = stringPreferencesKey("follows.v1")
        val SKIPPED = booleanPreferencesKey("onboarding.skipped")
    }
}
