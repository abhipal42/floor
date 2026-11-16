package app.floor.android.model

/**
 * Whether a question vote carried, and where its threshold sat. Every scoreboard draws the same
 * yellow line, so the arithmetic lives here once (iOS `VoteOutcome.swift`).
 */
data class ThresholdLine(
    /** Yea, nay and present: what the bar is drawn across. */
    val cast: Int,
    val yea: Int,
    val nay: Int,
    /** Yea votes the question needed. */
    val needed: Int,
    val threshold: VoteThreshold,
    /** What the chamber recorded, when its result wording says; null while open or unfamiliar. */
    val recorded: Outcome?,
) {
    constructor(vote: Vote) : this(
        cast = vote.totals.voting,
        yea = vote.totals.yea,
        nay = vote.totals.nay,
        needed = vote.votesNeeded,
        threshold = vote.threshold,
        recorded = if (vote.state == VoteState.FINAL) vote.recordedOutcome else null,
    )

    /** How far yea finished from the line: positive is over it, negative short of it. */
    val margin: Int get() = yea - needed

    /** True when the count and the chamber's record disagree; the record wins. */
    val contradicted: Boolean
        get() = recorded != null && (recorded == Outcome.CARRIED) != (margin >= 0)

    /** Yea votes past the line, or null when it fell short or the record says otherwise. */
    val over: Int? get() = if (!contradicted && margin >= 0) margin else null

    /** Yea votes it still needed, or null once the line was met or the record says otherwise. */
    val short: Int? get() = if (!contradicted && margin < 0) -margin else null

    /** Share of the bar the yea fill takes, 0..1. */
    val yeaShare: Double get() = if (cast > 0) yea.toDouble() / cast else 0.0

    /** Where the yellow line sits on the bar, 0..1. */
    val lineShare: Double get() = if (cast > 0) minOf(1.0, needed.toDouble() / cast) else 0.5

    /** The short name for what was needed, printed in the threshold yellow. */
    val label: String
        get() = when (threshold) {
            VoteThreshold.MAJORITY -> "MAJORITY"
            VoteThreshold.TWO_THIRDS -> "TWO-THIRDS"
            VoteThreshold.THREE_FIFTHS_SWORN -> "60 OF 100"
        }
}

enum class Outcome { CARRIED, FAILED }

/** The threshold arithmetic, or null for a Speaker election, which has no yea/nay sides. */
val Vote.line: ThresholdLine? get() = if (kind == VoteKind.QUESTION) ThresholdLine(this) else null

/**
 * Whether the question carried, or null for a Speaker election or a vote not yet final. The
 * chamber's own result is the authority; only when it is missing or unfamiliar does the threshold
 * decide.
 */
val Vote.outcome: Outcome?
    get() {
        if (kind != VoteKind.QUESTION || state != VoteState.FINAL) return null
        recordedOutcome?.let { return it }
        val line = line ?: return null
        return if (line.margin >= 0) Outcome.CARRIED else Outcome.FAILED
    }

/**
 * The outcome the result wording states, or null when it is missing or unfamiliar. Rejections are
 * checked first because "Not Agreed to" contains "Agreed", and "Veto Sustained" is a failed override.
 */
val Vote.recordedOutcome: Outcome?
    get() {
        val r = result?.lowercase() ?: return null
        if (listOf("rejected", "failed", "not agreed", "not sustained", "not invoked", "defeated", "veto sustained")
                .any { r.contains(it) }
        ) return Outcome.FAILED
        if (listOf("passed", "agreed", "confirmed", "sustained", "adopted", "invoked", "concurred", "overridden")
                .any { r.contains(it) }
        ) return Outcome.CARRIED
        return null
    }

/** One word for the result chip: PASSED, AGREED, CONFIRMED, FAILED, REJECTED. */
val Vote.outcomeWord: String?
    get() {
        val outcome = outcome ?: return null
        val r = (result ?: "").lowercase()
        return when (outcome) {
            Outcome.CARRIED -> when {
                r.contains("overridden") -> "OVERRIDDEN"
                r.contains("confirmed") -> "CONFIRMED"
                r.contains("passed") -> "PASSED"
                r.contains("agreed") -> "AGREED"
                else -> "PASSED"
            }
            Outcome.FAILED -> if (r.contains("rejected") || r.contains("not agreed")) "REJECTED" else "FAILED"
        }
    }

private val questionKinds = listOf(
    // The Senate's override question names passage, so it goes before "passage".
    "objections of the president" to "Veto override",
    "veto" to "Veto override",
    "conference report" to "Conference report",
    "suspend the rules" to "Suspension",
    "cloture" to "Cloture",
    "previous question" to "Previous question",
    "recommit" to "Motion to recommit",
    "motion to table" to "Motion to table",
    "discharge" to "Motion to discharge",
    "motion to refer" to "Motion to refer",
    "motion to proceed" to "Motion to proceed",
    "concur" to "Concur",
    "nomination" to "Nomination",
    "amendment" to "Amendment",
    "passage" to "Passage",
    "resolution" to "Resolution",
    "adjourn" to "Adjourn",
    "journal" to "Journal",
)

/** What kind of question this was, in a word or two: `Suspension`, `Cloture`, `Passage`. */
val Vote.questionKind: String
    get() {
        if (kind == VoteKind.ELECTION) return "Speaker election"
        val q = question.lowercase()
        questionKinds.firstOrNull { q.contains(it.first) }?.let { return it.second }
        return question.removePrefix("On the ").let { if (it == question) question.removePrefix("On ") else it }
    }
