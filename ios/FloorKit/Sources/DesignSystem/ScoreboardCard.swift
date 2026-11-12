import Models
import SwiftUI

/// The Yea-vs-Nay matchup card from the design canvas.
///
/// Layout follows the canvas: a fixed 56pt side, a flexible score, a fixed 92pt status, the other
/// score, the other side. The gaps are zero — the sides and status already carry their own padding,
/// and default `HStack` spacing costs 32pt across four gaps, which at 402pt width leaves each score
/// about 69pt. "216" at this size needs more than that, so the number used to break across lines and
/// render as 2/1/6 stacked vertically.
public struct ScoreboardCard: View {
    let vote: Vote
    let title: String

    public init(vote: Vote, title: String) {
        self.vote = vote
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(vote.chamber.rawValue.uppercased())
                    .font(Typography.eyebrow)
                    .tracking(0.9)
                    .foregroundStyle(Palette.textMuted)
                Text(title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(vote.question)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: 0) {
                side(label: "Yea", symbol: "checkmark", color: Palette.yea)
                score(vote.totals.yea, leading: vote.leader != .nay)
                status
                score(vote.totals.nay, leading: vote.leader != .yea)
                side(label: "Nay", symbol: "xmark", color: Palette.nay)
            }
        }
        .padding(14)
        .background(Palette.card, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title). \(vote.question). Yea \(vote.totals.yea), Nay \(vote.totals.nay). \(statusText)"
        )
    }

    private var statusText: String {
        switch vote.state {
        case .final: vote.result ?? "Final"
        case .open: "Voting open"
        case .scheduled: "Scheduled"
        }
    }

    /// The canvas sets a live card's score at 50pt and a settled one's at 44pt.
    private var scoreSize: CGFloat { vote.state == .open ? 50 : 44 }

    private var status: some View {
        VStack(spacing: 3) {
            Text(vote.state == .final ? "Final" : statusText)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(vote.state == .open ? Palette.liveText : Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Needs \(vote.votesNeeded)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
        }
        .frame(width: 92)
    }

    private func score(_ value: Int, leading: Bool) -> some View {
        Text("\(value)")
            .font(Typography.score(scoreSize))
            .monospacedDigit()
            .foregroundStyle(leading ? Palette.text : Palette.trailing)
            // One line always. A unanimous Senate vote is two digits and a House vote three, but
            // scaling rather than wrapping keeps the row intact whatever arrives.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
    }

    private func side(label: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.16), in: .circle)
                .overlay(Circle().stroke(color, lineWidth: 1.5))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(width: 56)
    }
}

#Preview("Final") {
    ScoreboardCard(vote: .sample, title: "H.Con.Res. 14 · FY2025 Budget Resolution")
        .padding(14)
        .background(Palette.ground)
        .preferredColorScheme(.dark)
}

#Preview("Widest case") {
    // Four digits a side is beyond anything either chamber can produce, so if this holds, every
    // real vote holds.
    let wide = Vote(
        id: "house-119-1-1", kind: .question, chamber: .house, congress: 119, session: 1,
        rollNumber: 1, question: "On Motion to Concur in the Senate Amendment with an Amendment",
        billId: nil, nominationId: nil, billRef: nil, occurredAt: nil, state: .open,
        threshold: .majority, totals: VoteTotals(yea: 8888, nay: 8888, present: 0, notVoting: 0),
        candidates: [], result: nil
    )
    return ScoreboardCard(vote: wide, title: "A measure with a notably long name that wraps")
        .padding(14)
        .background(Palette.ground)
        .preferredColorScheme(.dark)
}
