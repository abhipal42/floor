package app.floor.android.model

import kotlinx.serialization.Serializable

// v0.2.60: the Local tab. A registry of jurisdictions (`GET /v1/local`: the 50 states and nine
// cities), each one's hub (`GET /v1/local/{id}`), and the user's state legislators
// (`GET /v1/local/{state}/legislators`). Decoded leniently, as the news is.

/** A state or a city Floor covers. */
@Serializable
data class Jurisdiction(
    val id: String,
    /** `state` or `city`. */
    private val kind: String = "state",
    val name: String,
    /** Postal code: `NY`. */
    val state: String = "",
    /** A city's Census place GEOID; null for a state. */
    val placeGeoid: String? = null,
    /** `records`, `pending`, `news_only`; anything else reads as pending. */
    private val coverage: String? = null,
) {
    enum class Kind { STATE, CITY }

    /** What Floor can read for it: council or legislature records, soon, or headlines only. */
    enum class Coverage { RECORDS, PENDING, NEWS_ONLY }

    val kindValue: Kind get() = if (kind.trim().lowercase() == "city") Kind.CITY else Kind.STATE

    val coverageValue: Coverage
        get() = when (coverage?.trim()?.lowercase()) {
            "records" -> Coverage.RECORDS
            "news_only" -> Coverage.NEWS_ONLY
            else -> Coverage.PENDING
        }
}

private object LossyJurisdictions : LossyList<Jurisdiction>(Jurisdiction.serializer())
private object LossyLocalItems : LossyList<LocalItem>(LocalItem.serializer())
private object LossyLegislators : LossyList<StateLegislator>(StateLegislator.serializer())
private object LossyLocalNews : LossyList<Headline>(Headline.serializer())

/** `GET /v1/local`. */
@Serializable
data class LocalRegistry(@Serializable(with = LossyJurisdictions::class) val jurisdictions: List<Jurisdiction> = emptyList()) {
    val cities: List<Jurisdiction> get() = jurisdictions.filter { it.kindValue == Jurisdiction.Kind.CITY }

    fun byId(id: String): Jurisdiction? = jurisdictions.firstOrNull { it.id == id }
}

/** A bill or a council matter that became law, passed, or waits on the governor. */
@Serializable
data class LocalItem(
    val id: String,
    /** `S 1788-A`, `Int. 891-A`, `CB 121276`. */
    val identifier: String = "",
    val title: String,
    val summary: String? = null,
    /** `State Senate`, `Assembly`, `City Council`. */
    val body: String = "",
    /** `YYYY-MM-DD`. */
    val date: String? = null,
    /** `signed`, `became_law`, `passed`, `awaiting_governor`. */
    private val status: String? = null,
    val yes: Int? = null,
    val no: Int? = null,
    val url: String? = null,
) {
    enum class Status { SIGNED, BECAME_LAW, PASSED, AWAITING_GOVERNOR }

    val statusValue: Status?
        get() = when (status?.trim()?.lowercase()) {
            "signed" -> Status.SIGNED
            "became_law" -> Status.BECAME_LAW
            "passed" -> Status.PASSED
            "awaiting_governor" -> Status.AWAITING_GOVERNOR
            else -> null
        }

    /** The tally, when the vote record has one. */
    val tally: Pair<Int, Int>? get() = if (yes != null && no != null) yes to no else null
}

/** `GET /v1/local/{id}`: what was enacted, what waits on the governor, and the week's news. */
@Serializable
data class LocalHub(
    val jurisdiction: Jurisdiction,
    val updatedAt: String? = null,
    @Serializable(with = LossyLocalItems::class) val enacted: List<LocalItem> = emptyList(),
    @Serializable(with = LossyLocalItems::class) val waiting: List<LocalItem> = emptyList(),
    @Serializable(with = LossyLocalNews::class) val news: List<Headline> = emptyList(),
) {
    val isEmpty: Boolean get() = enacted.isEmpty() && waiting.isEmpty() && news.isEmpty()
}

/** One member of a state legislature, from Open States. */
@Serializable
data class StateLegislator(
    val id: String,
    val name: String,
    val party: String = "",
    /** `upper` or `lower`. */
    val chamber: String = "",
    val district: String = "",
    val photoUrl: String? = null,
    val url: String? = null,
) {
    val upper: Boolean get() = chamber.trim().lowercase() == "upper"

    /** `D`, `R`, or `I` for anything else, as the federal members' party letters go. */
    val partyLetter: String
        get() = when (party.trim().lowercase().firstOrNull()) {
            'd' -> "D"
            'r' -> "R"
            else -> "I"
        }

    val initials: String
        get() = name.split(' ').filter { it.isNotBlank() }.let { parts ->
            ((parts.firstOrNull()?.take(1) ?: "") + (parts.drop(1).lastOrNull()?.take(1) ?: "")).uppercase()
        }
}

@Serializable
data class StateLegislators(@Serializable(with = LossyLegislators::class) val legislators: List<StateLegislator> = emptyList())

/** The Census place a lookup fell in. */
@Serializable
data class Place(val geoid: String, val name: String = "")

/** The Local tab's words and choices, kept pure for the tests. */
object LocalHubs {
    /**
     * The saved cities: what the user chose ([saved]), else their own [place] when it is a registry
     * city, else none.
     */
    fun cityIds(saved: List<String>?, place: Place?, registry: LocalRegistry): List<String> =
        saved ?: listOfNotNull(registry.cities.firstOrNull { place != null && it.placeGeoid == place.geoid }?.id)

    /**
     * The hub switch: the user's state (from the stored district) first, then the saved cities in
     * the order they were added. Ids the registry no longer lists are dropped.
     */
    fun hubs(state: String?, saved: List<String>?, place: Place?, registry: LocalRegistry): List<Jurisdiction> {
        val home = state?.let { code ->
            registry.jurisdictions.firstOrNull { it.kindValue == Jurisdiction.Kind.STATE && it.state.equals(code, ignoreCase = true) }
        }
        val cities = cityIds(saved, place, registry).distinct().mapNotNull { id -> registry.cities.firstOrNull { it.id == id } }
        return listOfNotNull(home) + cities
    }

    /** Adds or removes [id], starting from what [cityIds] shows. */
    fun toggle(current: List<String>, id: String): List<String> = if (id in current) current - id else current + id

    /** The muted card a city with no council records gets above its headlines; null with records. */
    fun coverageNote(jurisdiction: Jurisdiction): String? = when {
        jurisdiction.kindValue != Jurisdiction.Kind.CITY -> null
        jurisdiction.coverageValue == Jurisdiction.Coverage.PENDING ->
            "Council records for ${jurisdiction.name} are coming soon. Headlines below."
        jurisdiction.coverageValue == Jurisdiction.Coverage.NEWS_ONLY ->
            "${jurisdiction.name} doesn't publish council records in a form Floor can read yet. Headlines below."
        else -> null
    }

    /** A hub with nothing in it at all. */
    fun nothing(jurisdiction: Jurisdiction) = "Nothing from ${jurisdiction.name} in the last 30 days."

    /** The Cities screen's badge for a city. */
    fun badge(jurisdiction: Jurisdiction): String = when (jurisdiction.coverageValue) {
        Jurisdiction.Coverage.RECORDS -> "Ready"
        Jurisdiction.Coverage.PENDING -> "Coming soon"
        Jurisdiction.Coverage.NEWS_ONLY -> "News only"
    }

    private val assembly = setOf("CA", "NV", "NY", "WI", "NJ")
    private val delegates = setOf("MD", "VA", "WV")

    /** The chamber a legislator sits in: `State Senate`, `Assembly`, `House of Delegates`, `State House`. */
    fun chamberName(state: String, upper: Boolean): String {
        val code = state.uppercase()
        return when {
            code == "NE" -> "Legislature"
            upper -> "State Senate"
            code in assembly -> "Assembly"
            code in delegates -> "House of Delegates"
            else -> "State House"
        }
    }

    /** `State Senate · District 59`. */
    fun legislatorLine(state: String, legislator: StateLegislator): String =
        "${chamberName(state, legislator.upper)} · District ${legislator.district}"

    /** The dashed card a state hub shows when the stored district has no state districts. */
    fun lookUpAgain(state: String): String {
        val code = state.uppercase()
        val lower = when {
            code == "NE" -> null
            code in assembly -> "Assembly member"
            code in delegates -> "delegate"
            else -> "state representative"
        }
        return if (lower == null) "Look up your address again to see your state senator."
        else "Look up your address again to see your state senator and $lower."
    }

    /** The state hub's legislators, the senator first. */
    fun ordered(legislators: List<StateLegislator>): List<StateLegislator> = legislators.sortedBy { if (it.upper) 0 else 1 }
}
