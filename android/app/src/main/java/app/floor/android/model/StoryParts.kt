package app.floor.android.model

/**
 * The colour group a story's band takes (iOS `TopicGroup`): one per icon. The 32 CRS policy areas
 * map onto these in [ofPolicyArea], the same table on both platforms.
 */
enum class TopicGroup {
    DEFENSE, MONEY, COURTS, HEALTH, LAND, RIGHTS, GOV, OTHER;

    companion object {
        /** Every CRS policy area (`Topic.names`) and its group. One table; iOS holds the same rows. */
        val table: Map<String, TopicGroup> = mapOf(
            "Agriculture and Food" to LAND,
            "Animals" to LAND,
            "Armed Forces and National Security" to DEFENSE,
            "Arts, Culture, Religion" to RIGHTS,
            "Civil Rights and Liberties, Minority Issues" to RIGHTS,
            "Commerce" to MONEY,
            "Congress" to GOV,
            "Crime and Law Enforcement" to COURTS,
            "Economics and Public Finance" to MONEY,
            "Education" to HEALTH,
            "Emergency Management" to DEFENSE,
            "Energy" to LAND,
            "Environmental Protection" to LAND,
            "Families" to HEALTH,
            "Finance and Financial Sector" to MONEY,
            "Foreign Trade and International Finance" to MONEY,
            "Government Operations and Politics" to GOV,
            "Health" to HEALTH,
            "Housing and Community Development" to HEALTH,
            "Immigration" to RIGHTS,
            "International Affairs" to DEFENSE,
            "Labor and Employment" to MONEY,
            "Law" to COURTS,
            "Native Americans" to RIGHTS,
            "Public Lands and Natural Resources" to LAND,
            "Science, Technology, Communications" to OTHER,
            "Social Sciences and History" to OTHER,
            "Social Welfare" to HEALTH,
            "Sports and Recreation" to OTHER,
            "Taxation" to MONEY,
            "Transportation and Public Works" to LAND,
            "Water Resources Development" to LAND,
        )

        fun ofPolicyArea(area: String?): TopicGroup = area?.let { table[Topic.canonical(it) ?: it] } ?: OTHER

        /** A bill by its policy area; a nomination is courts when its position names a judge or court, else gov. */
        fun of(measure: MeasureSummary?): TopicGroup = when (measure?.kind) {
            null -> OTHER
            MeasureSummary.Kind.BILL -> ofPolicyArea(measure.policyArea)
            MeasureSummary.Kind.NOMINATION -> {
                val p = measure.position.orEmpty().lowercase()
                if ("judge" in p || "court" in p || "justice" in p) COURTS else GOV
            }
        }
    }
}

/**
 * The kinds of vote that move a measure along without deciding it (iOS `VoteStep`), and each
 * kind's name on a story's step. The kinds are the `explainer.kind` values the API emits
 * (`apps/api/src/votekinds.ts`); every one is in exactly one of [procedural] and [substantive].
 */
object VoteStep {
    val procedural: Set<String> = setOf(
        "cloture", "cloture_motion_to_proceed", "motion_to_proceed", "previous_question", "rule", "consideration",
        "recommit", "commit", "refer", "table", "table_reconsider", "reconsider", "discharge", "adjourn",
        "quorum_call", "attendance", "point_of_order", "appeal", "go_to_conference", "instruct_conferees",
    )

    val substantive: Set<String> = setOf(
        "suspension", "nomination", "treaty", "passage", "joint_resolution", "resolution", "concurrent_resolution",
        "veto_override", "conference_report", "amendment", "concur", "concur_with_amendment", "speaker_election",
    )

    private val names: Map<String, String> = mapOf(
        "cloture" to "Cloture",
        "cloture_motion_to_proceed" to "Cloture to proceed",
        "motion_to_proceed" to "Motion to proceed",
        "previous_question" to "Previous question",
        "rule" to "Rule for debate",
        "consideration" to "Consideration",
        "recommit" to "Motion to recommit",
        "commit" to "Motion to commit",
        "refer" to "Motion to refer",
        "table" to "Motion to table",
        "table_reconsider" to "Tabling reconsideration",
        "reconsider" to "Reconsideration",
        "discharge" to "Discharge petition",
        "adjourn" to "Adjournment",
        "quorum_call" to "Quorum call",
        "attendance" to "Attendance",
        "point_of_order" to "Point of order",
        "appeal" to "Appeal of the chair",
        "go_to_conference" to "Go to conference",
        "instruct_conferees" to "Instruct conferees",
        "suspension" to "Passage under suspension",
        "nomination" to "Confirmation",
        "treaty" to "Ratification",
        "passage" to "Passage",
        "joint_resolution" to "Passage",
        "resolution" to "Adoption",
        "concurrent_resolution" to "Adoption",
        "veto_override" to "Veto override",
        "conference_report" to "Conference report",
        "amendment" to "Amendment",
        "concur" to "Agreeing to the Senate's changes",
        "concur_with_amendment" to "Counter-amendment",
        "speaker_election" to "Speaker election",
    )

    /** A vote with no explainer counts as deciding something, so it is never hidden in a mini row. */
    fun isProcedural(vote: Vote): Boolean = vote.explainer?.kind in procedural

    /** `Rule for debate`, `Passage`, `Cloture`; the question's own words for a kind with no explainer. */
    fun name(vote: Vote): String = vote.explainer?.kind?.let { names[it] } ?: vote.questionKind
}
