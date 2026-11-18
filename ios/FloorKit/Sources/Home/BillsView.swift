import APIClient
import DesignSystem
import Models
import SwiftUI

/// The Bills tab (v0.2.59, the locked "Your picks" of <https://claude.ai/artifact/T7fxxQyFCYdPaJnewnNpT2>):
/// the bills your members voted on, as progress cards in topic sections, filtered All / Passed /
/// Blocked on each bill's latest vote. A special rule's votes fold into the bill they brought up.
///
/// There is no "all bills" route, so the list is built from the feeds already loaded
/// (``HomeModel/bills``' source): your members' votes, or following nobody, the latest finals.
struct BillsView: View {
    let model: HomeModel
    let onOpenBill: (String) -> Void
    @State private var filter: BillsFilter = .all
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BILLS").font(Typography.pageTitle).foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("What your members voted on, and where it stands.")
                        .scaledFont(13).foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch model.phase {
                case .loading:
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
                case let .failed(message):
                    Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary).panel()
                case .loaded:
                    if let saved = model.saved { SavedDataNote(saved) }
                    segment
                    let sections = BillsLedger.sections(model.ledgerItems, filter: filter)
                    if sections.isEmpty {
                        Text(emptyLine)
                            .scaledFont(13).foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    ForEach(sections) { section in
                        Text(section.group.name.uppercased())
                            .font(Typography.display(19, weight: .extraBold))
                            .tracking(0.4)
                            .foregroundStyle(Palette.topicText(section.group))
                            .padding(.top, 12)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.cards) { card in
                            // A rule's card opens the bill it brought up.
                            Button { onOpenBill(card.ruleFor == nil ? card.measure.id : card.measure.forBillId ?? card.measure.id) } label: {
                                LedgerCardView(card: card, calendar: calendar)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the bill")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .groundGlow()
        // No load here: the Finals tab is always mounted beside this one and loads the shared feed.
    }

    private var emptyLine: String {
        switch filter {
        case .all: "None of your members' recent votes were on a bill."
        case .passed: "None of these bills' latest votes passed."
        case .blocked: "None of these bills' latest votes failed."
        }
    }

    private var segment: some View {
        HStack(spacing: 4) {
            ForEach(BillsFilter.allCases, id: \.self) { option in
                let on = filter == option
                Button { filter = option } label: {
                    Text(option.rawValue)
                        .scaledFont(12, weight: .bold)
                        .foregroundStyle(on ? Palette.text : Palette.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? Palette.chip : Color.clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.cardSunken, in: .rect(cornerRadius: 11))
        .padding(.top, 8)
    }
}

/// One bill's progress card (Bills A): a topic-colour left edge, the cite chip and `TOPIC · NOV 12`,
/// the title, CRS's lead, the track, then the latest vote's kind, party split, score and stamp, and
/// any rule votes folded in.
struct LedgerCardView: View {
    let card: LedgerCard
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let vote = card.latest.vote
        let large = dynamicTypeSize.isAccessibilitySize
        let top = large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        VStack(alignment: .leading, spacing: 0) {
            top {
                SkewChip(card.measure.citation, size: 13)
                    .fixedSize()
                if !large { Spacer(minLength: 6) }
                Text(eyebrow.uppercased())
                    .scaledFont(11, weight: .bold)
                    .tracking(1)
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.trailing)
            }
            Text(card.title)
                .scaledFont(16.5, weight: .bold)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let summary = card.summary {
                Text(summary)
                    .scaledFont(13)
                    .lineSpacing(2)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
                    .padding(.top, 5)
            }
            if let track = card.track {
                TrackView(track: track).padding(.top, 13)
            }
            footer(vote)
                .padding(.top, 11)
                .overlay(alignment: .top) { Rectangle().fill(Palette.cardBorder).frame(height: 1) }
                .padding(.top, 12)
            if let rule = BillsLedger.ruleLine(card.rules, calendar: calendar) {
                Text(rule)
                    .scaledFont(11.5)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                .fill(Palette.topic(card.group))
                .frame(width: 4)
                .padding(.vertical, 14)
        }
        .heroCard(cornerRadius: 22, fill: Palette.card)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// `Defense · Nov 12`.
    private var eyebrow: String {
        [card.group.name, card.latest.vote.occurredAtDate.map { Stories.shortDate($0, calendar: calendar) }]
            .compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private func footer(_ vote: Vote) -> some View {
        let left = VStack(alignment: .leading, spacing: 2) {
            Text(BillsLedger.kindLine(vote))
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
            if let party = BillsLedger.partyLine(card.latest.partyTotals) {
                Text(party).scaledFont(11.5).foregroundStyle(Palette.textMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        let right = HStack(spacing: 8) {
            if vote.kind == .question {
                Text("\(vote.totals.yea)–\(vote.totals.nay)")
                    .font(Typography.display(24, weight: .blackItalic))
                    .monospacedDigit()
                    .foregroundStyle(Palette.outcome(vote.outcome))
            }
            if let word = vote.outcomeWord {
                SkewChip(word, foreground: Palette.ground, background: Palette.outcome(vote.outcome), size: 13)
                    .fixedSize()
            }
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) { left; right }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 8) {
                left
                Spacer(minLength: 6)
                right
            }
        }
    }

    private var spoken: String {
        let vote = card.latest.vote
        var parts = [card.measure.citation, card.title]
        if let summary = card.summary { parts.append(summary) }
        if let track = card.track { parts.append(track.spoken) }
        var latest = "Latest: \(BillsLedger.kindLine(vote)), \(vote.totals.yea) to \(vote.totals.nay)"
        if let word = vote.outcomeWord { latest += ", \(word.lowercased())" }
        parts.append(latest)
        if let party = BillsLedger.partyLine(card.latest.partyTotals) { parts.append(party) }
        if let rule = BillsLedger.ruleLine(card.rules, calendar: calendar) { parts.append(String(rule.dropFirst(2))) }
        return parts.joined(separator: ". ")
    }
}

/// The progress track: a dot per step joined by lines, done in green, the current step ringed,
/// where it stopped in the nay colour; the step names under it.
struct TrackView: View {
    let track: BillTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                ForEach(Array(track.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(lineDone(index) ? Palette.yea : Palette.raised)
                            .frame(height: 2)
                    }
                    dot(step.state)
                }
            }
            .padding(.horizontal, 4)
            UnderDots(inset: 9) {
                ForEach(Array(track.steps.enumerated()), id: \.offset) { index, step in
                    Text(step.label)
                        .scaledFont(10.5, weight: .semibold)
                        .foregroundStyle(color(step.state))
                        .multilineTextAlignment(alignment(index))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.spoken)
    }

    /// The line into step `index` is green when that step is done.
    private func lineDone(_ index: Int) -> Bool {
        let state = track.steps[index].state
        return state == .done || state == .current
    }

    private func dot(_ state: BillTrack.State) -> some View {
        Circle()
            .fill(state == .stopped ? Palette.nay : state == .upcoming ? Palette.raised : Palette.yea)
            .frame(width: 10, height: 10)
            .background {
                if state == .current { Circle().fill(Palette.yea.opacity(0.25)).frame(width: 18, height: 18) }
            }
    }

    private func color(_ state: BillTrack.State) -> Color {
        switch state {
        case .done, .current: Palette.textSecondary
        case .upcoming: Palette.textMuted
        case .stopped: Palette.nay
        }
    }

    private func alignment(_ index: Int) -> TextAlignment {
        index == 0 ? .leading : index == track.steps.count - 1 ? .trailing : .center
    }

}

/// The track's labels, each centred under its dot (the dots sit evenly from `inset` to
/// `width - inset`), the first held to the leading edge and the last to the trailing one. Each label
/// gets an even share of the width, so a long one wraps rather than running into its neighbour.
private struct UnderDots: Layout {
    let inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let share = width / CGFloat(max(1, subviews.count))
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let share = bounds.width / CGFloat(n)
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: share, height: nil))
            let dot = n == 1 ? bounds.minX + inset
                : bounds.minX + inset + (bounds.width - 2 * inset) * CGFloat(i) / CGFloat(n - 1)
            let x = i == 0 ? bounds.minX : i == n - 1 ? bounds.maxX - size.width
                : min(max(dot - size.width / 2, bounds.minX), bounds.maxX - size.width)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: size.width, height: size.height))
        }
    }
}
