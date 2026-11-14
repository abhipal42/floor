import Models
import SwiftUI

// The pieces of the Round 10 design (<https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>): a bill
// row with its stage chip and five-step road, a topic row, and the Follow / Following pill that
// both carry. Shared by the Following tab, a topic's page and the "+ Add" search.

/// Follow / Following, as the mock's `.fb` draws it: filled while you don't follow, outlined once
/// you do. A switch to VoiceOver: "Follow Health, switch button, off".
public struct FollowPill: View {
    let on: Bool
    let offTitle: String
    let onTitle: String
    let name: String
    let hint: String
    let action: () -> Void

    /// - Parameters:
    ///   - name: what VoiceOver says is followed, e.g. `H.R. 2493` or `Health`.
    ///   - hint: what following does, read after the label.
    public init(
        on: Bool, offTitle: String = "FOLLOW", onTitle: String = "FOLLOWING", name: String,
        hint: String, action: @escaping () -> Void
    ) {
        self.on = on
        self.offTitle = offTitle
        self.onTitle = onTitle
        self.name = name
        self.hint = hint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(on ? onTitle : offTitle)
                .font(Typography.label(12))
                .tracking(0.6)
                .lineLimit(1)
                .foregroundStyle(on ? Palette.text : Palette.ground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(on ? Color.clear : Palette.threshold, in: .rect(cornerRadius: 8))
                .overlay {
                    if on { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.raised, lineWidth: 1) }
                }
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow \(name)")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(on ? "Unfollows" : hint)
    }
}

/// The stage chip: filled green for law, filled orange for a failed vote, outlined on the way.
public struct StageChipView: View {
    let chip: StageChip

    public init(_ chip: StageChip) { self.chip = chip }

    public var body: some View {
        Text(chip.text)
            .font(Typography.display(10.5, weight: .extraBold))
            .tracking(0.8)
            .lineLimit(1)
            .foregroundStyle(chip.tone == .neutral ? Palette.textSecondary : Palette.ground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background, in: .rect(cornerRadius: 4))
            .overlay {
                if chip.tone == .neutral { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.raised, lineWidth: 1) }
            }
            .fixedSize()
    }

    private var background: Color {
        switch chip.tone {
        case .law: Palette.yea
        case .failed: Palette.nay
        case .neutral: .clear
        }
    }
}

/// Five bars, the steps reached in the threshold yellow.
public struct BillRoadView: View {
    let steps: Int

    public init(steps: Int) { self.steps = steps }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<BillRoad.steps.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < steps ? Palette.threshold : Palette.panelBorder)
                    .frame(height: 4)
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// A bill in a list (the mock's `.bl2`): citation and stage chip (or a trailing control), the
/// plain short label, the latest step, and the road. One VoiceOver element unless `trailing` is a
/// control, which then stays its own element beside the row's text.
public struct BillRowView<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// At accessibility sizes the label and latest step get more lines, and a trailing control goes
    /// under the text rather than squeezing it into a column a word wide.
    private var large: Bool { dynamicTypeSize.isAccessibilitySize }
    let bill: BillListItem
    let showsLatest: Bool
    let showsRoad: Bool
    let trailing: Trailing?
    let onOpen: (() -> Void)?

    /// A row with no control of its own; put it in a `Button` to make the whole card open the bill.
    public init(bill: BillListItem, showsLatest: Bool = true, showsRoad: Bool = true) where Trailing == EmptyView {
        self.bill = bill
        self.showsLatest = showsLatest
        self.showsRoad = showsRoad
        trailing = nil
        onOpen = nil
    }

    /// - Parameters:
    ///   - onOpen: what tapping the row's text does (opens the bill); the trailing control keeps its own tap.
    ///   - trailing: drawn where the chip goes, e.g. a Follow pill in search results.
    public init(
        bill: BillListItem, showsLatest: Bool = true, showsRoad: Bool = false, onOpen: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.bill = bill
        self.showsLatest = showsLatest
        self.showsRoad = showsRoad
        self.trailing = trailing()
        self.onOpen = onOpen
    }

    public var body: some View {
        let layout = large && trailing != nil
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            if let onOpen {
                Button(action: onOpen) { text.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the bill")
            } else {
                text
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .contentShape(.rect)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(bill.citation.uppercased())
                    .font(Typography.label(12))
                    .tracking(0.8)
                    .foregroundStyle(Palette.threshold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if trailing == nil, let chip = bill.chip { StageChipView(chip) }
            }
            Text(bill.label)
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Palette.text)
                .lineLimit(large ? 10 : 3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if showsLatest, let latest = bill.latestStep {
                Text(latest)
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(large ? 8 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsRoad, let steps = bill.roadSteps { BillRoadView(steps: steps) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.billRow(bill))
    }
}

/// A topic in a list (the mock's `.tp`): its name, a count line, and a trailing control or `›`.
public struct TopicRowView<Trailing: View>: View {
    let name: String
    let detail: String?
    let spoken: String
    let onOpen: (() -> Void)?
    let trailing: Trailing

    /// - Parameters:
    ///   - spoken: what VoiceOver reads for the name and counts (``Spoken/topicRow(_:)``).
    ///   - onOpen: what tapping the name does (opens the topic); the trailing control keeps its own tap.
    public init(
        name: String, detail: String?, spoken: String? = nil, onOpen: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.detail = detail
        self.spoken = spoken ?? [name, detail].compactMap(\.self).joined(separator: ". ")
        self.onOpen = onOpen
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let onOpen {
                Button(action: onOpen) { text.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the topic's bills")
            } else {
                text
            }
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .contentShape(.rect)
    }

    private var text: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.uppercased())
                    .font(Typography.display(20, weight: .blackItalic))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).scaledFont(11, weight: .medium).foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }
}

/// The words on a topic row, apart from the view so they can be tested.
public enum TopicText {
    /// `724 bills · 9 with a floor vote · latest Nov 12`. The counts grow as the catalog fills.
    public static func detail(_ topic: Topic) -> String {
        var parts = ["\(topic.bills.formatted()) \(topic.bills == 1 ? "bill" : "bills")"]
        if topic.billsWithFloorVote > 0 { parts.append("\(topic.billsWithFloorVote.formatted()) with a floor vote") }
        if let latest = topic.latestActionOn.flatMap(Formats.monthDay) { parts.append("latest \(latest)") }
        return parts.joined(separator: " · ")
    }
}
