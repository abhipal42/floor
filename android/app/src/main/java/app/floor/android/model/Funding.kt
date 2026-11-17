package app.floor.android.model

import kotlinx.serialization.Serializable
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

// `GET /v1/members/{id}/funding` (iOS `Funding.swift`): a member's current campaign's money, from two
// FEC sources that do not reconcile (HANDOFF lesson 24). No individual donor is named anywhere in
// this response, and nothing here may add one (product rule).

/** One committee's giving to a member over an FEC cycle: its own checks, and earmarks passed through. */
@Serializable
data class PacCheck(
    val committeeId: String,
    /** As filed with the FEC, in capitals. Show [displayName]. */
    val name: String,
    val kind: String? = null,
    val orgType: String? = null,
    val connectedOrg: String? = null,
    val direct: Double,
    val earmarked: Double = 0.0,
) {
    val displayName: String get() = CommitteeName.display(name)
}

/** What a member's current campaign reported receiving, and the committees that reported giving. */
@Serializable
data class Funding(
    /** The election this campaign is for: 2030 for a senator elected in 2024. */
    val cycle: Int,
    val coverageStart: String? = null,
    val coverageEnd: String? = null,
    val receipts: Double,
    val smallDollar: Double,
    val itemized: Double,
    val pac: Double,
    val party: Double,
    val other: Double,
    val cashOnHand: Double? = null,
    /** The two-year FEC cycle [committees] covers (lesson 33). */
    val committeesCycle: Int? = null,
    val committees: List<PacCheck> = emptyList(),
) {
    /** The four parts of the bar, in the mock's order. Party money rides with transfers. */
    enum class Part(val label: String) {
        SMALL_DOLLAR("Small-dollar"),
        ITEMIZED("Larger gifts"),
        PAC("PACs"),
        OTHER("Transfers & other"),
    }

    /** As reported; [Part.OTHER] can be negative (refunds and adjustments). */
    fun amount(part: Part): Double = when (part) {
        Part.SMALL_DOLLAR -> smallDollar
        Part.ITEMIZED -> itemized
        Part.PAC -> pac
        Part.OTHER -> party + other
    }

    /** As the bar and the legend draw it: never below zero, so both always agree. */
    fun shown(part: Part): Double = maxOf(0.0, amount(part))

    val shareBase: Double get() = Part.entries.sumOf { shown(it) }

    /** `45.5%` of the parts shown, or `—` with nothing to share out. */
    fun percent(part: Part): String =
        if (shareBase <= 0) "—" else String.format(Locale.US, "%.1f%%", 100 * shown(part) / shareBase)

    val adjustmentNote: String?
        get() {
            val other = amount(Part.OTHER)
            if (other >= 0) return null
            return "Transfers & other came to ${MoneyFormat.total(other)}: it includes refunds/adjustments, " +
                "so it shows as 0 and the shares are of the other three."
        }

    /** `2026 campaign · Jan 2025 – Oct 14, 2026`. */
    val period: String
        get() {
            val range = FundingDates.range(coverageStart, coverageEnd)
            return "$cycle campaign" + if (range.isEmpty()) "" else " · $range"
        }

    /** The committees' own checks, biggest first, nothing that netted to zero or below. */
    fun pacChecks(limit: Int = 10): List<PacCheck> = committees.filter { it.direct > 0 }.take(limit)

    val pacsNote: String
        get() {
            val years = committeesCycle?.let { "Each PAC's own checks, from its ${FundingDates.cycleYears(it)} filings. " } ?: ""
            return years + "A PAC can give \$5,000 per election — primary and general — so \$10,000 is the usual most for one race."
        }

    val pacsNone: Pair<String, String>
        get() {
            val years = committeesCycle?.let { FundingDates.cycleYears(it) }
            return ("No PAC checks on file" + (years?.let { " for $it" } ?: "") + ".") to
                ("No committee has reported giving to this campaign" + (years?.let { " in the $it FEC files" } ?: "") + ".")
        }
}

/** The member and their campaign's money; [funding] is null for a member the FEC has no totals for. */
@Serializable
data class MemberFunding(val member: Member, val funding: Funding? = null) {
    val noFilings: Pair<String, String>
        get() = "No campaign filings yet" to
            "${member.fullName} has no totals at the FEC for a current campaign. A newly appointed member, " +
            "or one who hasn't filed for the next race, shows up here once the FEC lists their campaign."
}

/** Campaign money as the landing page prints it (iOS `MoneyFormat`). */
object MoneyFormat {
    /** `$17.9M`, `$4.23M`, `$884K`, `−$12K`. */
    fun total(x: Double): String {
        val sign = if (x < 0) "−" else ""
        val a = abs(x)
        val thousands = (a / 1000).roundToLong()
        if (thousands < 1000) return "$sign\$${thousands}K"
        val hundredths = (a / 1e4).roundToLong() / 100.0
        if (hundredths < 10) return sign + "$" + String.format(Locale.US, "%.2f", hundredths) + "M"
        return sign + "$" + String.format(Locale.US, "%.1f", (a / 1e5).roundToLong() / 10.0) + "M"
    }

    /** The same for TalkBack: `17.9 million dollars`. */
    fun spoken(x: Double): String {
        val printed = total(x)
        val sign = if (printed.startsWith("−")) "minus " else ""
        val digits = printed.trimStart('−', '$')
        val unit = if (digits.endsWith("M")) "million" else "thousand"
        return "$sign${digits.dropLast(1)} $unit dollars"
    }

    /** A PAC check: `$10K`, `$2.5K`, `$750`. */
    fun check(amount: Double): String {
        if (abs(amount) < 1000) return "\$${amount.roundToLong()}"
        val k = (amount / 100).roundToLong() / 10.0
        return "$" + (if (k == Math.rint(k)) k.toLong().toString() else k.toString()) + "K"
    }

    /** `$53,830,872`. */
    fun dollars(x: Double, locale: Locale = Locale.US): String =
        java.text.NumberFormat.getCurrencyInstance(locale).apply {
            currency = java.util.Currency.getInstance("USD")
            maximumFractionDigits = 0
        }.format(x)
}

/** FEC dates are calendar days, printed in UTC (iOS `FundingDates`). */
object FundingDates {
    /** `Jan 2025 – Oct 14, 2026`, or whichever end is known. */
    fun range(start: String?, end: String?): String {
        val a = start?.let { Formats.day(it) }?.let { java.time.format.DateTimeFormatter.ofPattern("MMM yyyy", Locale.US).format(it) } ?: ""
        val b = end?.let { Formats.dayText(it) } ?: ""
        if (a.isNotEmpty() && b.isNotEmpty()) return "$a – $b"
        return a.ifEmpty { b }
    }

    /** `2025–26`. */
    fun cycleYears(cycle: Int): String = "${cycle - 1}–${cycle.toString().takeLast(2)}"
}

/** FEC committee names in title case, rule for rule as the landing page's `committeeName`. */
object CommitteeName {
    private val acronyms = setOf(
        "PAC", "AFL", "CIO", "IBEW", "SEIU", "UAW", "NEA", "AFT", "AMA", "ADA", "AARP", "NRA", "UA", "USA",
        "US", "UPS", "CVS", "IBM", "GE", "BP", "LLC", "LLP", "TIAA", "AT&T", "II", "III",
    )
    private val small = setOf("of", "and", "the", "for", "on", "in", "to", "a", "an", "at", "by")

    fun display(raw: String): String {
        val keep = mutableSetOf<String>()
        var s = raw.replace(Regex("\\s*\\([^)]*\\)"), "")
        s = Regex("\\b(?:[A-Z] ){2,}[A-Z]\\b").replace(s) { m -> m.value.replace(" ", "").also { keep += it } }
        s = s.replace(Regex("POLITICAL ACTION COMMITTEE", RegexOption.IGNORE_CASE), "PAC")
        s = s.replace(Regex("\\s+"), " ").trim()
        return s.split(" ").mapIndexed { i, word ->
            word.split("-").mapIndexed { k, part -> casePart(part, i == 0 && k == 0, keep) }.joinToString("-")
        }.joinToString(" ")
    }

    private fun casePart(part: String, first: Boolean, keep: Set<String>): String {
        val bare = part.filter { (it.isLetterOrDigit() && it.code < 128) || it == '&' }
        val upper = bare.uppercase()
        val hasDigit = bare.any { it.isDigit() }
        val vowels = if (bare.length >= 3) "AEIOUY" else "AEIOU"
        val hasVowel = upper.any { it in vowels }
        if (upper in acronyms || upper in keep || hasDigit || (bare.length > 3 && upper.endsWith("PAC")) || (bare.length > 1 && !hasVowel)) {
            return part.uppercase()
        }
        val lower = part.lowercase()
        if (!first && lower in small) return lower
        val index = lower.indexOfFirst { it in 'a'..'z' }
        if (index < 0) return lower
        var cased = lower.substring(0, index) + lower[index].uppercase() + lower.substring(index + 1)
        if (cased.length > 2 && cased[0].lowercaseChar() in "od" && (cased[1] == '\'' || cased[1] == '’') && cased[2] in 'a'..'z') {
            cased = cased.substring(0, 2) + cased[2].uppercase() + cased.substring(3)
        }
        return cased
    }
}
