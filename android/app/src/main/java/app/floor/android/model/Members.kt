package app.floor.android.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import java.time.ZoneId

// The members half of the API contract (`apps/api/openapi.json`): `GET /v1/members/{id}`, its
// `/votes`, `GET /v1/members?q=` and `GET /v1/reps`, mirroring iOS `Member.swift`, `Lists.swift`
// and the record arithmetic in `RepScreenModel.swift`.

/**
 * A list read element by element (iOS `LossyElement`): an element this build cannot read is dropped
 * alone rather than failing the response, and anything but an array reads as empty.
 */
open class LossyList<T>(private val element: KSerializer<T>) : KSerializer<List<T>> {
    private val list = ListSerializer(element)
    override val descriptor: SerialDescriptor = list.descriptor

    override fun deserialize(decoder: Decoder): List<T> {
        val json = decoder as? JsonDecoder ?: return list.deserialize(decoder)
        val array = json.decodeJsonElement() as? JsonArray ?: return emptyList()
        return array.mapNotNull {
            try {
                json.json.decodeFromJsonElement(element, it)
            } catch (_: Exception) {
                null
            }
        }
    }

    override fun serialize(encoder: Encoder, value: List<T>) = list.serialize(encoder, value)
}

/**
 * How often a member sided with the majority of their own party. [votes] is the denominator actually
 * used: an independent reports zero, and the screen shows nothing rather than a percentage of nothing.
 */
@Serializable
data class PartyLoyalty(val votes: Int, val withParty: Int, val againstParty: Int) {
    /** Share of counted votes cast with their party, or null when there is nothing to report. */
    val withPartyShare: Double? get() = if (votes > 0) withParty.toDouble() / votes else null
}

/** `GET /v1/members/{id}`: the member, their party loyalty, and their office's contact. */
@Serializable
data class MemberDetail(
    val member: Member,
    /** Always sent by the API; zero (no figure) only in a hand-built value. */
    val partyLoyalty: PartyLoyalty = PartyLoyalty(0, 0, 0),
    val contact: MemberContact? = null,
    /** The contract puts `social` on the member; read here too, should the API send it beside it. */
    private val social: MemberSocial? = null,
) {
    /** The member's official accounts, wherever the response put them. */
    val accounts: List<MemberSocial.Account> get() = (member.social ?: social)?.accounts.orEmpty()
}

/** One row of a member's voting record. */
@Serializable
data class MemberVote(
    val vote: Vote,
    val position: Position,
    /** The candidate they named, on a Speaker election. */
    val choice: String? = null,
    /** Null for a procedural vote that refers to no measure. */
    val measure: MeasureSummary? = null,
) {
    val id: String get() = vote.id

    /** How the grid and the readout cite it: the measure, else the kind of question. */
    val cite: String get() = measure?.citation ?: vote.questionKind

    /**
     * Whether they were on the winning side: yea on a question that carried, nay on one that failed.
     * Null for present, a missed vote, or a Speaker ballot.
     */
    val sidedWithOutcome: Boolean?
        get() {
            val outcome = vote.outcome ?: return null
            return when (position) {
                Position.YEA -> outcome == Outcome.CARRIED
                Position.NAY -> outcome == Outcome.FAILED
                else -> null
            }
        }
}

/** `GET /v1/members/{id}/votes`, newest first. */
@Serializable
data class MemberVotes(val votes: List<MemberVote>)

/** A congressional district: `TX`, 37. */
@Serializable
data class District(
    val congress: Int,
    val state: String,
    val district: Int,
    val countyFips: String? = null,
    /** v0.2.60: the Census state legislative districts (SLDU, SLDL), as Open States names them. */
    val stateUpper: String? = null,
    val stateLower: String? = null,
    /** v0.2.60: the Census incorporated place the lookup fell in, for the Local tab's default city. */
    val place: Place? = null,
) {
    /** `TX-37`, `TX-AL` at large, or just `DC` where a delegate covers the whole place. */
    val name: String
        get() = when {
            state in setOf("DC", "PR", "GU", "VI", "AS", "MP") -> state
            district == 0 -> "$state-AL"
            else -> "$state-$district"
        }
}

/** `GET /v1/reps?address=` or `?lat=&lng=`: the district and its members, and any seats changing hands. */
@Serializable
data class Reps(
    val district: District,
    val members: List<Member>,
    @Serializable(with = LossyElects::class) val elect: List<MemberElect> = emptyList(),
    @Serializable(with = LossyPending::class) val pending: List<PendingSeat> = emptyList(),
) {
    val representative: Member? get() = members.firstOrNull { it.chamber == Chamber.HOUSE }
    val senators: List<Member> get() = members.filter { it.chamber == Chamber.SENATE }
}

/**
 * Who represents you, as onboarding resolves it and the app keeps it on the device (iOS
 * `Delegation`). **The address and the location are not part of it**: each is used for one request
 * and dropped.
 */
@Serializable
data class Delegation(
    val district: District,
    val members: List<Member>,
    /** When the lookup was made, epoch milliseconds. */
    val resolvedAt: Long = 0,
) {
    val representative: Member? get() = members.firstOrNull { it.chamber == Chamber.HOUSE }
    val senators: List<Member> get() = members.filter { it.chamber == Chamber.SENATE }
    val memberIds: List<String> get() = members.map { it.bioguideId }

    companion object {
        fun of(reps: Reps, resolvedAt: Long) = Delegation(reps.district, reps.members, resolvedAt)
    }
}

/** `GET /v1/members?q=`: sitting members, and members-elect and undecided seats matching the same text. */
@Serializable
data class MemberSearch(
    val members: List<Member>,
    @Serializable(with = LossyElects::class) val elect: List<MemberElect> = emptyList(),
    @Serializable(with = LossyPending::class) val pending: List<PendingSeat> = emptyList(),
)

// MARK: - Words about a member

/** `House · TX-37`, `House · WY-AL`, `Senate · TX`, `Delegate · DC`. */
val Member.seatCaption: String
    get() = "${if (isDelegate) title else chamber.title} · $seatBadge"

/** `U.S. Representative · D-TX-37`. */
val Member.roleLine: String
    get() = "${if (isDelegate) title else "U.S. $title"} · $partyAndSeat"

/** `House · New York 8th · D`, `Senate · New York · D`, `Delegate · District of Columbia · D`. */
val Member.seatLine: String
    get() {
        val name = StateName.full(state)
        val d = district
        return when {
            isDelegate -> "$title · $name · $party"
            chamber == Chamber.HOUSE && d != null -> "House · $name ${if (d == 0) "at-large" else StateName.ordinal(d)} · $party"
            else -> "Senate · $name · $party"
        }
    }

/** `YEA`, `NAY`, `PRESENT`, `MISSED`, `BALLOT`. */
val Position.shortLabel: String
    get() = when (this) {
        Position.YEA -> "YEA"
        Position.NAY -> "NAY"
        Position.PRESENT -> "PRESENT"
        Position.NOT_VOTING -> "MISSED"
        Position.CANDIDATE -> "BALLOT"
    }

/** The filled chip: `YEA`, `NAY`, `PRESENT`, `DNV`, a candidate's name. */
fun Position.chip(choice: String?): String = when (this) {
    Position.NOT_VOTING -> "DNV"
    Position.CANDIDATE -> choice?.trim()?.takeIf { it.isNotEmpty() }?.uppercase() ?: "BALLOT"
    else -> shortLabel
}

// MARK: - The record

/** The player card's tier, from crossovers: 400 or more MAVERICK, 300 or more SWING, else STARTER. */
enum class Tier { STARTER, SWING, MAVERICK;

    companion object {
        fun of(crossovers: Int) = if (crossovers >= 400) MAVERICK else if (crossovers >= 300) SWING else STARTER
    }
}

/** The last-40 numbers behind the rings and the grid (iOS `RecordStats`). */
class RecordStats(votes: List<MemberVote>, window: Int = 40) {
    /** Oldest first, as the grid reads left to right. */
    val calls: List<MemberVote> = votes.take(window).reversed()
    val missed: Int = calls.count { it.position == Position.NOT_VOTING }
    val present: Int = calls.count { it.position == Position.PRESENT }
    val showedUp: Int = calls.size - missed
    private val sided = calls.mapNotNull { it.sidedWithOutcome }
    val decided: Int = sided.size
    val sidedWithOutcome: Int = sided.count { it }

    val showedUpShare: Double? get() = if (calls.isEmpty()) null else showedUp.toDouble() / calls.size
    val winningShare: Double? get() = if (decided == 0) null else sidedWithOutcome.toDouble() / decided
}

/**
 * The computed "did you know" lines (iOS `RecordFacts`): arithmetic over the record on screen, none
 * written by a model.
 */
object RecordFacts {
    fun didYouKnow(member: Member, votes: List<MemberVote>, zone: ZoneId, window: Int = 40): String? {
        val calls = votes.take(window)
        if (calls.isEmpty()) return null
        val name = member.lastName
        val suspensions = calls.filter { it.vote.questionKind == "Suspension" }
        if (member.chamber == Chamber.HOUSE && suspensions.isNotEmpty()) {
            val yeas = suspensions.filter { it.position == Position.YEA }
            val others = suspensions.filter { it.position != Position.YEA }
            var text = "${suspensions.size} of $name's last ${calls.size} calls came up under suspension, the two-thirds fast lane."
            text += when {
                others.isEmpty() -> " $name voted yea on every one."
                others.size <= 2 -> {
                    val list = others.map { "${it.cite} (${it.position.shortLabel.lowercase()})" }
                    " $name voted yea on ${yeas.size} — the exception${if (others.size == 1) " was" else "s were"} " +
                        list.joinToString(" and ") + "."
                }
                else -> {
                    val nays = suspensions.count { it.position == Position.NAY }
                    val missed = suspensions.count { it.position == Position.NOT_VOTING }
                    var tail = " $name voted yea on ${yeas.size}"
                    if (nays > 0) tail += ", nay on $nays"
                    if (missed > 0) tail += ", and missed $missed"
                    "$tail."
                }
            }
            return text
        }
        val missed = calls.filter { it.position == Position.NOT_VOTING }
        return when (missed.size) {
            0 -> "$name cast a vote on every one of their last ${calls.size} calls."
            1, 2 -> {
                val list = missed.map { row -> listOfNotNull(row.cite, row.vote.dayIn(zone)).joinToString(", ") }
                "$name's missed vote${if (missed.size == 1) "" else "s"} in the last ${calls.size}: " + list.joinToString("; ") + "."
            }
            else -> "$name missed ${missed.size} of their last ${calls.size} calls."
        }
    }
}

/** What TalkBack reads for a member (iOS `Spoken.member`, `delegationCard`, `followingRow`, `memberPosition`). */
object SpokenMember {
    /** `Lloyd Doggett, Democrat, Representative for Texas' 37th District`. */
    fun member(member: Member): String = "${member.fullName}, ${PartyName.singular(member.party)}, ${member.title} for ${seat(member)}"

    fun seat(member: Member): String {
        val d = member.district
        if (member.chamber != Chamber.HOUSE || d == null || member.isDelegate) return StateName.inSentence(member.state)
        return StateName.districtName(member.state, d)
    }

    fun delegationCard(member: Member, share: Double?): String {
        val loyalty = share?.let { "Voted with their party ${String.format(java.util.Locale.US, "%.1f", it * 100)} percent of the time" }
            ?: "No party-loyalty figure"
        return "${member(member)}. $loyalty"
    }

    fun followingRow(member: Member, share: Double?, latest: MemberVote?, zone: ZoneId): String {
        val parts = mutableListOf(member(member))
        share?.let { parts += "${String.format(java.util.Locale.US, "%.1f", it * 100)} percent with their party" }
        if (latest != null) {
            val how = when (latest.position) {
                Position.YEA -> "yea"
                Position.NAY -> "nay"
                Position.PRESENT -> "present"
                Position.NOT_VOTING -> "did not vote"
                Position.CANDIDATE -> "for ${latest.choice ?: "a candidate"}"
            }
            parts += "Latest vote: " + listOfNotNull(how, latest.cite, latest.vote.dayIn(zone)).joinToString(", ")
        } else {
            parts += "No recorded votes yet"
        }
        return parts.joinToString(" ") { if (it.endsWith(".")) it else "$it." }
    }

    /** `Hakeem Jeffries, Representative for New York's 8th District, voted nay, with 128 of 211 Democrats`. */
    fun memberPosition(position: MemberPosition, partyNote: String?): String {
        val m = position.member
        val action = when (position.position) {
            Position.YEA -> "voted yea"
            Position.NAY -> "voted nay"
            Position.PRESENT -> "voted present"
            Position.NOT_VOTING -> "did not vote"
            Position.CANDIDATE -> "voted for ${position.choice ?: "a candidate"}"
        }
        return listOfNotNull(m.fullName, "${m.title} for ${seat(m)}", action, partyNote).joinToString(", ")
    }
}

/** `Nov 11`: a vote's day in [zone], as the record prints it. */
fun Vote.dayIn(zone: ZoneId): String? =
    occurredAtInstant?.atZone(zone)?.format(java.time.format.DateTimeFormatter.ofPattern("MMM d", java.util.Locale.US))
