package app.floor.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters
import java.util.Locale

// Members-elect (round 12, iOS `MembersElect.swift`): the winners of a general election before they
// take office, and the seats whose race is not decided yet. Floor never calls a race: every elect
// carries who called it and a source; a pending seat never carries a name. Decoded leniently.

/** The sitting member a seat belongs to now. */
@Serializable
data class SeatHolder(val bioguideId: String, val firstName: String, val lastName: String, val party: String) {
    val fullName: String get() = "$firstName $lastName"
}

/** Who called the race (`AP`, `House Clerk`), when, and where it says so. */
@Serializable
data class ElectCall(val by: String, val on: String? = null, val sourceUrl: String? = null) {
    val isClerk: Boolean get() = by == "House Clerk"
}

@Serializable
data class MemberElect(
    val id: String,
    val bioguideId: String? = null,
    val firstName: String,
    val lastName: String,
    val party: String,
    val state: String,
    val district: Int? = null,
    val chamber: Chamber,
    /** `YYYY-MM-DD`: `2027-01-03`. */
    val takesOffice: String,
    val replaces: SeatHolder? = null,
    val call: ElectCall,
    val fecCandidateId: String? = null,
    /** A special election's winner, sworn in once the state certifies: [takesOffice] is never shown. */
    val takesOfficeOnCertification: Boolean = false,
) {
    val fullName: String get() = "$firstName $lastName"

    /** The year the race was decided: the call's, else the year before a January term. */
    val electionYear: Int?
        get() {
            call.on?.take(4)?.toIntOrNull()?.let { return it }
            val year = takesOffice.take(4).toIntOrNull() ?: return null
            return if (takesOfficeOnCertification) year else year - 1
        }

    /** The elect as a [Member], for what draws one (initials, party tint, seat badge). */
    val asMember: Member
        get() = Member(bioguideId ?: id, firstName, lastName, party, state, district, chamber)

    /** `Senator-elect`, `Representative-elect`. */
    val title: String get() = "${asMember.title}-elect"
}

/** A seat whose race is not decided. Never carries a candidate's name. */
@Serializable
data class PendingSeat(
    val id: String,
    val state: String,
    val district: Int? = null,
    val chamber: Chamber,
    /** `uncalled` or `runoff`; anything else is still a seat without a winner. */
    @SerialName("status") val statusRaw: String = "uncalled",
    val runoffOn: String? = null,
    val incumbent: SeatHolder? = null,
    val sourceUrl: String? = null,
) {
    val isRunoff: Boolean get() = statusRaw == "runoff"

    val seatBadge: String get() = Member(id, "", "", "", state, district, chamber).seatBadge
}

object LossyElects : LossyList<MemberElect>(MemberElect.serializer())
object LossyPending : LossyList<PendingSeat>(PendingSeat.serializer())

/** `GET /v1/members-elect?state=`. */
@Serializable
data class MembersElect(
    @Serializable(with = LossyElects::class) val elect: List<MemberElect> = emptyList(),
    @Serializable(with = LossyPending::class) val pending: List<PendingSeat> = emptyList(),
) {
    /** Only the seats an address's delegation holds: the state's Senate seats and its House district. */
    fun seats(state: String, district: Int?): MembersElect {
        fun mine(s: String, c: Chamber, d: Int?) = s == state && (c == Chamber.SENATE || d == district)
        return MembersElect(elect.filter { mine(it.state, it.chamber, it.district) }, pending.filter { mine(it.state, it.chamber, it.district) })
    }

    companion object {
        /** What an API without the route (its 404) reads as. */
        const val NONE_BODY = """{"elect":[],"pending":[]}"""
    }
}

@Serializable
data class ElectFunding(
    val cycle: Int? = null,
    val receipts: Double? = null,
    val disbursements: Double? = null,
    val coverageEnd: String? = null,
    val sourceUrl: String? = null,
)

/** A member-elect's candidate disclosure: assets in ranges as filed, never a total. */
@Serializable
data class ElectDisclosure(
    val filedAt: String? = null,
    val sourceUrl: String? = null,
    @Serializable(with = LossyAssets::class) val assets: List<DisclosedAsset> = emptyList(),
    val paper: Boolean = false,
)

/** `GET /v1/members-elect/{id}`. */
@Serializable
data class ElectProfile(val elect: MemberElect, val funding: ElectFunding? = null, val disclosure: ElectDisclosure? = null)

/**
 * One row of a delegation that may be changing hands (iOS `SeatRow`): a member (LEAVING when an
 * elect replaces them), an elect under the member they replace, or a seat with no winner yet.
 */
sealed interface SeatRow {
    val key: String

    data class Sitting(val member: Member, val leavingOn: String?) : SeatRow {
        override val key get() = "member-${member.bioguideId}"
    }

    data class Elect(val elect: MemberElect) : SeatRow {
        override val key get() = elect.id
    }

    data class Pending(val seat: PendingSeat) : SeatRow {
        override val key get() = "pending-${seat.id}"
    }

    companion object {
        /** Members in order, each followed by the elect replacing them and any undecided seat they hold. */
        fun rows(members: List<Member>, elect: List<MemberElect>, pending: List<PendingSeat>): List<SeatRow> {
            val rows = mutableListOf<SeatRow>()
            val placedElect = mutableSetOf<String>()
            val placedPending = mutableSetOf<String>()
            for (member in members) {
                val replacing = elect.filter { it.replaces?.bioguideId == member.bioguideId }
                val leaving = member.leavingOn ?: replacing.firstOrNull { !it.takesOfficeOnCertification }?.takesOffice
                rows += Sitting(member, leaving)
                replacing.forEach { if (placedElect.add(it.id)) rows += Elect(it) }
                pending.filter { it.incumbent?.bioguideId == member.bioguideId }.forEach { if (placedPending.add(it.id)) rows += Pending(it) }
            }
            rows += elect.filter { it.id !in placedElect }.map(::Elect)
            rows += pending.filter { it.id !in placedPending }.map(::Pending)
            return rows
        }

        /** True when some row is about a seat changing hands. */
        fun changing(rows: List<SeatRow>): Boolean = rows.any { it !is Sitting || it.leavingOn != null }
    }
}

/** The dates and lines the elect rows and screen print (iOS `ElectText`); calendar days in UTC. */
object ElectText {
    /** `Jan 3, 2027`. */
    fun day(iso: String, locale: Locale): String? = Formats.dayText(iso, locale)

    /** `Jan 3`. */
    fun monthDay(iso: String, locale: Locale): String? = Formats.monthDay(iso, locale)

    /** The Tuesday after the first Monday in November of [year], `YYYY-MM-DD`. */
    fun electionDay(year: Int): String {
        val firstMonday = LocalDate.of(year, 11, 1).with(TemporalAdjusters.firstInMonth(DayOfWeek.MONDAY))
        return firstMonday.plusDays(1).toString()
    }

    fun electionDay(elect: MemberElect): String? = elect.electionYear?.let(::electionDay)

    /** The Congress a term starting on [takesOffice] sits in: 2027 is the 120th. */
    fun congress(takesOffice: String): Int? = takesOffice.take(4).toIntOrNull()?.let { (it - 1789) / 2 + 1 }

    fun congress(elect: MemberElect): Int? =
        if (elect.takesOfficeOnCertification) elect.electionYear?.let { (it - 1789) / 2 + 1 } else congress(elect.takesOffice)

    /** `Jan 3`, or `when Ohio certifies`. */
    fun takesOffice(elect: MemberElect, locale: Locale): String =
        if (elect.takesOfficeOnCertification) "when ${StateName.full(elect.state)} certifies"
        else monthDay(elect.takesOffice, locale) ?: elect.takesOffice

    /** `Race called by AP`, `Listed by the House Clerk`. */
    fun calledBy(call: ElectCall): String = if (call.isClerk) "Listed by the House Clerk" else "Race called by ${call.by}"

    fun callLine(call: ElectCall, locale: Locale): String {
        val whenText = call.on?.let { monthDay(it, locale) }?.let { " on $it" } ?: ""
        return if (call.isClerk) "Listed by the House Clerk$whenText. Floor shows the list, it doesn't make one."
        else "Race called by ${call.by}$whenText. Floor shows the call, it doesn't make one."
    }

    /** `Michigan's Senate seat`, `New York's 12th District`. */
    fun seatName(state: String, district: Int?, chamber: Chamber): String {
        if (chamber == Chamber.HOUSE && district != null) return StateName.districtName(state, district)
        val name = StateName.full(state)
        return "${if (name.endsWith("s")) "$name'" else "$name's"} Senate seat"
    }

    /** The pending seat's placeholder: a title and a line, never a name. */
    fun pending(seat: PendingSeat, locale: Locale): Pair<String, String> {
        val name = seatName(seat.state, seat.district, seat.chamber)
        return if (seat.isRunoff) {
            (seat.runoffOn?.let { monthDay(it, locale) }?.let { "Runoff $it" } ?: "Runoff ahead") to
                "$name: no winner yet. This seat fills in when the race is decided."
        } else {
            "Race not called yet" to "$name: Floor waits for the call. It never shows a leader or a projection."
        }
    }

    /** `Senator · Michigan`, `Representative · NY-12`; leaving, `Senator · leaves Jan 3, 2027`. */
    fun memberCaption(member: Member, leavingOn: String?, locale: Locale): String {
        val seat = if (member.chamber == Chamber.SENATE) member.title else "${member.title} · ${member.seatBadge}"
        leavingOn?.let { day(it, locale) }?.let { return "$seat · leaves $it" }
        return if (member.chamber == Chamber.SENATE) "$seat · ${StateName.full(member.state)}" else seat
    }

    /** `Senator-elect · takes office Jan 3`. */
    fun electCaption(elect: MemberElect, locale: Locale): String {
        val seat = if (elect.chamber == Chamber.SENATE) elect.title else "${elect.title} · ${elect.asMember.seatBadge}"
        return "$seat · takes office ${takesOffice(elect, locale)}"
    }
}
