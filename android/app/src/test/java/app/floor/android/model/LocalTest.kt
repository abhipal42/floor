package app.floor.android.model

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import app.floor.android.local.LocalModel
import app.floor.android.store.InMemoryCityStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * v0.2.60's Local tab: the hub list from the stored state, the saved cities and the place's
 * default; the coverage copy; the legislators' words; and the district's new fields.
 */
class LocalTest {
    private val registry = Fixtures.decode("local-registry", LocalRegistry.serializer())
    private val nycPlace = Place("3651000", "New York city")

    @Test
    fun theRegistryHasFiftyStatesAndNineCities() {
        assertEquals(59, registry.jurisdictions.size)
        assertEquals(9, registry.cities.size)
        assertEquals(Jurisdiction.Coverage.NEWS_ONLY, registry.byId("philadelphia")?.coverageValue)
    }

    @Test
    fun theStateComesFirstThenTheCities() {
        // Nothing saved yet: the user's own place, when it is a registry city.
        assertEquals(listOf("ny", "nyc"), LocalHubs.hubs("NY", null, nycPlace, registry).map { it.id })
        // A place that isn't a registry city adds none.
        assertEquals(listOf("ny"), LocalHubs.hubs("NY", null, Place("3602000", "Albany city"), registry).map { it.id })
        // Saved cities replace the default, in the order they were added; unknown ids drop.
        assertEquals(listOf("ny", "seattle", "boston"), LocalHubs.hubs("NY", listOf("seattle", "gone", "boston"), nycPlace, registry).map { it.id })
        // Saved none at all: the state alone.
        assertEquals(listOf("ny"), LocalHubs.hubs("ny", emptyList(), nycPlace, registry).map { it.id })
        // No state known: only the cities.
        assertEquals(listOf("nyc"), LocalHubs.hubs(null, null, nycPlace, registry).map { it.id })
    }

    @Test
    fun togglingStartsFromWhatIsShown() {
        val shown = LocalHubs.cityIds(null, nycPlace, registry)
        assertEquals(listOf("nyc", "seattle"), LocalHubs.toggle(shown, "seattle"))
        assertEquals(emptyList<String>(), LocalHubs.toggle(shown, "nyc"))
    }

    @Test
    fun aCityAddedIsSavedAndShown() {
        val store = InMemoryCityStore()
        val model = LocalModel(FloorApi("http://localhost/"), store)
        assertNull(store.loadCities())
        model.toggleCity("seattle")
        assertEquals(listOf("seattle"), store.loadCities())
        assertEquals(listOf("seattle"), model.state.saved)
    }

    @Test
    fun coverageSaysWhatFloorCanRead() {
        assertNull(LocalHubs.coverageNote(registry.byId("nyc")!!))
        assertNull(LocalHubs.coverageNote(registry.byId("ny")!!))
        assertEquals("Council records for Boston are coming soon. Headlines below.", LocalHubs.coverageNote(registry.byId("boston")!!))
        assertEquals(
            "Philadelphia doesn't publish council records in a form Floor can read yet. Headlines below.",
            LocalHubs.coverageNote(registry.byId("philadelphia")!!),
        )
        assertEquals(listOf("Ready", "Coming soon", "News only"), listOf("nyc", "sf", "los-angeles").map { LocalHubs.badge(registry.byId(it)!!) })
        assertEquals("Nothing from Seattle in the last 30 days.", LocalHubs.nothing(registry.byId("seattle")!!))
    }

    @Test
    fun legislatorsSitInTheirStatesChambers() {
        val senator = StateLegislator("a", "Ada Lovelace", "Democratic", "upper", "59")
        val member = StateLegislator("b", "Bo Diddley", "Republican", "lower", "65")
        assertEquals("State Senate · District 59", LocalHubs.legislatorLine("NY", senator))
        assertEquals("Assembly · District 65", LocalHubs.legislatorLine("NY", member))
        assertEquals("State House · District 65", LocalHubs.legislatorLine("TX", member))
        assertEquals("House of Delegates · District 65", LocalHubs.legislatorLine("VA", member))
        assertEquals(listOf("D", "R"), listOf(senator.partyLetter, member.partyLetter))
        assertEquals(listOf(senator, member), LocalHubs.ordered(listOf(member, senator)))
        assertEquals("Look up your address again to see your state senator and Assembly member.", LocalHubs.lookUpAgain("NY"))
        assertEquals("Look up your address again to see your state senator and state representative.", LocalHubs.lookUpAgain("TX"))
    }

    @Test
    fun theHubsDecodeAsServed() {
        val ny = Fixtures.decode("local-ny", LocalHub.serializer())
        assertEquals("S 1788-A", ny.enacted.single().identifier)
        assertEquals(LocalItem.Status.SIGNED, ny.enacted.single().statusValue)
        assertEquals(LocalItem.Status.AWAITING_GOVERNOR, ny.waiting.single().statusValue)
        val nyc = Fixtures.decode("local-nyc", LocalHub.serializer())
        assertEquals(44 to 5, nyc.enacted.single().tally)
        assertNull(ny.enacted.single().tally)
    }

    @Test
    fun theDistrictCarriesItsStateDistrictsAndPlace() {
        val old = FloorApi.json.decodeFromString(District.serializer(), """{"congress":119,"state":"NY","district":12}""")
        assertNull(old.stateUpper)
        assertNull(old.place)
        val new = FloorApi.json.decodeFromString(
            District.serializer(),
            """{"congress":119,"state":"NY","district":10,"stateUpper":"59","stateLower":"65","place":{"geoid":"3651000","name":"New York city"}}""",
        )
        assertEquals("59", new.stateUpper)
        assertEquals("65", new.stateLower)
        assertEquals(nycPlace, new.place)
    }
}
