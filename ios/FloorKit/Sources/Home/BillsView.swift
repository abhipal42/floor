import DesignSystem
import Models
import SwiftUI

/// The Bills tab: every bill your members voted on recently, newest vote first.
///
/// The locked mocks have no Bills list (the tab bar's Bills item points straight at one bill), and
/// the API has no "all bills" route, so this is the plainest list that serves the tab: the bills in
/// your feed, each with its latest vote's result.
struct BillsView: View {
    let model: HomeModel
    let onOpenBill: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("BILLS").font(Typography.headline(34)).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Bills your members voted on recently.")
                    .font(.system(size: 13)).foregroundStyle(Palette.textMuted)
                switch model.phase {
                case .loading:
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
                case let .failed(message):
                    Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary).panel()
                case .loaded:
                    if model.bills.isEmpty {
                        Text("None of your members' recent votes were on a bill.")
                            .font(Typography.body).foregroundStyle(Palette.textMuted)
                    }
                    ForEach(model.bills) { item in
                        if let measure = item.measure {
                            Button { onOpenBill(measure.id) } label: { row(item, measure) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.ground)
        // No load here: the Finals tab is always mounted beside this one and loads the shared feed.
    }

    private func row(_ item: FeedItem, _ measure: MeasureSummary) -> some View {
        let vote = item.vote
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SkewChip(measure.citation.uppercased())
                Spacer(minLength: 4)
                Text([vote.chamber.name, vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.textMuted)
            }
            Text(measure.title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading).lineLimit(3)
            HStack(spacing: 8) {
                Text("Latest: \(vote.questionKind.lowercased())")
                    .font(.system(size: 12)).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 4)
                if vote.kind == .question {
                    Text("\(vote.totals.yea)–\(vote.totals.nay)")
                        .font(Typography.label(18)).monospacedDigit()
                        .foregroundStyle(Palette.outcome(vote.outcome))
                }
                if let word = vote.outcomeWord {
                    SkewChip(word, background: Palette.outcome(vote.outcome))
                }
            }
        }
        .panel()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the bill")
    }
}
