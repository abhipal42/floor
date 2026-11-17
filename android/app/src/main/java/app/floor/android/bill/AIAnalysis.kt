package app.floor.android.bill

import app.floor.android.model.AnalysisClaim
import app.floor.android.model.BillAnalysis

/**
 * What the bill screen's AI section shows, worked out from the API's analysis and nothing else
 * (iOS `AIAnalysis`).
 *
 * The product rule is "AI is labelled and cited": every line is the API's own text, every chip
 * points at a CRS paragraph the response carries, and a line none of whose citations resolves to a
 * paragraph containing its quote is cut rather than shown uncited. The disclaimer is the response's.
 */
data class AIAnalysis(
    val groups: List<Group>,
    val disclaimer: String,
    /** The CRS summary version analysed, e.g. `Public Law`. */
    val stage: String,
    /** The bill's summary has changed since this was written. */
    val stale: Boolean,
) {
    /** `What it does`, `What it changes`, `Who it touches`, `Impact`, and their lines. */
    data class Group(val id: String, val heading: String, val lines: List<Line>)

    data class Line(val id: String, val text: String, val citations: List<Citation>) {
        /** What TalkBack reads: `AI-written: …, cited from CRS paragraph 2`. */
        val spoken: String
            get() {
                val sources = citations.map { it.spoken }
                val list = when (sources.size) {
                    0 -> ""
                    1 -> sources[0]
                    2 -> "${sources[0]} and ${sources[1]}"
                    else -> sources.dropLast(1).joinToString(", ") + ", and " + sources.last()
                }
                return "AI-written: ${text.removeSuffix(".")}, cited from $list"
            }
    }

    /** One chip: the CRS paragraph (1-based) a line came from, and that paragraph verbatim. */
    data class Citation(val id: String, val paragraph: Int, val section: String?, val source: String) {
        /** `CRS ¶2`, or `CRS ¶5 · Sec. 101`. */
        val label: String get() = section?.let { "CRS ¶$paragraph · $it" } ?: "CRS ¶$paragraph"

        /** `CRS paragraph 2`, or `CRS paragraph 5, Sec. 101`. */
        val spoken: String get() = section?.let { "CRS paragraph $paragraph, $it" } ?: "CRS paragraph $paragraph"
    }

    /** Every chip, so a screen can find the one that is open. */
    val citations: List<Citation> get() = groups.flatMap { g -> g.lines.flatMap { it.citations } }

    /** The label over an open citation: `CRS SUMMARY · ¶2 · PUBLIC LAW`. */
    fun sourceLabel(citation: Citation): String = "CRS summary · ¶${citation.paragraph} · $stage".uppercase()

    fun sourceSpoken(citation: Citation): String =
        "CRS summary, paragraph ${citation.paragraph}, $stage: ${citation.source}"

    companion object {
        const val STALE_NOTE = "The CRS summary has changed since this was written."

        fun of(analysis: BillAnalysis): AIAnalysis {
            val source = analysis.source
            fun lines(key: String, claims: List<AnalysisClaim>): List<Line> = claims.mapIndexedNotNull { index, claim ->
                val id = "$key-$index"
                // A blank line says nothing a reader could check against the source.
                if (claim.text.isBlank()) return@mapIndexedNotNull null
                val citations = claim.citations.mapIndexedNotNull { n, citation ->
                    val paragraph = source.paragraph(citation)
                    if (paragraph == null || !quoteIsIn(citation.quote, paragraph)) null
                    else Citation("$id-$n", citation.paragraph, citation.section, paragraph)
                }
                // Uncited is cut, not shown: the rule is a source for every line.
                if (citations.isEmpty()) null else Line(id, claim.text, citations)
            }
            val groups = listOf(
                Group("purpose", "What it does", lines("purpose", listOfNotNull(analysis.purpose))),
                Group("provisions", "What it changes", lines("provisions", analysis.provisions)),
                Group("affectedGroups", "Who it touches", lines("affectedGroups", analysis.affectedGroups)),
                Group("impact", "Impact", lines("impact", analysis.impact)),
            ).filter { it.lines.isNotEmpty() }
            return AIAnalysis(groups, analysis.disclaimer, source.stage, source.stale)
        }

        /**
         * Whether a quote appears in the paragraph it cites, compared as the worker's `normalize`
         * does (`apps/worker/src/analysis.ts`); leading and trailing dots, ellipses and spaces are
         * dropped from the quote first.
         */
        fun quoteIsIn(quote: String, paragraph: String): Boolean {
            val needle = normalize(quote.trim { it == '.' || it == '…' || it.isWhitespace() })
            return needle.isNotEmpty() && needle in normalize(paragraph)
        }

        /** The worker's `normalize`, character for character. */
        fun normalize(text: String): String {
            val out = StringBuilder()
            var space = false
            for (ch in text) {
                if (ch.isWhitespace()) {
                    space = out.isNotEmpty()
                    continue
                }
                if (space) {
                    out.append(' ')
                    space = false
                }
                when (ch) {
                    '‘', '’', '′' -> out.append('\'')
                    '“', '”', '″' -> out.append('"')
                    '–', '—' -> out.append('-')
                    else -> out.append(ch.toString().lowercase())
                }
            }
            return out.toString()
        }
    }
}
