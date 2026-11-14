import DesignSystem
import Models
import SwiftUI

// Section E of the locked live/AI design (https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn): a
// violet-labelled section at the top of the bill, each line with its citation chips, a tapped chip
// opening the CRS paragraph verbatim, and the API's disclaimer under it all.

/// The Bill screen's AI section in whichever state ``BillScreenModel/analysis`` is in.
struct AIAnalysisSection: View {
    let phase: BillScreenModel.AnalysisPhase
    let openCitation: String?
    let onToggle: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
        switch phase {
        case .loading:
            AISkeleton()
        case .hidden:
            EmptyView()
        case .noSummary:
            NoSummaryCard()
        case let .loaded(analysis):
            AIAnalysisCard(analysis: analysis, openCitation: openCitation, onToggle: onToggle)
        case .failed:
            AIBox {
                AILabel(text: "Couldn't load the AI summary")
                Button("Try again", action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.ai)
            }
        }
    }
}

/// The violet card every AI state draws in: the mock's `.ai`.
private struct AIBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Palette.ai.opacity(Tones.aiCardTint), Palette.ai.opacity(0.02)], startPoint: .top, endPoint: .bottom
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.ai.opacity(0.35), lineWidth: 1))
    }
}

/// The "AI" tag and what wrote the section: the mock's `.lab`.
private struct AILabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text("AI")
                .font(Typography.label(11))
                .tracking(1.1)
                .foregroundStyle(Palette.aiInk)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Palette.ai, in: .rect(cornerRadius: 5))
                .fixedSize()
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.ai)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI. \(text)")
    }
}

private struct AIAnalysisCard: View {
    let analysis: AIAnalysis
    let openCitation: String?
    let onToggle: (String) -> Void

    var body: some View {
        AIBox {
            AILabel(text: "Written by AI from the CRS summary")
            if analysis.stale {
                Text(AIAnalysis.staleNote)
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(analysis.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.heading.uppercased())
                        .font(Typography.label(11.5))
                        .tracking(1.15)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.lines) { line in
                        lineView(line)
                    }
                }
            }
            Text(analysis.disclaimer)
                .font(.caption2)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.ai.opacity(0.2)).frame(height: 1) }
        }
    }

    private func lineView(_ line: AIAnalysis.Line) -> some View {
        // No spacing: the chips' 44pt targets already leave air above and below them.
        VStack(alignment: .leading, spacing: 0) {
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(Palette.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line.accessibilityLabel)
            ChipFlow(spacing: 8) {
                ForEach(line.citations) { citation in
                    chip(citation)
                }
            }
            ForEach(line.citations.filter { $0.id == openCitation }) { citation in
                source(citation)
            }
        }
    }

    private func chip(_ citation: AIAnalysis.Citation) -> some View {
        let open = citation.id == openCitation
        return Button { onToggle(citation.id) } label: {
            Text(citation.label)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(open ? Palette.aiInk : Palette.ai)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(open ? Palette.ai : .clear, in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.ai.opacity(0.45), lineWidth: 1))
                // A 44pt-tall target around the small chip. Laid out, not overhanging: a target that
                // reached past its frame would overlap the next row's when the chips wrap.
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source: \(citation.spoken)")
        .accessibilityHint(open ? "Hides the cited paragraph" : "Shows the cited paragraph")
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    private func source(_ citation: AIAnalysis.Citation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(analysis.sourceLabel(citation))
                .font(Typography.label(10.5))
                .tracking(1.05)
                .foregroundStyle(Palette.textSecondary)
            Text(citation.source)
                .font(.custom("Georgia", size: 12.5, relativeTo: .footnote))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.ai).frame(width: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(analysis.sourceAccessibilityLabel(citation))
    }
}

/// While the analysis is being fetched: the label and three shimmering bars, the mock's `.skel`.
private struct AISkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        AIBox {
            AILabel(text: "Loading the AI summary…")
            ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Palette.track)
                        .overlay {
                            if !reduceMotion {
                                LinearGradient(
                                    colors: [.clear, Palette.raised.opacity(0.6), .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .offset(x: phase * proxy.size.width)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 5))
                        .frame(width: proxy.size.width * width)
                }
                .frame(height: 10)
                .accessibilityHidden(true)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// No CRS summary, so nothing for a model to write from: the mock's dashed card.
private struct NoSummaryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NO SUMMARY YET")
                .font(Typography.label(11.5))
                .tracking(1.15)
                .foregroundStyle(Palette.textMuted)
            Text("CRS hasn't published a summary for this version, so Floor has nothing to explain from. "
                + "The bill's own title and actions are below.")
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Palette.panelBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }
}

/// Lays chips left to right and wraps them, so a line's chips still fit at the largest type sizes.
private struct ChipFlow: Layout {
    /// Between chips on a row.
    var spacing: CGFloat
    /// Between rows. Zero by default: each chip is a laid-out 44pt target, so rows that touch
    /// still never overlap.
    var rowSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        var width = rows.map { $0.width }.max() ?? 0
        if let limit = proposal.width, limit.isFinite { width = min(width, limit) }
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = measure(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = measure(subviews[index], width: width)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }

    /// A chip's natural size, but never wider than the line: at the largest type sizes a chip
    /// such as `CRS ¶5 · Sec. 101` wraps inside itself rather than pushing the card off screen.
    private func measure(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
