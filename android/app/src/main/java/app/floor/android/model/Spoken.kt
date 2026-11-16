package app.floor.android.model

/**
 * What TalkBack reads, as sentences, ported from iOS `Spoken.swift`. A card is read as one
 * sentence rather than its pieces ("YEA", "295", "PASSED"...).
 *
 * The members half (`your rep Doggett voted nay`) arrives with the delegation in a later phase;
 * the Finals feed carries no positions until then.
 */
object Spoken {
    /**
     * `H.R. 1013, On Passage, passed, 295 yea to 128 nay. Retirement Fairness Act. House, Nov 11,
     * needed 212.`
     *
     * @param day the date as the card prints it, already formatted, so this stays free of the clock.
     */
    fun scoreboard(vote: Vote, title: String, citation: String?, day: String? = null): String {
        // No citation (a procedural vote, a Speaker ballot): the question leads.
        val lead = listOfNotNull(citation, vote.question, result(vote)).filter { it.isNotEmpty() }.joinToString(", ")
        val detail = mutableListOf<String>()
        if (title != vote.question && title.isNotEmpty()) detail += sentence(title)
        val context = listOfNotNull(vote.chamber.title, day).toMutableList()
        vote.line?.let { if (vote.state != VoteState.SCHEDULED) context += "needed ${it.needed}" }
        detail += context.joinToString(", ")
        return (listOf(sentence(lead)) + detail.map(::sentence)).joinToString(" ")
    }

    /**
     * How the vote came out, in words: `passed, 295 yea to 128 nay`, `agreed to, 62 yea to 21 nay`.
     * Each number names its side.
     */
    fun result(vote: Vote): String {
        if (vote.kind == VoteKind.ELECTION) return electionResult(vote)
        val score = "${vote.totals.yea} yea to ${vote.totals.nay} nay"
        return when (vote.state) {
            VoteState.SCHEDULED -> "scheduled"
            VoteState.OPEN -> "voting now, $score so far"
            VoteState.FINAL -> {
                val word = vote.outcomeWord ?: return "final, $score"
                val verb = if (word == "AGREED") "agreed to" else word.lowercase()
                "$verb, $score"
            }
        }
    }

    private fun electionResult(vote: Vote): String {
        val leaders = vote.candidates.sortedByDescending { it.total }
        val first = leaders.firstOrNull()
            ?: return if (vote.state == VoteState.SCHEDULED) "scheduled" else "no ballots counted"
        return when (vote.state) {
            VoteState.SCHEDULED -> "scheduled"
            VoteState.OPEN -> "voting now, ${first.name} leads with ${first.total}"
            VoteState.FINAL -> {
                vote.electedSpeaker?.let { return "${it.name} elected Speaker with ${it.total}" }
                // Leading a ballot is not winning it (HANDOFF lesson 16), and a tie has no leader.
                val tied = leaders.filter { it.total == first.total }
                if (tied.size > 1) {
                    return "${list(tied.map { it.name })} tied with ${first.total}; nobody was elected on this ballot"
                }
                val runnerUp = leaders.getOrNull(1)?.let { ", ${it.name} had ${it.total}" } ?: ""
                "${first.name} led with ${first.total}$runnerUp; nobody was elected on this ballot"
            }
        }
    }

    private fun list(names: List<String>): String =
        if (names.size == 1) names[0] else names.dropLast(1).joinToString(", ") + " and " + names.last()

    private fun sentence(text: String): String =
        if (text.isEmpty() || text.last() in ".!?") text else "$text."
}
