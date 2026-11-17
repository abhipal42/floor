package app.floor.android.bill

import app.floor.android.model.Bill
import app.floor.android.model.BillStage
import app.floor.android.model.Chamber
import app.floor.android.model.District
import app.floor.android.model.Formats
import app.floor.android.model.Member
import app.floor.android.model.MemberContact
import app.floor.android.model.Schedule
import app.floor.android.model.ScheduleCategory
import app.floor.android.model.StateName
import app.floor.android.model.title

/**
 * The bill's facts, and nothing else, as Speak up and the offline share line say them (iOS
 * `BillFacts`): from the bill record and the week's schedule, no opinion and no AI.
 */
data class BillFacts(
    val citation: String,
    /** The bill's own name when it has one worth saying, else null. */
    val name: String?,
    val stage: BillStage?,
    val originChamber: Chamber?,
    val listing: FloorListing?,
    val hasVotes: Boolean,
) {
    /** `H.R. 5267, the American Franchise Act,` or just `H.R. 7254`. */
    val named: String get() = name?.let { "$citation, the $it," } ?: citation

    /** Where it stands, as the API's share line says it (`STAGE_CLAUSE` in apps/api/src/share.ts). */
    val clause: String
        get() {
            listing?.let {
                return when (it.chamber) {
                    Chamber.HOUSE -> "is scheduled for a House vote the week of ${it.weekOf}"
                    Chamber.SENATE -> "is on the Senate's program for the week of ${it.weekOf}"
                }
            }
            return when (stage) {
                BillStage.INTRODUCED -> "was introduced in the ${originChamber?.title ?: "Congress"}"
                BillStage.PASSED_HOUSE -> "passed the House"
                BillStage.PASSED_SENATE -> "passed the Senate"
                BillStage.PASSED_BOTH -> "passed the House and the Senate"
                BillStage.TO_PRESIDENT -> "was sent to the President"
                BillStage.LAW -> "became law"
                BillStage.VETOED -> "was vetoed"
                BillStage.FAILED -> "failed"
                BillStage.ADOPTED -> "was agreed to"
                null -> "is before Congress"
            }
        }

    /** `H.R. 5267, the American Franchise Act, is scheduled for a House vote the week of November 16.` */
    val sentence: String get() = "$named $clause."

    companion object {
        fun of(bill: Bill, listing: FloorListing?) = BillFacts(
            bill.citation, name(bill), bill.stage, bill.originChamber, listing, bill.votes.isNotEmpty(),
        )

        /** A short title; else the official title when it names an act; else nothing. */
        fun name(bill: Bill): String? {
            bill.shortTitle?.let { return trimmingThe(it) }
            val title = bill.title.trim()
            val namesAnAct = Regex("\\bAct( of \\d{4})?$").containsMatchIn(title)
            return if (namesAnAct && title.length <= 90) trimmingThe(title) else null
        }

        private fun trimmingThe(name: String): String =
            if (name.startsWith("the ", ignoreCase = true)) name.substring(4) else name
    }
}

/** A bill on this week's floor list, as the bill screen's banner and Speak up name it. */
data class FloorListing(
    val chamber: Chamber,
    val category: ScheduleCategory,
    /** `November 16`. */
    val weekOf: String,
    /** `Nov 16`. */
    val weekOfShort: String,
) {
    /** The banner's line: `Scheduled for House consideration under a rule, week of Nov 16.` */
    val bannerLine: String
        get() = when {
            chamber == Chamber.SENATE -> "Named in the Senate's program, week of $weekOfShort."
            category == ScheduleCategory.RULE -> "Scheduled for House consideration under a rule, week of $weekOfShort."
            category == ScheduleCategory.SUSPENSION -> "Scheduled for the House's fast track, needing two-thirds, week of $weekOfShort."
            else -> "On the House's floor list, week of $weekOfShort."
        }

    companion object {
        fun of(schedule: Schedule, billId: String): FloorListing? {
            val (chamber, item) = schedule.listing(billId) ?: return null
            return FloorListing(
                chamber, item.category,
                Formats.monthDayWide(schedule.week) ?: schedule.week,
                Formats.monthDay(schedule.week) ?: schedule.week,
            )
        }
    }
}

/** "Your view · you choose": the four stances. None is chosen until the person taps one. */
enum class Stance(val chip: String) {
    SUPPORT("I support it"),
    OPPOSE("I oppose it"),
    HOW_WILL_YOU_VOTE("How will you vote?"),
    QUESTION("I have a question"),
}

/**
 * The fixed text Speak up fills in (iOS `SpeakUpTemplate`): the greeting, where you live, the
 * bill's facts and the stance you picked, plus two placeholders for what only you can add. Never
 * stored, never sent by Floor.
 */
object SpeakUpTemplate {
    const val OWN_WORDS = "[Add your own words (optional)]"
    const val NAME_AND_ADDRESS = "[Your name and address go in the office's form]"
    const val HOUSE_FIND_YOUR_REP = "https://www.house.gov/representatives/find-your-representative"

    /** `Dear Representative Doggett,`. */
    fun greeting(member: Member) = "Dear ${member.title} ${member.lastName},"

    /** `I live in Texas's 37th District.`; for a senator, `I live in Texas.` */
    fun residence(member: Member, district: District): String =
        if (member.chamber == Chamber.SENATE) "I live in ${StateName.inSentence(district.state)}."
        else "I live in ${StateName.districtName(district.state, district.district)}."

    fun stanceLine(stance: Stance): String = when (stance) {
        Stance.SUPPORT -> "I support it."
        Stance.OPPOSE -> "I oppose it."
        Stance.HOW_WILL_YOU_VOTE -> "How do you plan to vote, and why?"
        Stance.QUESTION -> "I have a question about it:"
    }

    fun message(to: Member, district: District, facts: BillFacts, stance: Stance): String = listOf(
        greeting(to),
        "${residence(to, district)} ${facts.sentence} ${stanceLine(stance)}",
        OWN_WORDS,
        NAME_AND_ADDRESS,
    ).joinToString("\n\n")

    /** [text] with its stance line swapped, keeping edits; null when the old line is gone. */
    fun restanced(text: String, from: Stance, to: Stance): String? {
        val old = stanceLine(from)
        val at = text.indexOf(old)
        if (at < 0) return null
        return text.replaceRange(at, at + old.length, stanceLine(to))
    }

    /** The call script, line by line: the same facts read aloud, and the stance (or the choices). */
    fun callScript(to: Member, district: District, facts: BillFacts, stance: Stance?): List<String> {
        val place = if (to.chamber == Chamber.SENATE) StateName.inSentence(district.state)
        else StateName.districtName(district.state, district.district)
        val who = if (to.chamber == Chamber.SENATE) "the Senator" else "the ${to.title}"
        val line = when (stance) {
            Stance.SUPPORT -> "I support it."
            Stance.OPPOSE -> "I oppose it."
            Stance.HOW_WILL_YOU_VOTE -> "I'd like to know how $who plans to vote."
            Stance.QUESTION -> "I have a question about it: [your question]"
            null -> "\"I support it.\" / \"I oppose it.\" / \"I'd like to know where $who stands.\" (you pick)"
        }
        return listOf(
            "\"Hi, I'm a constituent from [your city], $place.\"",
            "\"I'm calling about ${facts.citation}${facts.name?.let { ", the $it" } ?: ""}. It ${facts.clause}.\"",
            if (stance == null) line else "\"$line\"",
            "\"Thank you.\"",
        )
    }

    /** Where "Copy & open form" goes: the office's form; else the House's; else the senator's site. */
    fun formUrl(member: Member, contact: MemberContact?): String? {
        contact?.contactForm?.let { return it }
        if (member.chamber == Chamber.HOUSE) return HOUSE_FIND_YOUR_REP
        return contact?.website
    }

    /** `tel:2022254865`. */
    fun telUrl(phone: String?): String? {
        val digits = phone?.filter { it.isDigit() } ?: return null
        return if (digits.isEmpty()) null else "tel:$digits"
    }
}

/**
 * What Share sends when `GET /v1/bills/{id}/share` can't be reached (iOS `ShareFallback`): the same
 * link shape on the web face, and a line built the way the API builds its own.
 */
object ShareFallback {
    const val BASE = "https://floor-web-seven.vercel.app"

    fun url(bill: Bill): String = "$BASE/bill/${bill.congress}/${bill.type}/${bill.number}"

    fun text(facts: BillFacts): String {
        val tail = when {
            facts.listing != null -> "What it does and how our members vote:"
            facts.hasVotes -> "What it does and how our members voted:"
            else -> "What it does and where it stands:"
        }
        return "${facts.sentence} $tail"
    }
}
