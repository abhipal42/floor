package app.floor.android.home

import app.floor.android.model.Outcome
import app.floor.android.model.PartyTotals
import app.floor.android.model.Position
import app.floor.android.model.VoteKind
import app.floor.android.model.VoteStep
import app.floor.android.model.VoteThreshold
import app.floor.android.model.line
import app.floor.android.model.outcome
import app.floor.android.model.outcomeWord
import java.time.Instant
import kotlin.math.abs

/**
 * The catch-up deck (iOS `CatchUp`): which five finals it deals, and the one computed line each
 * card carries.
 *
 * **The selection rule**, in order of preference:
 * 1. Votes that **failed despite more yeas than nays**, the ones a bare score misreads.
 * 2. Then the **closest margins against their own threshold**, either way.
 * 3. Then the **most recent**, and finally the vote ID, so the same feed always deals the same deck.
 *
 * Only final yea/nay questions are eligible: a Speaker ballot has no threshold line to sit near.
 */
object CatchUp {
    fun select(items: List<FeedItem>, count: Int = 5): List<FeedItem> =
        items.filter { it.vote.kind == VoteKind.QUESTION && it.vote.outcome != null && it.vote.line != null }
            .sortedWith(order)
            .take(count)

    private val order: Comparator<FeedItem> = compareByDescending<FeedItem> { failedDespiteMajority(it) }
        .thenBy { abs(it.vote.line?.margin ?: Int.MAX_VALUE) }
        .thenByDescending { it.vote.occurredAtInstant ?: Instant.MIN }
        .thenByDescending { it.vote.id }

    fun failedDespiteMajority(item: FeedItem): Boolean =
        item.vote.outcome == Outcome.FAILED && item.vote.totals.yea > item.vote.totals.nay

    /** The oldest final in the deck: the header's "since Sep 29". */
    fun since(deck: List<FeedItem>): Instant? = deck.mapNotNull { it.vote.occurredAtInstant }.minOrNull()

    /**
     * What a procedural vote was for, after the measure's summary: the first sentence of the vote
     * kind's own explainer ("A vote to end debate on whether to take up a bill."). Null for a vote
     * that decided something, or one with no explainer.
     */
    fun stepSentence(item: FeedItem): String? {
        if (!VoteStep.isProcedural(item.vote)) return null
        val text = item.vote.explainer?.text?.trim() ?: return null
        val end = text.indexOf(". ")
        return if (end < 0) text else text.substring(0, end + 1)
    }

    /**
     * The twist: one sentence computed from the numbers on the card and nothing else. The first rule
     * that applies wins: the record contradicts the count; failed with more yeas than nays; carried
     * with three or fewer against; your members split; within five of the line; else how far past
     * or short it finished.
     */
    fun twist(item: FeedItem): String {
        val vote = item.vote
        val line = vote.line ?: return vote.question
        val outcome = vote.outcome ?: return vote.question
        val chamber = vote.chamber.title
        val word = vote.outcomeWord
        if (line.contradicted && word != null) {
            return "${line.yea}–${line.nay}, recorded as ${word.lowercase()}: the chamber's record decides, not the count."
        }
        val short = line.short
        if (failedDespiteMajority(item) && short != null) {
            return when (line.threshold) {
                VoteThreshold.TWO_THIRDS -> "Won the room by ${line.yea - line.nay} and fell $short short of two-thirds."
                VoteThreshold.THREE_FIFTHS_SWORN -> "A majority voted yes and it still lost: $short short of ${line.needed}."
                VoteThreshold.MAJORITY -> "More yeas than nays, and it still lost: $short short of a majority of those voting."
            }
        }
        if (outcome == Outcome.CARRIED && line.nay <= 3) {
            if (line.nay == 0) return "Not one vote against in the entire $chamber."
            return "${word(line.nay).replaceFirstChar(Char::uppercase)} vote${if (line.nay == 1) "" else "s"} against in the entire $chamber."
        }
        val sides = item.positions.filter { it.position == Position.YEA || it.position == Position.NAY }
        if (sides.map { it.position }.toSet().size > 1) {
            val who = sides.joinToString(", ") { "${it.member.lastName} ${it.position.name.lowercase()}" }
            return "Your ${if (vote.chamber.title == "Senate") "senators" else "members"} split: $who."
        }
        val over = line.over
        if (over != null && over <= 5) {
            return if (over == 0) "Not a vote to spare: exactly the ${line.needed} it needed."
            else "Cleared the line by $over: ${line.yea} yea against the ${line.needed} it needed."
        }
        if (short != null && short <= 5) {
            return "${word(short).replaceFirstChar(Char::uppercase)} vote${if (short == 1) "" else "s"} from carrying: ${line.yea} yea against the ${line.needed} it needed."
        }
        if (over != null) {
            return if (line.threshold == VoteThreshold.MAJORITY) "Won by ${line.yea - line.nay}, $over past the line."
            else "Cleared ${if (line.threshold == VoteThreshold.TWO_THIRDS) "two-thirds" else "sixty"} with $over to spare."
        }
        return "Fell ${short ?: 0} short of the ${line.needed} it needed."
    }

    private val words = listOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten")

    private fun word(n: Int): String = words.getOrNull(n) ?: "$n"

    /** `R 53–0`, one per party that voted, in the API's order: the card's party rows and the Bills footer. */
    fun partyLines(totals: List<PartyTotals>): List<Pair<String, String>> =
        totals.filter { it.yea + it.nay > 0 }.map { it.party to "${it.yea}–${it.nay}" }
}
