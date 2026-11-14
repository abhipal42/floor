import Foundation

/// Where an AI line came from: a paragraph of the CRS summary, quoted.
public struct AnalysisCitation: Codable, Sendable, Hashable {
    /// 1-based index into ``AnalysisSource/paragraphs``.
    public var paragraph: Int
    /// Verbatim excerpt of that paragraph.
    public var quote: String
    /// The bill section, as CRS labels the paragraph (`Sec. 101`); nil when it names none.
    public var section: String?

    public init(paragraph: Int, quote: String, section: String?) {
        self.paragraph = paragraph
        self.quote = quote
        self.section = section
    }
}

/// One AI-written line. Always AI (`ai` is always true) and always cited.
public struct AnalysisClaim: Codable, Sendable, Hashable {
    public var text: String
    public var ai: Bool
    public var citations: [AnalysisCitation]

    public init(text: String, ai: Bool = true, citations: [AnalysisCitation]) {
        self.text = text
        self.ai = ai
        self.citations = citations
    }
}

/// The CRS summary an analysis was written from.
public struct AnalysisSource: Codable, Sendable, Hashable {
    /// `crs_summary`.
    public var kind: String
    /// The summary version analysed, e.g. `Public Law`.
    public var stage: String
    public var paragraphs: [String]
    /// The bill's summary has changed since; a new analysis is pending.
    public var stale: Bool

    public init(kind: String, stage: String, paragraphs: [String], stale: Bool) {
        self.kind = kind
        self.stage = stage
        self.paragraphs = paragraphs
        self.stale = stale
    }

    /// The paragraph a citation points at, or nil if it is out of range.
    public func paragraph(for citation: AnalysisCitation) -> String? {
        paragraphs.indices.contains(citation.paragraph - 1) ? paragraphs[citation.paragraph - 1] : nil
    }
}

/// `GET /v1/bills/{id}/analysis` (M4 Layer 1), shown at the top of the Bill screen (`AIAnalysis` in
/// BillScreen). Wherever it is shown, ``disclaimer`` goes with it and every line is labelled as AI.
public struct BillAnalysis: Codable, Sendable, Hashable {
    public var billId: String
    public var ai: Bool
    /// `AI-generated`.
    public var label: String
    public var disclaimer: String
    public var source: AnalysisSource
    public var model: String
    public var verifierModel: String?
    public var promptVersion: String
    public var generatedAt: String
    public var provisions: [AnalysisClaim]
    public var affectedGroups: [AnalysisClaim]
    public var impact: [AnalysisClaim]
    /// nil when no purpose line survived verification.
    public var purpose: AnalysisClaim?

    public init(
        billId: String, ai: Bool = true, label: String, disclaimer: String, source: AnalysisSource,
        model: String, verifierModel: String?, promptVersion: String, generatedAt: String,
        provisions: [AnalysisClaim], affectedGroups: [AnalysisClaim], impact: [AnalysisClaim],
        purpose: AnalysisClaim?
    ) {
        self.billId = billId
        self.ai = ai
        self.label = label
        self.disclaimer = disclaimer
        self.source = source
        self.model = model
        self.verifierModel = verifierModel
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
        self.provisions = provisions
        self.affectedGroups = affectedGroups
        self.impact = impact
        self.purpose = purpose
    }
}
