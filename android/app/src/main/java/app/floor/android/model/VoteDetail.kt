package app.floor.android.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

// The vote screen's half of the API contract (`apps/api/openapi.json`): `GET /v1/votes/{id}` and
// `GET /v1/vote-kinds`, mirroring iOS `Vote.swift`, `Enums.swift` and the extensions in
// `VoteScreenModel.swift`.

/** How one member voted. [CANDIDATE] appears only on Speaker elections, alongside a choice. */
@Serializable
enum class Position {
    @SerialName("yea") YEA,
    @SerialName("nay") NAY,
    @SerialName("present") PRESENT,
    @SerialName("not_voting") NOT_VOTING,
    @SerialName("candidate") CANDIDATE,
}

/** One party's counts on a vote. */
@Serializable
data class PartyTotals(val party: String, val yea: Int, val nay: Int, val present: Int, val notVoting: Int) {
    /** Members of this party who cast yea, nay or present. */
    val voting: Int get() = yea + nay + present

    /** One square per member on the roll: yea, then nay, present, did not vote. */
    val squares: List<Position>
        get() = List(yea) { Position.YEA } + List(nay) { Position.NAY } +
            List(present) { Position.PRESENT } + List(notVoting) { Position.NOT_VOTING }
}

/** How many of one party backed one candidate in a Speaker election. */
@Serializable
data class CandidateTotal(val party: String, val candidate: String, val total: Int)

/** Who a position belongs to: the fields the vote route sends with `?members=`. */
@Serializable
data class Member(
    val bioguideId: String,
    val firstName: String,
    val lastName: String,
    val party: String,
    val state: String,
    val district: Int? = null,
    val chamber: Chamber,
    /**
     * `YYYY-MM-DD`: the day they leave, when a member-elect replaces them and that day has not come.
     * Null otherwise, and in a response from an API older than members-elect.
     */
    val leavingOn: String? = null,
)

/** One member's own position on a vote, for the members named in `?members=`. */
@Serializable
data class MemberPosition(val member: Member, val position: Position, val choice: String? = null)

/** `GET /v1/vote-kinds`: one row of the table the explainers come from. */
@Serializable
data class VoteKindInfo(
    val kind: String,
    val text: String,
    val source: String,
    /** Null when it applies to both chambers. */
    val chamber: Chamber? = null,
    /** The condition it applies under, in words; null for always. */
    val `when`: String? = null,
    val questions: List<String> = emptyList(),
) {
    /** The question as roll calls print it, less "On": `Suspend the Rules and Pass`, `Cloture Motion`. */
    val title: String
        get() {
            val first = questions.firstOrNull() ?: return kind.replace('_', ' ')
            val prefix = listOf("On Motion to ", "On the ", "On ", "Motion to ").firstOrNull { first.startsWith(it) }
            return if (prefix != null) first.removePrefix(prefix) else first
        }

    /** `Senate · When: … · Senate Rule XXII`: the line under a kind's text. */
    val footnote: String
        get() = listOfNotNull(chamber?.title, `when`?.let { "When: $it" }, source).joinToString(" · ")
}

@Serializable
data class VoteKindList(val kinds: List<VoteKindInfo>)

/**
 * `GET /v1/votes/{id}`: a vote plus the breakdowns the vote screen needs.
 *
 * The wire format is flat: the vote's own fields sit beside `partyTotals` and the rest, so [vote] is
 * decoded from the same object (iOS `VoteDetail.init(from:)`).
 */
@Serializable(with = VoteDetail.Serializer::class)
data class VoteDetail(
    val vote: Vote,
    /** Per-party counts. A Speaker election carries rows here only for present and not voting. */
    val partyTotals: List<PartyTotals>,
    /** Which candidate each party backed. Empty unless the vote is a Speaker election. */
    val candidateTotals: List<CandidateTotal> = emptyList(),
    /** How the members named in `?members=` voted. Empty when the request named none. */
    val positions: List<MemberPosition> = emptyList(),
    /** What was voted on, or null for a procedural vote that refers to no measure. */
    val measure: MeasureSummary? = null,
) {
    /** The measure's citation and name where there is one, else the question. */
    val title: String get() = measure?.let { "${it.citation} · ${it.title}" } ?: vote.question

    /** Party rows worth drawing: a party that cast no vote at all on this roll call is noise. */
    val significantParties: List<PartyTotals> get() = partyTotals.filter { it.voting + it.notVoting > 0 }

    /** The box score's rows, majority party first: the larger party on this roll call leads. */
    val boxScore: List<PartyTotals>
        get() = significantParties.sortedWith(
            compareByDescending<PartyTotals> { it.voting + it.notVoting }.thenByDescending { it.party },
        )

    /** Whether the box score needs a PRES column. Most roll calls have nobody voting present. */
    val anyPresent: Boolean get() = partyTotals.any { it.present > 0 }

    /** Parties for the full roll's tabs, Democrats first as the mock has it. */
    val rollParties: List<PartyTotals>
        get() {
            val order = mapOf("D" to 0, "R" to 1, "I" to 2)
            return significantParties.sortedWith(compareBy<PartyTotals> { order[it.party] ?: 9 }.thenBy { it.party })
        }

    /** Everyone on the roll, the sum of every party row. */
    val rollCount: Int get() = significantParties.sumOf { it.voting + it.notVoting }

    /** One candidate's total and which parties gave it, for a Speaker election. */
    data class CandidateStrength(val candidate: String, val total: Int, val parties: List<CandidateTotal>)

    /** Candidate totals grouped by candidate, strongest first. */
    val candidatesByStrength: List<CandidateStrength>
        get() = candidateTotals.groupBy { it.candidate }
            .map { (name, rows) -> CandidateStrength(name, rows.sumOf { it.total }, rows) }
            .sortedByDescending { it.total }

    /**
     * One sentence under the box score about who crossed party lines, computed from the counts.
     *
     * Only the two major parties are read: an independent's "party" is themselves (HANDOFF lesson
     * 15). Null for a Speaker election, or when a party split evenly and has no side to cross from.
     */
    val crossoverSentence: String?
        get() {
            if (vote.kind != VoteKind.QUESTION) return null
            val dems = partyTotals.firstOrNull { it.party == "D" && it.yea + it.nay > 0 } ?: return null
            val reps = partyTotals.firstOrNull { it.party == "R" && it.yea + it.nay > 0 } ?: return null
            if (dems.yea == dems.nay || reps.yea == reps.nay) return null
            val demYea = dems.yea > dems.nay
            val repYea = reps.yea > reps.nay
            val demCross = if (demYea) dems.nay else dems.yea
            val repCross = if (repYea) reps.nay else reps.yea
            if (demYea == repYea) {
                val side = if (demYea) "yea" else "nay"
                if (demCross == 0 && repCross == 0) return "Every Democrat and every Republican voting voted $side."
                return "Most of both parties voted $side: Democrats ${dems.yea}–${dems.nay}, Republicans ${reps.yea}–${reps.nay}."
            }
            return when {
                demCross == 0 && repCross == 0 -> "A party-line vote: no Democrat or Republican crossed."
                demCross == 0 -> "$repCross ${PartyName.of("R", repCross)} crossed to join a unanimous Democratic side."
                repCross == 0 -> "$demCross ${PartyName.of("D", demCross)} crossed to join a unanimous Republican side."
                else -> "$demCross ${PartyName.of("D", demCross)} and $repCross ${PartyName.of("R", repCross)} crossed party lines."
            }
        }

    object Serializer : KSerializer<VoteDetail> {
        @Serializable
        private data class Breakdown(
            val partyTotals: List<PartyTotals>,
            val candidateTotals: List<CandidateTotal> = emptyList(),
            val positions: List<MemberPosition> = emptyList(),
            val measure: MeasureSummary? = null,
        )

        override val descriptor: SerialDescriptor = Breakdown.serializer().descriptor

        override fun deserialize(decoder: Decoder): VoteDetail {
            val json = (decoder as? JsonDecoder) ?: error("VoteDetail decodes from JSON only")
            val obj = json.decodeJsonElement().jsonObject
            val vote = json.json.decodeFromJsonElement(Vote.serializer(), obj)
            val rest = json.json.decodeFromJsonElement(Breakdown.serializer(), obj)
            return VoteDetail(vote, rest.partyTotals, rest.candidateTotals, rest.positions, rest.measure)
        }

        override fun serialize(encoder: Encoder, value: VoteDetail) {
            val json = (encoder as? JsonEncoder) ?: error("VoteDetail encodes to JSON only")
            val vote = json.json.encodeToJsonElement(Vote.serializer(), value.vote).jsonObject
            val rest = json.json.encodeToJsonElement(
                Breakdown.serializer(),
                Breakdown(value.partyTotals, value.candidateTotals, value.positions, value.measure),
            ).jsonObject
            json.encodeJsonElement(JsonObject(vote + rest))
        }
    }
}

/** `Democrats`, `Republican`: a party code in words (iOS `PartyName`). */
object PartyName {
    fun plural(party: String): String = when (party) {
        "D" -> "Democrats"
        "R" -> "Republicans"
        "I" -> "Independents"
        else -> party
    }

    fun singular(party: String): String = when (party) {
        "D" -> "Democrat"
        "R" -> "Republican"
        "I" -> "Independent"
        else -> party
    }

    fun of(party: String, count: Int): String = if (count == 1) singular(party) else plural(party)
}
