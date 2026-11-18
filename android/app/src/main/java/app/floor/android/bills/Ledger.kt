package app.floor.android.bills

import app.floor.android.home.FeedItem
import app.floor.android.home.Stories
import app.floor.android.model.BillStage
import app.floor.android.model.Chamber
import app.floor.android.model.MeasureSummary
import app.floor.android.model.Outcome
import app.floor.android.model.TopicGroup
import app.floor.android.model.Vote
import app.floor.android.model.VoteStep
import app.floor.android.model.outcome
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/** The Bills tab's switch: every card, or only those whose latest vote carried, or failed. */
enum class LedgerFilter(val label: String) { ALL("All"), PASSED("Passed"), BLOCKED("Blocked") }

/**
 * One bill on the Bills tab (v0.2.59, Bills A's card): its votes newest first, and the House rules
 * for it, folded in. A rule whose bill is not in the list is a card of its own, [ruleFor] naming the bill.
 */
data class LedgerCard(val measure: MeasureSummary, val votes: List<FeedItem>, val rules: List<FeedItem> = emptyList()) {
    val latest: FeedItem get() = votes.first()
    val topic: TopicGroup get() = TopicGroup.ofPolicyArea(measure.policyArea)

    /** `H.R. 2102` for a rule whose bill is not in the list; null for any other card. */
    val ruleFor: String? get() = measure.forBillId?.let { Ledger.citation(it) }

    /** `Rule for H.R. 2102`, or the measure's own title. */
    val title: String get() = ruleFor?.let { "Rule for $it" } ?: measure.title
}

/** What the ledger draws: the shared feed's phase and votes ([app.floor.android.home.HomeState.billItems]), and the switch. */
data class LedgerState(
    val phase: app.floor.android.home.HomeState.Phase = app.floor.android.home.HomeState.Phase.Loading,
    val items: List<FeedItem> = emptyList(),
    val filter: LedgerFilter = LedgerFilter.ALL,
    val saved: app.floor.android.model.SavedCopy? = null,
) {
    /** What an empty ledger says, by filter. */
    val emptyMessage: String
        get() = when (filter) {
            LedgerFilter.ALL -> "None of the recent votes were on a bill."
            LedgerFilter.PASSED -> "No bill's latest vote carried."
            LedgerFilter.BLOCKED -> "No bill's latest vote failed."
        }
}

/** A Finals topic group's cards, newest first. */
data class LedgerSection(val topic: TopicGroup, val cards: List<LedgerCard>)

/** One step on a bill's progress track. */
data class TrackStep(val label: String, val state: State) {
    enum class State { DONE, CURRENT, AHEAD, STOPPED }
}

/** The Bills ledger, apart from the screen so it can be tested (iOS `BillsLedger`). */
object Ledger {
    private val newest = compareByDescending<FeedItem> { it.vote.occurredAtInstant ?: Instant.MIN }.thenByDescending { it.vote.id }

    /**
     * One card per bill the feed voted on, newest vote first. A vote whose [MeasureSummary.forBillId]
     * is a bill in the list folds into that bill's card; otherwise it keeps a card of its own.
     */
    fun cards(items: List<FeedItem>): List<LedgerCard> {
        val bills = items.distinctBy { it.vote.id }.filter { it.measure?.kind == MeasureSummary.Kind.BILL }
        val ids = bills.mapNotNull { it.measure?.id }.toSet()
        val rules = bills.filter { it.measure?.forBillId in ids }.groupBy { it.measure!!.forBillId!! }
        return bills.filterNot { it.measure?.forBillId in ids }
            .groupBy { it.measure!!.id }
            .map { (id, votes) ->
                val sorted = votes.sortedWith(newest)
                LedgerCard(sorted.first().measure!!, sorted, rules[id].orEmpty().sortedWith(newest))
            }
            .sortedWith(compareBy(newest) { it.latest })
    }

    /** Whether a card's latest vote passes [filter]: carried for Passed, failed for Blocked. */
    fun matches(card: LedgerCard, filter: LedgerFilter): Boolean = when (filter) {
        LedgerFilter.ALL -> true
        LedgerFilter.PASSED -> card.latest.vote.outcome == Outcome.CARRIED
        LedgerFilter.BLOCKED -> card.latest.vote.outcome == Outcome.FAILED
    }

    /** The cards under [filter], one section per topic group, the group with the most recent vote first. */
    fun sections(items: List<FeedItem>, filter: LedgerFilter): List<LedgerSection> =
        cards(items).filter { matches(it, filter) }
            .groupBy { it.topic }
            .map { (topic, cards) -> LedgerSection(topic, cards) }

    /** `119-hr-2102` as the chamber cites it: `H.R. 2102`. */
    fun citation(billId: String): String? {
        val parts = billId.split("-")
        if (parts.size != 3) return null
        val prefix = when (parts[1]) {
            "hr" -> "H.R."
            "s" -> "S."
            "hjres" -> "H.J.Res."
            "sjres" -> "S.J.Res."
            "hconres" -> "H.Con.Res."
            "sconres" -> "S.Con.Res."
            "hres" -> "H.Res."
            "sres" -> "S.Res."
            else -> return null
        }
        return "$prefix ${parts[2]}"
    }

    private fun type(measure: MeasureSummary): String? = measure.id.split("-").getOrNull(1)

    /**
     * The steps from [MeasureSummary.stage], or null for no track (no stage, a nomination, a rule
     * card). A bill goes Introduced → its own chamber → the other → Law; a simple resolution
     * Introduced → Adopted; a concurrent one through both chambers to Adopted. Done steps are green
     * with a ✓ on their label, the furthest one a ring; a vetoed or failed measure's stopping step
     * is in the nay colour.
     */
    fun track(card: LedgerCard): List<TrackStep>? {
        if (card.ruleFor != null) return null
        val stage = card.measure.stage ?: return null
        val type = type(card.measure) ?: return null
        val house = type.startsWith("h")
        val chambers = if (house) listOf(Chamber.HOUSE, Chamber.SENATE) else listOf(Chamber.SENATE, Chamber.HOUSE)
        val end = when (type) {
            "hr", "s", "hjres", "sjres" -> "Law"
            "hconres", "sconres", "hres", "sres" -> "Adopted"
            else -> return null
        }
        val middle = if (type == "hres" || type == "sres") emptyList() else chambers
        val names = listOf("Introduced") + middle.map { it.title } + end
        val passed: Set<Chamber> = when (stage) {
            BillStage.PASSED_HOUSE -> setOf(Chamber.HOUSE)
            BillStage.PASSED_SENATE -> setOf(Chamber.SENATE)
            BillStage.PASSED_BOTH, BillStage.TO_PRESIDENT, BillStage.LAW, BillStage.VETOED, BillStage.ADOPTED -> chambers.toSet()
            BillStage.INTRODUCED, BillStage.FAILED -> emptySet()
        }
        val done = BooleanArray(names.size)
        done[0] = true
        middle.forEachIndexed { i, chamber -> done[i + 1] = chamber in passed }
        if (stage == BillStage.LAW || stage == BillStage.ADOPTED) done[names.lastIndex] = true
        // Where a vetoed or failed measure stopped: the end for a veto; for a failure, the chamber
        // whose vote failed (its latest), else the first step not reached.
        val stopped: Int? = when (stage) {
            BillStage.VETOED -> names.lastIndex
            BillStage.FAILED -> {
                val vote = card.latest.vote
                val at = if (vote.outcome == Outcome.FAILED) middle.indexOf(vote.chamber) else -1
                if (at >= 0) {
                    for (i in 1..at) done[i] = true
                    at + 1
                } else {
                    1
                }
            }
            else -> null
        }
        if (stopped != null) done[stopped] = false
        val furthest = done.indices.last { done[it] }
        return names.mapIndexed { i, name ->
            when {
                i == stopped -> TrackStep(if (stage == BillStage.VETOED) "Vetoed" else "Failed", TrackStep.State.STOPPED)
                done[i] -> TrackStep(if (i == 0) name else "$name ✓", if (i == furthest) TrackStep.State.CURRENT else TrackStep.State.DONE)
                else -> TrackStep(name, TrackStep.State.AHEAD)
            }
        }
    }

    /** The track as one sentence for TalkBack: `Passed the House; next, the Senate`. */
    fun spokenTrack(card: LedgerCard): String? {
        val steps = track(card) ?: return null
        val stage = card.measure.stage
        fun name(label: String) = when (label.removeSuffix(" ✓")) {
            "House" -> "the House"
            "Senate" -> "the Senate"
            "Law" -> "becoming law"
            "Adopted" -> "adoption"
            else -> label.lowercase()
        }
        if (stage == BillStage.VETOED) return "Passed both chambers; vetoed"
        if (stage == BillStage.FAILED) {
            val vote = card.latest.vote
            return if (vote.outcome == Outcome.FAILED) "Failed in the ${vote.chamber.title}" else "Failed"
        }
        if (stage == BillStage.LAW) return "Became law"
        if (stage == BillStage.ADOPTED) return "Adopted"
        val passed = steps.drop(1).filter { it.state != TrackStep.State.AHEAD }.map { name(it.label) }
        val next = steps.firstOrNull { it.state == TrackStep.State.AHEAD }?.let { name(it.label) }
        val head = when {
            passed.size >= 2 -> "Passed both chambers"
            passed.size == 1 -> "Passed ${passed[0]}"
            else -> "Introduced"
        }
        return if (next != null) "$head; next, $next" else head
    }

    /**
     * The footer's left line: `Passed House` for a deciding vote that passed, else the vote's kind
     * (`Motion to proceed`, `Motion to refer`: the House records a referral as "Passed" too).
     */
    fun voteKind(vote: Vote): String =
        if (!VoteStep.isProcedural(vote) && vote.outcome == Outcome.CARRIED && vote.result?.lowercase()?.contains("passed") == true) "Passed ${vote.chamber.title}"
        else VoteStep.name(vote)

    /** `R 182–18 · D 210–0`, with I when independents voted. */
    fun partyLine(item: FeedItem): String? =
        item.partyTotals.filter { it.yea + it.nay > 0 }.joinToString(" · ") { "${it.party} ${it.yea}–${it.nay}" }.takeIf { it.isNotEmpty() }

    /** `+ Rule adopted 271–135, Nov 12 · 245–175, Nov 11`: a bill's rule votes, newest first, scores on one day sharing its date. */
    fun ruleLine(rules: List<FeedItem>, zone: ZoneId, locale: Locale): String? {
        if (rules.isEmpty()) return null
        val word = if (rules.all { it.vote.outcome == Outcome.CARRIED }) "adopted" else "votes"
        val days = LinkedHashMap<String?, MutableList<String>>()
        rules.forEach { r ->
            val day = r.vote.occurredAtInstant?.let { Stories.format(it, zone, locale) }
            days.getOrPut(day) { mutableListOf() } += "${r.vote.totals.yea}–${r.vote.totals.nay}"
        }
        return "+ Rule $word " + days.entries.joinToString(" · ") { (day, scores) -> scores.joinToString(" · ") + (day?.let { ", $it" } ?: "") }
    }
}
