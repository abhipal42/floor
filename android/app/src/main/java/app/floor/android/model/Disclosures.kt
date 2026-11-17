package app.floor.android.model

import kotlinx.serialization.Serializable

/**
 * `GET /v1/members/{id}/disclosures` (iOS `Disclosures.swift`): a member's financial disclosures as
 * filed, in ranges. Off, the route answers `{ enabled: false, reason }` and the screen shows the
 * reason as a visible placeholder. Nothing here is a total, and the app never adds values up
 * (product rule "Ranges, not net worth"). Lists are read element by element ([LossyList]).
 */
@Serializable
data class Disclosures(
    val enabled: Boolean = false,
    val reason: String? = null,
    val deadlineDays: Int? = null,
    val annual: AnnualDisclosure? = null,
    @Serializable(with = LossyTrades::class) val trades: List<DisclosedTrade> = emptyList(),
    @Serializable(with = LossyPaper::class) val paperFilings: List<PaperFiling> = emptyList(),
) {
    /** The deadline the API states, else the STOCK Act's 45 days. */
    val deadline: Int get() = deadlineDays ?: 45

    companion object {
        /** What an API without the route (its 404) reads as: off, with no reason given. */
        const val UNAVAILABLE_BODY = """{"enabled":false}"""
    }
}

@Serializable
data class AnnualDisclosure(
    val year: Int? = null,
    val filedAt: String? = null,
    val amendment: Boolean = false,
    val sourceUrl: String? = null,
    /** Floor's AI transcribed these rows from a paper filing: shown with the AI tag (lesson 73). */
    val transcribed: Boolean = false,
    @Serializable(with = LossyAssets::class) val assets: List<DisclosedAsset> = emptyList(),
)

/** One asset line, its value the filed range, never a number. */
@Serializable
data class DisclosedAsset(
    val name: String,
    val type: String? = null,
    val typeCode: String? = null,
    val account: String? = null,
    val owner: String? = null,
    val value: String? = null,
    val incomeType: String? = null,
    val income: String? = null,
    val description: String? = null,
)

/** One trade from a periodic transaction report, in a range. */
@Serializable
data class DisclosedTrade(
    val type: String? = null,
    val typeFiled: String? = null,
    val asset: String,
    val ticker: String? = null,
    val assetType: String? = null,
    val owner: String? = null,
    val amount: String? = null,
    val transactedAt: String? = null,
    val notifiedAt: String? = null,
    val filedAt: String? = null,
    val daysToFile: Int? = null,
    val pastDeadline: Boolean = false,
    val comment: String? = null,
    val sourceUrl: String? = null,
) {
    /** `Bought`, `Sold`, `Sold part`, `Exchanged`. */
    val verb: String
        get() = when (type?.lowercase()) {
            "buy" -> "Bought"
            "sell" -> if (typeFiled?.lowercase()?.contains("partial") == true) "Sold part" else "Sold"
            "exchange" -> "Exchanged"
            else -> typeFiled ?: "Traded"
        }
}

/** A filing only on paper, linked rather than read. */
@Serializable
data class PaperFiling(
    val kind: String? = null,
    val reportYear: Int? = null,
    val filedAt: String? = null,
    val sourceUrl: String? = null,
    val status: String? = null,
)

object LossyAssets : LossyList<DisclosedAsset>(DisclosedAsset.serializer())
object LossyTrades : LossyList<DisclosedTrade>(DisclosedTrade.serializer())
object LossyPaper : LossyList<PaperFiling>(PaperFiling.serializer())
