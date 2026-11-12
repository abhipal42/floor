import Models
import SwiftUI

/// The Yea-vs-Nay matchup card from the Home screen design.
public struct ScoreboardCard: View {
    let vote: Vote
    let title: String

    public init(vote: Vote, title: String) {
        self.vote = vote
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("\(vote.chamber.rawValue.uppercased()) · \(vote.question.uppercased())")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            HStack {
                side(label: "Yea", symbol: "checkmark", color: Palette.yea)
                score(vote.totals.yea, leading: vote.leader != .nay)
                status
                score(vote.totals.nay, leading: vote.leader != .yea)
                side(label: "Nay", symbol: "xmark", color: Palette.nay)
            }
        }
        .padding(14)
        .background(Palette.card, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). Yea \(vote.totals.yea), Nay \(vote.totals.nay). \(statusText)")
    }

    private var statusText: String {
        switch vote.state {
        case .final: vote.result ?? "Final"
        case .open: "Voting open"
        case .scheduled: "Scheduled"
        }
    }

    private var status: some View {
        VStack(spacing: 3) {
            Text(vote.state == .final ? "Final" : statusText)
                .font(.callout.weight(.bold))
                .foregroundStyle(vote.state == .open ? Palette.live : .primary)
            Text("Needs \(vote.votesNeeded)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 92)
    }

    private func score(_ value: Int, leading: Bool) -> some View {
        Text("\(value)")
            .font(.system(size: 48, weight: .bold, design: .rounded).width(.condensed))
            .monospacedDigit()
            .foregroundStyle(leading ? .primary : Palette.trailing)
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
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(width: 56)
    }
}

#Preview {
    ScoreboardCard(vote: .sample, title: "H.Con.Res. 14 · FY2025 Budget Resolution")
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
