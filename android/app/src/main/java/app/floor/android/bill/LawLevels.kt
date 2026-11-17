package app.floor.android.bill

import app.floor.android.model.Bill
import app.floor.android.model.Chamber
import app.floor.android.model.Outcome
import app.floor.android.model.Vote
import app.floor.android.model.VoteThreshold
import app.floor.android.model.line
import app.floor.android.model.outcome
import app.floor.android.model.questionKind

/**
 * A bill's path to law as steps (iOS `BillProgress`), from the actions Congress.gov marks with no
 * chamber — its own summary labels, far steadier than the free-text actions — and the chambers'
 * passage roll calls, which arrive before the bill's actions are re-fetched.
 */
class BillProgress(bill: Bill) {
    enum class State { DONE, FAILED, PENDING }

    data class Step(val label: String, val state: State, val on: String?)

    val steps: List<Step>

    init {
        val markers = bill.actions.filter { it.chamber == null }
        val origin = bill.originChamber ?: Chamber.HOUSE
        val other = if (origin == Chamber.HOUSE) Chamber.SENATE else Chamber.HOUSE

        // Newest first is how the API returns actions, so the last match is the first marker.
        fun day(matching: (String) -> Boolean): String? = markers.lastOrNull { matching(it.text) }?.actedOn
        fun passed(chamber: Chamber): String? =
            day { it.contains("Passed/agreed to in ${chamber.title}", ignoreCase = true) }
                ?: bill.votes.firstOrNull { it.chamber == chamber && it.isFinalPassage }?.occurredAt?.take(10)
        fun rejected(chamber: Chamber): Boolean =
            markers.any { it.text.contains("Failed of passage/not agreed to in ${chamber.title}", ignoreCase = true) }

        val list = mutableListOf<Step>()
        // The action list is capped, so `introducedOn` is the authority.
        val introducedOn = bill.introducedOn ?: day { it.contains("Introduced in", ignoreCase = true) }
        list += Step("Introduced", if (introducedOn == null) State.PENDING else State.DONE, introducedOn)
        val verb = if (bill.isResolution) "Agreed to in" else "Passed"
        for (chamber in bill.chambersThatMustAct(origin, other)) {
            val on = passed(chamber)
            list += Step(
                "$verb ${chamber.title}",
                when {
                    on != null -> State.DONE
                    rejected(chamber) -> State.FAILED
                    else -> State.PENDING
                },
                on,
            )
        }
        if (bill.canBecomeLaw) {
            val on = day { it.contains("Became Public Law", ignoreCase = true) }
            list += Step("Became law", if (on != null) State.DONE else State.PENDING, on)
        }
        steps = list
    }
}

/** Whether this roll call carried the measure in its chamber, rather than a procedural step on the way. */
val Vote.isFinalPassage: Boolean
    get() {
        if (outcome != Outcome.CARRIED) return false
        val q = question.lowercase()
        return "passage" in q || "concur" in q || "agreeing to the resolution" in q
    }

/** Whether losing this vote stops the measure where it is (a failed amendment or recommittal does not). */
val Vote.failureStopsTheBill: Boolean
    get() = questionKind in setOf(
        "Passage", "Cloture", "Motion to proceed", "Suspension", "Resolution", "Concur", "Veto override", "Conference report",
    )

/** A key play, as the bill screen lists it: `Senate cloture, 60 needed — 3 short`. */
val Vote.playDescription: String
    get() {
        val need = when (threshold) {
            VoteThreshold.MAJORITY -> "majority needed"
            VoteThreshold.TWO_THIRDS -> "two-thirds needed"
            VoteThreshold.THREE_FIFTHS_SWORN -> "60 needed"
        }
        var text = "${chamber.title} ${questionKind.lowercase()}, $need"
        val short = line?.short
        if (outcome == Outcome.FAILED && short != null) text += " — $short short"
        return text
    }

/**
 * "Six levels to law" (iOS `LawLevels`): Introduced, Committee, House, Senate, Same text, Signed.
 * Built on [BillProgress], so the two can never disagree about whether a chamber passed it.
 * Stuck is a chamber that voted on the bill and lost without passing it; failed is Congress.gov's
 * own marker. BOSS marks a supermajority in the way. A level the measure never has to reach is
 * [State.NOT_APPLICABLE].
 */
class LawLevels(bill: Bill) {
    enum class State { DONE, PENDING, STUCK, FAILED, NOT_APPLICABLE }

    data class Level(val number: Int, val name: String, val state: State, val boss: Boolean)

    val levels: List<Level>
    val citation: String = bill.citation
    val isResolution: Boolean = bill.isResolution
    /** The chamber it started in, which is the one it goes to first. */
    val origin: Chamber = bill.originChamber ?: Chamber.HOUSE
    /** The losing vote that left a chamber stuck, if one did. */
    var stoppedBy: Vote? = null
        private set

    init {
        val progress = BillProgress(bill)
        val texts = bill.actions.map { it.text.lowercase() }
        fun any(needles: List<String>) = texts.any { t -> needles.any { it in t } }
        fun chamberStep(chamber: Chamber) = progress.steps.firstOrNull { it.label.endsWith(chamber.title) }
        fun chamberState(chamber: Chamber): State {
            val step = chamberStep(chamber) ?: return State.NOT_APPLICABLE
            return when (step.state) {
                BillProgress.State.DONE -> State.DONE
                BillProgress.State.FAILED -> State.FAILED
                BillProgress.State.PENDING -> {
                    // Only the latest vote that could stop the bill counts.
                    val lost = bill.votes.firstOrNull { it.chamber == chamber && it.failureStopsTheBill }
                    if (lost != null && lost.outcome == Outcome.FAILED) {
                        if (stoppedBy == null) stoppedBy = lost
                        State.STUCK
                    } else {
                        State.PENDING
                    }
                }
            }
        }
        fun supermajority(chamber: Chamber) = bill.votes.any { it.chamber == chamber && it.threshold != VoteThreshold.MAJORITY }

        val introduced = if (progress.steps.firstOrNull()?.state == BillProgress.State.DONE) State.DONE else State.PENDING
        val house = chamberState(Chamber.HOUSE)
        val senate = chamberState(Chamber.SENATE)
        val reachedFloor = bill.votes.isNotEmpty() || house == State.DONE || senate == State.DONE
        val committee = if (reachedFloor || any(listOf("reported", "discharged"))) State.DONE else State.PENDING
        val other = if (origin == Chamber.HOUSE) Chamber.SENATE else Chamber.HOUSE
        val sameText = when {
            bill.chambersThatMustAct(origin, other).size < 2 -> State.NOT_APPLICABLE
            bill.canBecomeLaw ->
                if (any(listOf("presented to president", "cleared for white house", "became public law"))) State.DONE else State.PENDING
            else -> {
                val amended = texts.any { "passed/agreed to in" in it && "with an amendment" in it }
                val resolved = texts.any { "resolving differences" in it && "agree" in it }
                if (house == State.DONE && senate == State.DONE && (!amended || resolved)) State.DONE else State.PENDING
            }
        }
        val signed = when {
            !bill.canBecomeLaw -> State.NOT_APPLICABLE
            progress.steps.lastOrNull()?.let { it.label == "Became law" && it.state == BillProgress.State.DONE } == true -> State.DONE
            any(listOf("vetoed by president", "pocket veto")) -> State.FAILED
            else -> State.PENDING
        }
        val states = listOf(introduced, committee, house, senate, sameText, signed)
        val boss = listOf(false, false, supermajority(Chamber.HOUSE), supermajority(Chamber.SENATE), false, bill.canBecomeLaw)
        levels = NAMES.indices.map { i ->
            Level(i + 1, NAMES[i], states[i], boss[i] && states[i] != State.NOT_APPLICABLE)
        }
    }

    /** The levels in the order this measure meets them: the Senate first for a Senate bill. */
    private val ordered: List<Level>
        get() = if (origin != Chamber.SENATE) levels else levels.toMutableList().also { it[2] = levels[3]; it[3] = levels[2] }

    /** The run of done levels from the start, in meeting order, skipping ones that do not apply. */
    private val climbed: List<Level>
        get() {
            val run = mutableListOf<Level>()
            for (level in ordered) {
                if (level.state == State.NOT_APPLICABLE) continue
                if (level.state != State.DONE) break
                run += level
            }
            return run
        }

    /** How many levels it has climbed, in the order it meets them. */
    val reached: Int get() = climbed.size

    /** Every level this measure has to reach is done. */
    val isComplete: Boolean get() = levels.all { it.state == State.DONE || it.state == State.NOT_APPLICABLE }

    val isLaw: Boolean get() = levels[5].state == State.DONE

    /** Any level stuck or failed: the header's verdict is drawn in the nay colour. */
    val isBlocked: Boolean get() = levels.any { it.state == State.STUCK || it.state == State.FAILED }

    /** The header's verdict: `LAW`, `LEVEL 3 OF 6`, `STOPPED AT THE 60`, `FAILED IN THE HOUSE`. */
    val status: String
        get() {
            if (isLaw) return "LAW"
            if (isComplete) return "ADOPTED"
            levels.firstOrNull { it.state == State.FAILED }?.let {
                return if (it.number == 6) "VETOED" else "FAILED IN THE ${it.name.uppercase()}"
            }
            levels.firstOrNull { it.state == State.STUCK }?.let {
                return when (stoppedBy?.threshold) {
                    VoteThreshold.THREE_FIFTHS_SWORN -> "STOPPED AT THE 60"
                    VoteThreshold.TWO_THIRDS -> "SHORT OF TWO-THIRDS"
                    else -> "STUCK IN THE ${it.name.uppercase()}"
                }
            }
            return "LEVEL $reached OF 6"
        }

    /** `H.R. 1013 passed the House. Next: the Senate.` */
    val sentence: String
        get() {
            if (isLaw) return "$citation is law."
            if (isComplete) return "$citation was adopted."
            levels.firstOrNull { it.state == State.FAILED }?.let {
                return if (it.number == 6) "$citation was vetoed." else "$citation failed in the ${it.name}."
            }
            levels.firstOrNull { it.state == State.STUCK }?.let { return "$citation is stuck in the ${it.name}." }
            val done = climbed.lastOrNull()
            val next = ordered.firstOrNull { it.state != State.DONE && it.state != State.NOT_APPLICABLE }
            val did = when (done?.name) {
                "Introduced" -> "was introduced"
                "Committee" -> "cleared committee"
                "House" -> if (isResolution) "was agreed to in the House" else "passed the House"
                "Senate" -> if (isResolution) "was agreed to in the Senate" else "passed the Senate"
                "Same text" -> "cleared both chambers in the same text"
                else -> "has not been introduced"
            }
            next ?: return "$citation $did."
            val what = when (next.name) {
                "Introduced" -> "introduction"
                "Committee" -> "committee"
                "House" -> "the House"
                "Senate" -> "the Senate"
                "Same text" -> "the same text in both chambers"
                else -> "the President's signature"
            }
            return "$citation $did. Next: $what."
        }

    companion object {
        val NAMES = listOf("Introduced", "Committee", "House", "Senate", "Same text", "Signed")
    }
}
