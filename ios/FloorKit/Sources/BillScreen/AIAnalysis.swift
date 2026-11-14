import Foundation
import Models

/// What the Bill screen's AI section shows, worked out from the API's analysis and nothing else.
///
/// The product rule is "AI is labelled and cited": every line here is the API's own text, every
/// chip points at a CRS paragraph the response carries, and a line none of whose citations resolves
/// to a paragraph is cut rather than shown uncited. The disclaimer is the response's, verbatim.
public struct AIAnalysis: Equatable, Sendable {
    /// One heading and its lines, in the order the screen draws them.
    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String
        /// `What it does`, `What it changes`, `Who it touches`, `Impact`.
        public var heading: String
        public var lines: [Line]
    }

    /// One AI-written line with its citation chips.
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var citations: [Citation]

        /// What VoiceOver reads for the line: `AI-written: …, cited from CRS paragraph 2`.
        public var accessibilityLabel: String {
            let sources = citations.map(\.spoken)
            let list = switch sources.count {
            case 0: ""
            case 1: sources[0]
            case 2: "\(sources[0]) and \(sources[1])"
            default: sources.dropLast().joined(separator: ", ") + ", and " + sources[sources.count - 1]
            }
            // The line's own full stop would read as "agencies., cited"; the label ends the sentence.
            let sentence = text.hasSuffix(".") ? String(text.dropLast()) : text
            return "AI-written: \(sentence), cited from \(list)"
        }
    }

    /// One chip: the CRS paragraph a line came from, and that paragraph verbatim.
    public struct Citation: Equatable, Sendable, Identifiable {
        public var id: String
        /// 1-based, as the API numbers it.
        public var paragraph: Int
        /// `Sec. 101`, when CRS names one for the paragraph.
        public var section: String?
        /// The cited paragraph, verbatim from the response's source.
        public var source: String

        /// The chip's text: `CRS ¶2`, or `CRS ¶5 · Sec. 101`.
        public var label: String {
            section.map { "CRS ¶\(paragraph) · \($0)" } ?? "CRS ¶\(paragraph)"
        }

        /// `CRS paragraph 2`, or `CRS paragraph 5, Sec. 101`.
        public var spoken: String {
            section.map { "CRS paragraph \(paragraph), \($0)" } ?? "CRS paragraph \(paragraph)"
        }
    }

    public var groups: [Group]
    /// The API's disclaimer, shown as sent.
    public var disclaimer: String
    /// The CRS summary version analysed, e.g. `Public Law`.
    public var stage: String
    /// The bill's summary has changed since this was written.
    public var stale: Bool

    public init(_ analysis: BillAnalysis) {
        let source = analysis.source
        func lines(_ key: String, _ claims: [AnalysisClaim]) -> [Line] {
            claims.enumerated().compactMap { index, claim in
                let id = "\(key)-\(index)"
                // A blank line says nothing a reader could check against the source.
                guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let citations = claim.citations.enumerated().compactMap { n, citation -> Citation? in
                    guard let paragraph = source.paragraph(for: citation),
                          Self.quote(citation.quote, isIn: paragraph)
                    else { return nil }
                    return Citation(
                        id: "\(id)-\(n)", paragraph: citation.paragraph, section: citation.section, source: paragraph
                    )
                }
                // Uncited is cut, not shown: the rule is a source for every line.
                return citations.isEmpty ? nil : Line(id: id, text: claim.text, citations: citations)
            }
        }
        groups = [
            Group(id: "purpose", heading: "What it does", lines: lines("purpose", analysis.purpose.map { [$0] } ?? [])),
            Group(id: "provisions", heading: "What it changes", lines: lines("provisions", analysis.provisions)),
            Group(id: "affectedGroups", heading: "Who it touches", lines: lines("affectedGroups", analysis.affectedGroups)),
            Group(id: "impact", heading: "Impact", lines: lines("impact", analysis.impact)),
        ].filter { !$0.lines.isEmpty }
        disclaimer = analysis.disclaimer
        stage = source.stage
        stale = source.stale
    }

    /// Whether a citation's quote appears in the paragraph it cites, compared the way the worker's
    /// check does (`normalize` in `apps/worker/src/analysis.ts`): lowercased, whitespace runs folded
    /// to one space, curly quotes and en/em dashes folded, and leading or trailing dots, ellipses and
    /// spaces dropped from the quote. The worker has already checked this, along with a minimum length
    /// and a stopword rule it alone applies; this is the app refusing to trust a response that
    /// contradicts its own source, not a second opinion.
    static func quote(_ quote: String, isIn paragraph: String) -> Bool {
        let trimmed = quote.trimmingCharacters(in: CharacterSet(charactersIn: ".…").union(.whitespacesAndNewlines))
        let needle = normalize(trimmed)
        return !needle.isEmpty && normalize(paragraph).contains(needle)
    }

    /// The worker's `normalize`, character for character.
    static func normalize(_ text: String) -> String {
        var out = ""
        var space = false
        for ch in text {
            if ch.isWhitespace {
                space = !out.isEmpty
                continue
            }
            if space {
                out.append(" ")
                space = false
            }
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{2032}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{2033}": out.append("\"")
            case "\u{2013}", "\u{2014}": out.append("-")
            default: out.append(contentsOf: String(ch).lowercased())
            }
        }
        return out
    }

    /// Every chip, so a screen can find the one that is open.
    public var citations: [Citation] { groups.flatMap { $0.lines.flatMap(\.citations) } }

    /// The label over an open citation: `CRS SUMMARY · ¶2 · PUBLIC LAW`.
    public func sourceLabel(_ citation: Citation) -> String {
        "CRS summary · ¶\(citation.paragraph) · \(stage)".uppercased()
    }

    /// What VoiceOver reads for an open citation: the stage, the paragraph and its words.
    public func sourceAccessibilityLabel(_ citation: Citation) -> String {
        "CRS summary, paragraph \(citation.paragraph), \(stage): \(citation.source)"
    }

    /// Shown when ``stale``: the summary this was written from is no longer the bill's latest.
    public static let staleNote = "The CRS summary has changed since this was written."
}
