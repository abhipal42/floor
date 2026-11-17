package app.floor.android.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The Bills half of the API contract (`apps/api/openapi.json`): `GET /v1/bills/{id}`, its
// `/analysis` and `/share`, `GET /v1/topics`, `GET /v1/topics/{name}/bills`, `GET /v1/search`,
// `GET /v1/schedule` and the contact on `GET /v1/members/{id}`, mirroring iOS `Bill.swift`,
// `BillAnalysis.swift`, `Topics.swift`, `Schedule.swift` and `Devices.swift`.
//
// A stage or schedule category this build does not know reads as null or OTHER rather than failing
// the response (as iOS decodes them): such fields are kept as the API's string and read through a
// property.

/** The most recent thing that happened to a bill or nomination. [on] is a calendar day, `YYYY-MM-DD`. */
@Serializable
data class LatestAction(val on: String, val text: String)

/** A Congressional Budget Office cost estimate. */
@Serializable
data class CboEstimate(val title: String, val url: String, val pubDate: String)

/** One step in a bill's history, newest first as the API returns them. Null [chamber]: a Congress.gov marker. */
@Serializable
data class BillAction(val actedOn: String, val chamber: Chamber? = null, val text: String)

/**
 * Where a measure stands on the road to law, as the worker derives it (`apps/worker/src/stage.ts`).
 * [ADOPTED] is a resolution agreed to; [FAILED] a chamber voting it down; [VETOED] not overridden.
 */
enum class BillStage(val raw: String) {
    INTRODUCED("introduced"),
    PASSED_HOUSE("passed_house"),
    PASSED_SENATE("passed_senate"),
    PASSED_BOTH("passed_both"),
    TO_PRESIDENT("to_president"),
    LAW("law"),
    VETOED("vetoed"),
    FAILED("failed"),
    ADOPTED("adopted");

    /** Nothing more will happen to the measure. */
    val isSettled: Boolean get() = this in setOf(LAW, VETOED, FAILED, ADOPTED)

    /** Steps reached on the five-step road; null for a failed measure or an adopted resolution. */
    val roadSteps: Int?
        get() = when (this) {
            INTRODUCED -> 1
            PASSED_HOUSE, PASSED_SENATE -> 2
            PASSED_BOTH -> 3
            TO_PRESIDENT, VETOED -> 4
            LAW -> 5
            FAILED, ADOPTED -> null
        }

    companion object {
        /** Null for a stage this build does not know. */
        fun of(raw: String?): BillStage? = entries.firstOrNull { it.raw == raw }
    }
}

/** `GET /v1/bills/{id}`. */
@Serializable
data class Bill(
    val id: String,
    val congress: Int,
    /** `hr`, `s`, `hconres` and so on. */
    val type: String,
    val number: Int,
    /** As the chamber cites it, e.g. `H.Con.Res. 14`, sent by the API. */
    val citation: String,
    val title: String,
    /** Null when the bill has no short title of its own; fall back to [title]. */
    val shortTitle: String? = null,
    val sponsor: Member? = null,
    val introducedOn: String? = null,
    val originChamber: Chamber? = null,
    val policyArea: String? = null,
    /** Latest Congressional Research Service summary, plain text. */
    val summary: String? = null,
    /** The legislative stage that summary describes, e.g. `Passed Senate`. */
    val summaryStage: String? = null,
    val latestAction: LatestAction? = null,
    val cboEstimates: List<CboEstimate> = emptyList(),
    val actions: List<BillAction> = emptyList(),
    /** Newest first. */
    val votes: List<Vote> = emptyList(),
    /** The plain short label a bill list gives it; null in a response from before v0.2.29. */
    val label: String? = null,
    @SerialName("stage") val stageRaw: String? = null,
) {
    val stage: BillStage? get() = BillStage.of(stageRaw)

    /** Its short title where it has one, its full title otherwise. */
    val displayTitle: String get() = shortTitle ?: title

    /** What a vote on this bill was about, as a feed card names it. */
    val measure: MeasureSummary get() = MeasureSummary(id, MeasureSummary.Kind.BILL, citation, displayTitle, policyArea)

    /** A resolution is agreed to rather than passed, and most never reach the President. */
    val isResolution: Boolean get() = type in setOf("hres", "sres", "hconres", "sconres")

    /** Only bills and joint resolutions can become law. */
    val canBecomeLaw: Boolean get() = type in setOf("hr", "s", "hjres", "sjres")

    /** Which chambers have to act. A simple resolution never leaves the one it started in. */
    fun chambersThatMustAct(origin: Chamber, other: Chamber): List<Chamber> =
        if (type in setOf("hres", "sres")) listOf(origin) else listOf(origin, other)
}

/** The filters on a topic page. "Stalled" is unsettled with no action in 90 days. */
enum class TopicFilter(val raw: String, val label: String) {
    ALL("all", "All"),
    MOVING("moving", "Moving"),
    LAW("law", "Law"),
    STALLED("stalled", "Stalled"),
}

/** One row of a bill list: a topic page or search results. */
@Serializable
data class BillListItem(
    val id: String,
    val congress: Int,
    val type: String,
    val number: Int,
    val citation: String,
    /** A plain short label; the full title is [title]. */
    val label: String,
    val title: String,
    val policyArea: String? = null,
    @SerialName("stage") val stageRaw: String? = null,
    /** Not settled and no action in 90 days, computed by the API when it answered. */
    val stalled: Boolean,
    val latestAction: LatestAction? = null,
    val hasFloorVote: Boolean,
) {
    val stage: BillStage? get() = BillStage.of(stageRaw)
}

/** A topic: one of the 32 policy areas CRS assigns, one per bill. */
@Serializable
data class Topic(
    val name: String,
    val bills: Int,
    val billsWithFloorVote: Int,
    val latestActionOn: String? = null,
) {
    companion object {
        /** The 32 CRS policy areas, spelled and ordered as the API's `POLICY_AREAS`. */
        val names = listOf(
            "Agriculture and Food", "Animals", "Armed Forces and National Security", "Arts, Culture, Religion",
            "Civil Rights and Liberties, Minority Issues", "Commerce", "Congress", "Crime and Law Enforcement",
            "Economics and Public Finance", "Education", "Emergency Management", "Energy", "Environmental Protection",
            "Families", "Finance and Financial Sector", "Foreign Trade and International Finance",
            "Government Operations and Politics", "Health", "Housing and Community Development", "Immigration",
            "International Affairs", "Labor and Employment", "Law", "Native Americans",
            "Public Lands and Natural Resources", "Science, Technology, Communications", "Social Sciences and History",
            "Social Welfare", "Sports and Recreation", "Taxation", "Transportation and Public Works",
            "Water Resources Development",
        )

        /** The canonical spelling of a topic, case and spacing ignored; null when not one of the 32. */
        fun canonical(name: String): String? {
            val key = name.trim().split(Regex("\\s+")).joinToString(" ").lowercase()
            return names.firstOrNull { it.lowercase() == key }
        }
    }
}

/** `GET /v1/topics`: all 32, in a fixed order, including empty ones. */
@Serializable
data class TopicList(val congress: Int, val topics: List<Topic>)

/** `GET /v1/topics/{name}/bills`: one page, newest action first. */
@Serializable
data class TopicBills(
    val congress: Int,
    val topic: Topic,
    val filter: String,
    val bills: List<BillListItem>,
    /** Pass back as `cursor` for the next page; null on the last. */
    val nextCursor: String? = null,
)

/** `GET /v1/search?q=`: members, bills and topics, grouped. */
@Serializable
data class SearchResults(
    val query: String,
    /** The query read as a bill number: [bills] holds exact matches and nothing else is searched. */
    val billNumber: Boolean,
    val members: List<Member> = emptyList(),
    val bills: List<BillListItem> = emptyList(),
    val topics: List<Topic> = emptyList(),
)

/** `GET /v1/bills/{id}/share`: what the share sheet sends. */
@Serializable
data class BillShare(val url: String, val text: String, val kicker: String)

// MARK: - AI analysis

/** Where an AI line came from: a paragraph of the CRS summary (1-based), quoted. */
@Serializable
data class AnalysisCitation(val paragraph: Int, val quote: String, val section: String? = null)

/** One AI-written line. Always AI and always cited. */
@Serializable
data class AnalysisClaim(val text: String, val ai: Boolean = true, val citations: List<AnalysisCitation> = emptyList())

/** The CRS summary an analysis was written from. */
@Serializable
data class AnalysisSource(
    val kind: String,
    /** The summary version analysed, e.g. `Public Law`. */
    val stage: String,
    val paragraphs: List<String>,
    /** The bill's summary has changed since; a new analysis is pending. */
    val stale: Boolean,
) {
    /** The paragraph a citation points at, or null if it is out of range. */
    fun paragraph(citation: AnalysisCitation): String? = paragraphs.getOrNull(citation.paragraph - 1)
}

/** `GET /v1/bills/{id}/analysis`; its 404 means "none yet". [disclaimer] goes wherever it is shown. */
@Serializable
data class BillAnalysis(
    val billId: String,
    val ai: Boolean = true,
    val label: String,
    val disclaimer: String,
    val source: AnalysisSource,
    val model: String,
    val verifierModel: String? = null,
    val promptVersion: String,
    val generatedAt: String,
    val provisions: List<AnalysisClaim> = emptyList(),
    val affectedGroups: List<AnalysisClaim> = emptyList(),
    val impact: List<AnalysisClaim> = emptyList(),
    /** Null when no purpose line survived verification. */
    val purpose: AnalysisClaim? = null,
)

// MARK: - Schedule

/** How the House plans to take an item up. Anything else, including every Senate item, is [OTHER]. */
enum class ScheduleCategory { RULE, SUSPENSION, OTHER }

@Serializable
data class ScheduleItem(
    @SerialName("category") val categoryRaw: String,
    val categoryText: String = "",
    /** Null for a resolution not yet numbered, or a bill not in Floor's catalog yet. */
    val billId: String? = null,
    /** The citation, e.g. `H.R. 5267`. */
    val label: String,
    val title: String,
    /** What the source printed for the item. */
    val sourceText: String = "",
    val policyArea: String? = null,
    @SerialName("stage") val stageRaw: String? = null,
    val latestAction: LatestAction? = null,
    val addedAt: String? = null,
    /** Set once the item was taken off the week's list. */
    val removedAt: String? = null,
) {
    val category: ScheduleCategory
        get() = when (categoryRaw) {
            "rule" -> ScheduleCategory.RULE
            "suspension" -> ScheduleCategory.SUSPENSION
            else -> ScheduleCategory.OTHER
        }

    /** Null until staged, and for a stage newer than this build. */
    val stage: BillStage? get() = BillStage.of(stageRaw)

    /** `Placed on the Union Calendar, Calendar No. 702 · Oct 29`: the latest step, as a row says it. */
    val latestLine: String?
        get() {
            val action = latestAction ?: return null
            val text = action.text.trim('.', ' ')
            return listOfNotNull(text, Formats.monthDay(action.on)).joinToString(" · ")
        }
}

/** One day the Senate meets, from senate.gov and the Congressional Record's Daily Digest. */
@Serializable
data class SenateMeeting(
    /** `YYYY-MM-DD`. */
    val date: String,
    val convenesAt: String? = null,
    /** The Senate meets for seconds and does no business. */
    val proForma: Boolean = false,
    /** The Daily Digest's heading, e.g. `3 p.m., Monday, November 16`. */
    val heading: String? = null,
    /** The Daily Digest's program, in its own words; null until the Record is out. */
    val program: String? = null,
    val recordIssue: String? = null,
)

/**
 * `GET /v1/schedule`: the week ahead. The House's list of what may come up, and when the Senate
 * meets with the Daily Digest's program for that day. Listed is not scheduled: items move.
 */
@Serializable
data class Schedule(
    /** The Monday, `YYYY-MM-DD`. */
    val week: String,
    val house: House = House(),
    val senate: Senate? = null,
    /** Why [senate] is null. */
    val senateReason: String? = null,
    val sourceUpdatedAt: String? = null,
) {
    @Serializable
    data class House(
        /** True when the House has published a list for the week; null when it has not. */
        val inSession: Boolean? = null,
        val items: List<ScheduleItem> = emptyList(),
    )

    @Serializable
    data class Senate(val meetings: List<SenateMeeting> = emptyList(), val items: List<ScheduleItem> = emptyList())

    /** Where a bill is on this week's lists, if it is (and was not taken off). */
    fun listing(billId: String): Pair<Chamber, ScheduleItem>? {
        house.items.firstOrNull { it.billId == billId && it.removedAt == null }?.let { return Chamber.HOUSE to it }
        senate?.items?.firstOrNull { it.billId == billId && it.removedAt == null }?.let { return Chamber.SENATE to it }
        return null
    }

    /** `Nov 16–20`: Monday to Friday, the days the House lists. */
    val weekRange: String get() = weekRange(week)

    companion object {
        /** `Nov 16–20`, or `Nov 30 – Dec 4` across a month; the text itself when it is not a day. */
        fun weekRange(week: String): String {
            val monday = Formats.day(week) ?: return week
            val friday = monday.plusDays(4)
            val month = java.time.format.DateTimeFormatter.ofPattern("MMM", java.util.Locale.US)
            val start = "${monday.format(month)} ${monday.dayOfMonth}"
            return if (monday.month == friday.month) "$start–${friday.dayOfMonth}" else "$start – ${friday.format(month)} ${friday.dayOfMonth}"
        }

        /**
         * The Monday (`YYYY-MM-DD`) of the week [at] falls in, in Washington, [offsetWeeks] weeks on:
         * the API's own rule (`scheduleWeek` in apps/api/src/app.ts), so the app asks for the week it shows.
         */
        fun monday(at: java.time.Instant, offsetWeeks: Int = 0): String {
            val day = at.atZone(java.time.ZoneId.of("America/New_York")).toLocalDate()
            val back = (day.dayOfWeek.value - 1).toLong() // Monday is 1
            return day.minusDays(back).plusWeeks(offsetWeeks.toLong()).toString()
        }
    }
}

// MARK: - Members

/** How to reach a member's office. Every field can be null. */
@Serializable
data class MemberContact(
    val phone: String? = null,
    val contactForm: String? = null,
    val website: String? = null,
    val office: String? = null,
    val address: String? = null,
)
