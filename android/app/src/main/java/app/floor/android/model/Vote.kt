package app.floor.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.format.DateTimeParseException

// The API contract (`apps/api/openapi.json`) for the Finals feed, mirroring the iOS `Models`
// package: `Vote.swift`, `Lists.swift`, `Enums.swift` and the measure from `Member.swift`.

@Serializable
enum class Chamber {
    @SerialName("house") HOUSE,
    @SerialName("senate") SENATE;

    /** `House` or `Senate`. */
    val title: String get() = if (this == HOUSE) "House" else "Senate"
}

/** `ELECTION` is a Speaker election, where members vote for a candidate instead of yea or nay. */
@Serializable
enum class VoteKind {
    @SerialName("question") QUESTION,
    @SerialName("election") ELECTION,
}

@Serializable
enum class VoteState {
    @SerialName("scheduled") SCHEDULED,
    @SerialName("open") OPEN,
    @SerialName("final") FINAL,
}

/** How many votes a question needs. Mirrors `votesNeeded` in `@floor/shared`. */
@Serializable
enum class VoteThreshold {
    @SerialName("majority") MAJORITY,
    @SerialName("three_fifths_sworn") THREE_FIFTHS_SWORN,
    @SerialName("two_thirds") TWO_THIRDS;

    fun votesNeeded(voting: Int, sworn: Int = 100): Int = when (this) {
        MAJORITY -> voting / 2 + 1
        TWO_THIRDS -> (voting * 2 + 2) / 3
        THREE_FIFTHS_SWORN -> (sworn * 3 + 4) / 5
    }
}

@Serializable
data class VoteTotals(val yea: Int, val nay: Int, val present: Int, val notVoting: Int) {
    /** Members who cast yea, nay or present. */
    val voting: Int get() = yea + nay + present
}

/** One candidate's total in a Speaker election. */
@Serializable
data class Candidate(val name: String, val total: Int)

/** One line on what a kind of vote is, written by hand, with the rule it rests on. */
@Serializable
data class VoteExplainer(val kind: String, val text: String, val source: String)

@Serializable
data class Vote(
    val id: String,
    val kind: VoteKind,
    val chamber: Chamber,
    val congress: Int,
    val session: Int,
    val rollNumber: Int? = null,
    val question: String,
    val billId: String? = null,
    val nominationId: String? = null,
    /** How the chamber cited the measure on the roll call, e.g. `H CON RES 14` or `PN1093-3`. */
    val billRef: String? = null,
    /** When the roll call closed, ISO 8601. See [occurredAtInstant]. */
    val occurredAt: String? = null,
    val state: VoteState,
    val threshold: VoteThreshold,
    val totals: VoteTotals,
    /** Empty unless [kind] is [VoteKind.ELECTION]. */
    val candidates: List<Candidate> = emptyList(),
    /**
     * How the chamber recorded the outcome, e.g. `Passed`. On a Speaker election it is the name of
     * the candidate who led *that ballot*, which is not the same as being elected: see [electedSpeaker].
     */
    val result: String? = null,
    /** nil for a question the API has no line for. */
    val explainer: VoteExplainer? = null,
) {
    /** Votes needed to pass given who has voted so far. */
    val votesNeeded: Int get() = threshold.votesNeeded(voting = totals.voting)

    /** [occurredAt] parsed, or null when the roll call has no timestamp yet. */
    val occurredAtInstant: Instant?
        get() = occurredAt?.let {
            try {
                Instant.parse(it)
            } catch (_: DateTimeParseException) {
                null
            }
        }

    /** The candidate with the most votes on this ballot, or null for a question vote. */
    val leadingCandidate: Candidate?
        get() = if (kind == VoteKind.ELECTION) candidates.maxByOrNull { it.total } else null

    /**
     * The candidate elected Speaker on this ballot, or null if it settled nothing. A Speaker needs
     * more than half the votes cast *for a person* (HANDOFF lesson 16).
     */
    val electedSpeaker: Candidate?
        get() {
            val leader = leadingCandidate ?: return null
            val castForAPerson = candidates.sumOf { it.total }
            return if (leader.total * 2 > castForAPerson) leader else null
        }
}

/** Just enough about the bill or nomination a vote was on to label it in a list. */
@Serializable
data class MeasureSummary(
    val id: String,
    val kind: Kind,
    /** As the chamber cites it: `H.R. 1013`, `PN1093-3`. */
    val citation: String,
    /** A bill's short title where it has one, else its full title; a nomination's nominee. */
    val title: String,
    /** A bill's CRS policy area; null for a nomination or a bill CRS has not classified. */
    val policyArea: String? = null,
    /** A bill's sponsor; null for a nomination, and from an API older than v0.2.57. */
    val sponsor: Sponsor? = null,
    /**
     * The opening of a bill's CRS summary, its title line removed, cut at a sentence end (about 320
     * characters at most). CRS's text, not AI. Null when CRS has none.
     */
    val summaryLead: String? = null,
    /** A nomination's position: `United States Circuit Judge for the Tenth Circuit`. Null for a bill. */
    val position: String? = null,
    /** For a House rule ("Providing for consideration of the bill (H.R. 2102) ..."), the bill it names. */
    val forBillId: String? = null,
    /** A bill's stage as sent, so one this build does not know, or none, reads as a null [stage]. */
    @SerialName("stage") val stageRaw: String? = null,
) {
    /** Where the bill stands (as `BillListItem.stage`); null for a nomination or a bill not yet staged. */
    val stage: BillStage? get() = BillStage.of(stageRaw)

    @Serializable
    enum class Kind {
        @SerialName("bill") BILL,
        @SerialName("nomination") NOMINATION,
    }
}

/** A bill's sponsor as [MeasureSummary] carries it: enough for `Sponsor Bilirakis (R-FL)`. */
@Serializable
data class Sponsor(val bioguideId: String, val lastName: String, val party: String, val state: String)

/**
 * One row of `GET /v1/votes`: a final vote and what it was on, with nobody's position. [partyTotals]
 * is new in v0.2.57; an older API sends none, which decodes as null.
 */
@Serializable
data class RecentVote(val vote: Vote, val measure: MeasureSummary? = null, val partyTotals: List<PartyTotals>? = null) {
    val id: String get() = vote.id
}

/** `GET /v1/votes`: the most recent final votes, newest first. */
@Serializable
data class RecentVotes(val votes: List<RecentVote>)
