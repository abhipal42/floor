package app.floor.android.model

import android.icu.text.DateFormat
import android.icu.text.NumberFormat
import android.icu.util.TimeZone
import android.icu.util.ULocale
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeParseException
import java.util.Date
import java.util.Locale

// Where a bill stands, in words (iOS `BillStanding.swift`, `BillRow.swift`'s `TopicText`, and the
// member and state helpers from `Member.swift` and `VoteOutcome.swift`).

/** The stage chip: `LAW`, `PASSED HOUSE`, `SENATE CALENDAR`, `IN COMMITTEE`, `VOTE FAILED`. */
data class StageChip(val text: String, val tone: Tone) {
    enum class Tone { LAW, FAILED, NEUTRAL }

    companion object {
        /** The chip for a bill, or null when neither the stage nor the latest action says anything. */
        fun of(stage: BillStage?, latestAction: LatestAction?): StageChip? {
            val action = latestAction?.text?.lowercase() ?: ""
            when (stage) {
                BillStage.LAW -> return StageChip("LAW", Tone.LAW)
                BillStage.ADOPTED -> return StageChip("ADOPTED", Tone.LAW)
                BillStage.VETOED -> return StageChip("VETOED", Tone.FAILED)
                BillStage.FAILED -> return StageChip("FAILED", Tone.FAILED)
                else -> Unit
            }
            if ("became public law" in action) return StageChip("LAW", Tone.LAW)
            if (failedVote(action)) return StageChip("VOTE FAILED", Tone.FAILED)
            if (stage == BillStage.TO_PRESIDENT || "presented to president" in action) {
                return StageChip("TO THE PRESIDENT", Tone.NEUTRAL)
            }
            if (stage == BillStage.PASSED_BOTH) return StageChip("PASSED BOTH", Tone.NEUTRAL)
            if ("calendar" in action) {
                return StageChip(if ("senate" in action) "SENATE CALENDAR" else "HOUSE CALENDAR", Tone.NEUTRAL)
            }
            if (action.startsWith("reported") || "ordered to be reported" in action) return StageChip("REPORTED", Tone.NEUTRAL)
            if (inCommittee(action)) return StageChip("IN COMMITTEE", Tone.NEUTRAL)
            return when (stage) {
                BillStage.PASSED_HOUSE -> StageChip("PASSED HOUSE", Tone.NEUTRAL)
                BillStage.PASSED_SENATE -> StageChip("PASSED SENATE", Tone.NEUTRAL)
                BillStage.INTRODUCED -> StageChip("INTRODUCED", Tone.NEUTRAL)
                else -> null
            }
        }

        /** The latest action is a vote the measure itself lost (iOS's allowlist, word for word). */
        internal fun failedVote(action: String): Boolean {
            val excluded = listOf(
                "amdt", "motion to table", "motion to reconsider", "motion to commit",
                "motion to recommit", "motion to waive", "motion to instruct",
            )
            if (excluded.any { it in action } || Regex("\\bsa\\s?\\d+").containsMatchIn(action)) return false
            if ("failed of passage" in action) return true
            if ("motion to proceed to consideration of measure" in action && "not agreed to" in action) return true
            if ("not invoked" in action) return "cloture on the motion to proceed" in action || "cloture on the measure" in action
            return false
        }

        /** The latest action leaves the bill in committee. */
        internal fun inCommittee(action: String): Boolean {
            if ("discharged" in action || "committee of the whole" in action) return false
            return listOf("referred to", "hearings held", "subcommittee", "committee consideration", "mark-up", "markup")
                .any { it in action }
        }
    }
}

/** The five-step road on a bill row: introduced · passed one chamber · passed both · to the President · law. */
object BillRoad {
    val steps = listOf("introduced", "passed one chamber", "passed both", "to the President", "law")
}

val BillListItem.roadSteps: Int? get() = stage?.roadSteps

val BillListItem.chip: StageChip? get() = StageChip.of(stage, latestAction)

/** `Received in the Senate … · Nov 12`: the action as Congress.gov wrote it, and its day. */
val BillListItem.latestStep: String?
    get() {
        val action = latestAction ?: return null
        val day = Formats.monthDay(action.on) ?: return action.text
        return "${action.text} · $day"
    }

/** Calendar days and counts as the app prints them (iOS `Formats`). */
object Formats {
    /** A `YYYY-MM-DD` day, or null. */
    fun day(text: String): LocalDate? = try {
        LocalDate.parse(text.take(10))
    } catch (_: DateTimeParseException) {
        null
    }

    /**
     * A calendar day through an ICU skeleton, in UTC: a day has no zone, and formatting its UTC
     * midnight in any other zone could print the day before.
     */
    private fun format(text: String, skeleton: String, locale: Locale): String? {
        val date = day(text) ?: return null
        val format = DateFormat.getInstanceForSkeleton(skeleton, ULocale.forLocale(locale))
        format.timeZone = TimeZone.GMT_ZONE
        return format.format(Date.from(date.atStartOfDay(ZoneOffset.UTC).toInstant()))
    }

    /** `Nov 11`. */
    fun monthDay(text: String, locale: Locale = Locale.US): String? = format(text, "MMMd", locale)

    /** `Nov 11, 2026`. */
    fun dayText(text: String, locale: Locale = Locale.US): String? = format(text, "yMMMd", locale)

    /** `November 16`. */
    fun monthDayWide(text: String, locale: Locale = Locale.US): String? = format(text, "MMMMd", locale)

    /** `1,234`. */
    fun count(n: Int): String = NumberFormat.getIntegerInstance(ULocale.US).format(n.toLong())
}

/** The words on a topic row: `724 bills · 9 with a floor vote · latest Nov 12`. */
object TopicText {
    fun detail(topic: Topic): String {
        val parts = mutableListOf("${Formats.count(topic.bills)} ${if (topic.bills == 1) "bill" else "bills"}")
        if (topic.billsWithFloorVote > 0) parts += "${Formats.count(topic.billsWithFloorVote)} with a floor vote"
        topic.latestActionOn?.let(Formats::monthDay)?.let { parts += "latest $it" }
        return parts.joinToString(" · ")
    }
}

/** What TalkBack reads for a bill row or a topic row (iOS `Spoken.billRow`, `Spoken.topicRow`). */
object SpokenBill {
    fun billRow(bill: BillListItem): String {
        val parts = mutableListOf("${bill.citation}, ${bill.label}")
        bill.chip?.let { chip -> parts += chip.text.lowercase().split(" ").joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } } }
        bill.latestAction?.let { action ->
            parts += "Latest: " + listOfNotNull(action.text.removeSuffix("."), Formats.monthDay(action.on)).joinToString(", ")
        }
        bill.roadSteps?.let { parts += "Road to law: $it of ${BillRoad.steps.size}, ${BillRoad.steps[it - 1]}" }
        return parts.joinToString(" ") { if (it.endsWith(".")) it else "$it." }
    }

    fun topicRow(topic: Topic): String {
        val parts = mutableListOf(
            topic.name,
            "${topic.bills} ${if (topic.bills == 1) "bill" else "bills"}, ${topic.billsWithFloorVote} with a floor vote",
        )
        topic.latestActionOn?.let(Formats::monthDay)?.let { parts += "Latest action $it" }
        return parts.joinToString(" ") { "$it." }
    }
}

// MARK: - Members and states

private val delegateJurisdictions = setOf("DC", "PR", "GU", "VI", "AS", "MP")

/** A non-voting House member: the delegates and Puerto Rico's resident commissioner. */
val Member.isDelegate: Boolean get() = chamber == Chamber.HOUSE && state in delegateJurisdictions

/** `Representative`, `Delegate`, `Resident Commissioner`, `Senator`. */
val Member.title: String
    get() = when {
        chamber == Chamber.SENATE -> "Senator"
        state == "PR" -> "Resident Commissioner"
        isDelegate -> "Delegate"
        else -> "Representative"
    }

val Member.fullName: String get() = "$firstName $lastName"

/** `NC-12`, `WY-AL`, `TX` for a senator, `DC` for a delegate. */
val Member.seatBadge: String
    get() {
        val d = district
        if (chamber != Chamber.HOUSE || isDelegate || d == null) return state
        return "$state-${if (d == 0) "AL" else d.toString()}"
    }

/** `R-OK-1`. */
val Member.partyAndSeat: String get() = "$party-$seatBadge"

/** `Rep. Kevin Hern (R-OK-1)`, `Sen. Ted Cruz (R-TX)`. */
val Member.sponsorLine: String get() = "${titlePrefix(this)} $fullName ($partyAndSeat)"

/** `Rep. Doggett`, `Sen. Cornyn`. */
val Member.shortName: String get() = "${titlePrefix(this)} $lastName"

private fun titlePrefix(member: Member): String = when (member.title) {
    "Senator" -> "Sen."
    "Delegate" -> "Del."
    "Resident Commissioner" -> "Res. Comm."
    else -> "Rep."
}

/** State names as sentences use them (iOS `StateName`). */
object StateName {
    fun full(code: String): String = names[code] ?: code

    /** `the District of Columbia`; every other name unchanged. */
    fun inSentence(code: String): String = if (code in setOf("DC", "VI", "MP")) "the ${full(code)}" else full(code)

    /** `8th`, `21st`, `112th`. */
    fun ordinal(n: Int): String {
        val tens = n % 100
        val suffix = if (tens in 11..13) "th" else listOf("th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th")[n % 10]
        return "$n$suffix"
    }

    /** `New York's 8th District`, `Wyoming's at-large district`, `District of Columbia`. */
    fun districtName(state: String, district: Int): String {
        val name = full(state)
        if (state in delegateJurisdictions) return name
        val possessive = if (name.endsWith("s")) "$name'" else "$name's"
        return if (district == 0) "$possessive at-large district" else "$possessive ${ordinal(district)} District"
    }

    private val names = mapOf(
        "AL" to "Alabama", "AK" to "Alaska", "AZ" to "Arizona", "AR" to "Arkansas", "CA" to "California",
        "CO" to "Colorado", "CT" to "Connecticut", "DE" to "Delaware", "FL" to "Florida", "GA" to "Georgia",
        "HI" to "Hawaii", "ID" to "Idaho", "IL" to "Illinois", "IN" to "Indiana", "IA" to "Iowa",
        "KS" to "Kansas", "KY" to "Kentucky", "LA" to "Louisiana", "ME" to "Maine", "MD" to "Maryland",
        "MA" to "Massachusetts", "MI" to "Michigan", "MN" to "Minnesota", "MS" to "Mississippi",
        "MO" to "Missouri", "MT" to "Montana", "NE" to "Nebraska", "NV" to "Nevada", "NH" to "New Hampshire",
        "NJ" to "New Jersey", "NM" to "New Mexico", "NY" to "New York", "NC" to "North Carolina",
        "ND" to "North Dakota", "OH" to "Ohio", "OK" to "Oklahoma", "OR" to "Oregon", "PA" to "Pennsylvania",
        "RI" to "Rhode Island", "SC" to "South Carolina", "SD" to "South Dakota", "TN" to "Tennessee",
        "TX" to "Texas", "UT" to "Utah", "VT" to "Vermont", "VA" to "Virginia", "WA" to "Washington",
        "WV" to "West Virginia", "WI" to "Wisconsin", "WY" to "Wyoming", "DC" to "District of Columbia",
        "PR" to "Puerto Rico", "GU" to "Guam", "VI" to "U.S. Virgin Islands", "AS" to "American Samoa",
        "MP" to "Northern Mariana Islands",
    )
}
