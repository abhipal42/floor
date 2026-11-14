import DesignSystem
import Models
import SwiftUI

// The Live Activity's drawing (round 8, sections A and B of
// https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn). Plain SwiftUI, so the package's snapshot
// tests can draw it; the widget extension wraps these in `ActivityConfiguration` and the Dynamic
// Island's regions. Dark in both appearances, as the mock's lit displays are (`litObject()`).

/// `[glyph] HOUSE · ROLL CALL 321 ……… ● VOTE OPEN`.
public struct VoteActivityHeader: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState) {
        self.attributes = attributes
        self.content = content
    }

    public var body: some View {
        // One row as the mock has it; at the largest text sizes the state goes under the chamber.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                where_
                Spacer(minLength: 6)
                VoteActivityStatus(content: content)
            }
            VStack(alignment: .leading, spacing: 6) {
                where_
                VoteActivityStatus(content: content)
            }
        }
    }

    private var where_: some View {
        HStack(spacing: 8) {
            ChamberTile(size: 22)
            Text(VoteActivityText.header(attributes).uppercased())
                .font(Typography.label(12))
                .tracking(1.2)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// `● VOTE OPEN` in the live red, or `FINAL` in the threshold yellow.
public struct VoteActivityStatus: View {
    var content: VoteActivityAttributes.ContentState

    public init(content: VoteActivityAttributes.ContentState) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 5) {
            if content.state != .final {
                Circle()
                    .fill(Palette.live)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(Palette.live.opacity(0.25)).frame(width: 13, height: 13))
            }
            Text(VoteActivityText.status(content).uppercased())
                .font(Typography.label(12))
                .tracking(1.2)
                .foregroundStyle(content.state == .final ? Palette.threshold : Palette.live)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// `H.R. 1013 · ON PASSAGE`, and the bill's short title under it while the vote is open.
public struct VoteActivityHeadline: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState
    var size: CGFloat

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState, size: CGFloat = 24) {
        self.attributes = attributes
        self.content = content
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VoteActivityText.headline(attributes, content).uppercased())
                .font(Typography.headline(size))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let detail = VoteActivityText.detail(attributes, content) {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The score row. Open: dashes either side of "Needs a majority / Opened 2:43 PM" — the House
/// posts no running count, so nothing is invented. Final: yea and nay with "Yea · Nay" between.
public struct VoteActivityScore: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState
    /// Lock screen: the absentees line under "Yea · Nay". The expanded island leaves it out.
    var showsAbsentees: Bool
    var timeZone: TimeZone

    public init(
        attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState,
        showsAbsentees: Bool = true, timeZone: TimeZone = .current
    ) {
        self.attributes = attributes
        self.content = content
        self.showsAbsentees = showsAbsentees
        self.timeZone = timeZone
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            number(content.totals?.yea, color: Palette.yea)
            VStack(spacing: 2) {
                if content.state == .final, content.totals != nil {
                    caption("Yea · Nay", color: Palette.textMuted)
                    if showsAbsentees, let absent = VoteActivityText.absentees(content) {
                        caption(absent, color: Palette.textMuted)
                    }
                } else {
                    caption(VoteActivityText.needs(attributes), color: Palette.textMuted)
                    if let opened = VoteActivityText.opened(content, timeZone: timeZone) {
                        caption(opened, color: Palette.threshold)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            number(content.totals?.nay, color: Palette.nay)
        }
    }

    private func number(_ value: Int?, color: Color) -> some View {
        Text(value.map(String.init) ?? "—")
            .font(Typography.display(38, weight: .blackItalic, scales: false))
            .monospacedDigit()
            .foregroundStyle(value == nil ? Palette.raised : color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(Typography.label(12))
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The yea fill and the yellow threshold line, once final. A Speaker ballot has no bar.
public struct VoteActivityBar: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState) {
        self.attributes = attributes
        self.content = content
    }

    public var body: some View {
        if content.state == .final, content.totals != nil, let line = VoteActivityText.vote(attributes, content).line {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.panelBorder)
                    Capsule().fill(Palette.yea).frame(width: proxy.size.width * line.yeaShare)
                    Rectangle()
                        .fill(Palette.threshold)
                        .frame(width: 2, height: proxy.size.height + 4)
                        .offset(x: proxy.size.width * line.lineShare - 1)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
    }
}

/// Your members: a chip and a line each, then "+2 more of your members".
public struct VoteActivityMembers: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState
    var long: Bool

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState, long: Bool = true) {
        self.attributes = attributes
        self.content = content
        self.long = long
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(content.members) { call in
                HStack(spacing: 8) {
                    VoteActivityChip(call: call)
                    Text(VoteActivityText.line(call, attributes, content, alone: content.members.count == 1, long: long))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if let more = VoteActivityText.more(content) {
                Text(more)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `NAY` on the nay orange, or an outlined `…` until the member is recorded.
public struct VoteActivityChip: View {
    var call: VoteActivityAttributes.Call

    public init(call: VoteActivityAttributes.Call) {
        self.call = call
    }

    public var body: some View {
        let label = Text(VoteActivityText.chip(call))
            .font(Typography.label(11))
            .tracking(0.9)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        Group {
            if let position = call.position {
                label
                    .foregroundStyle(Palette.flapBoard)
                    .background(fill(position), in: .rect(cornerRadius: 4))
            } else {
                label
                    .foregroundStyle(Palette.textMuted)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.raised, lineWidth: 1))
            }
        }
        .fixedSize()
    }

    private func fill(_ position: Position) -> Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present, .notVoting: Palette.textMuted
        case .candidate: Palette.text
        }
    }
}

/// The lock screen (and banner) presentation: open, then final, exactly as the mock lays them out.
public struct VoteActivityLockScreen: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState
    var timeZone: TimeZone

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState, timeZone: TimeZone = .current) {
        self.attributes = attributes
        self.content = content
        self.timeZone = timeZone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VoteActivityHeader(attributes: attributes, content: content)
            VoteActivityHeadline(attributes: attributes, content: content)
            VoteActivityScore(attributes: attributes, content: content, timeZone: timeZone)
            VoteActivityBar(attributes: attributes, content: content)
            if !content.members.isEmpty {
                Divider().overlay(Palette.card)
                VoteActivityMembers(attributes: attributes, content: content)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .litObject()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoteActivityText.spoken(attributes, content, timeZone: timeZone))
    }
}

/// The expanded Dynamic Island's body: the lock screen's content without the title line, the bar or
/// the absentees, as the mock's long-press shows it.
public struct VoteActivityExpanded: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState
    var timeZone: TimeZone

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState, timeZone: TimeZone = .current) {
        self.attributes = attributes
        self.content = content
        self.timeZone = timeZone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoteActivityHeadline(attributes: attributes, content: content, size: 22)
            VoteActivityScore(attributes: attributes, content: content, showsAbsentees: false, timeZone: timeZone)
            if !content.members.isEmpty {
                VoteActivityMembers(attributes: attributes, content: content, long: false)
            }
        }
        .litObject()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoteActivityText.spoken(attributes, content, timeZone: timeZone))
    }
}

/// Compact leading: the glyph and the bill.
public struct VoteActivityCompactLeading: View {
    var attributes: VoteActivityAttributes
    var content: VoteActivityAttributes.ContentState

    public init(attributes: VoteActivityAttributes, content: VoteActivityAttributes.ContentState) {
        self.attributes = attributes
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 5) {
            ChamberTile(size: 16)
            Text(VoteActivityText.subject(attributes, content).uppercased())
                .font(Typography.label(12))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoteActivityText.subject(attributes, content))
    }
}

/// Compact trailing: `● OPEN`, then the score, which replaces the state.
public struct VoteActivityCompactTrailing: View {
    var content: VoteActivityAttributes.ContentState

    public init(content: VoteActivityAttributes.ContentState) {
        self.content = content
    }

    public var body: some View {
        Group {
            if content.state == .final, let t = content.totals {
                HStack(spacing: 0) {
                    Text("\(t.yea)").foregroundStyle(Palette.yea)
                    Text("–").foregroundStyle(Palette.textMuted)
                    Text("\(t.nay)").foregroundStyle(Palette.nay)
                }
                .font(Typography.display(14, weight: .blackItalic, scales: false))
                .monospacedDigit()
                .accessibilityLabel("\(t.yea) yea to \(t.nay) nay")
            } else {
                Text("● OPEN")
                    .font(Typography.label(12))
                    .tracking(1)
                    .foregroundStyle(Palette.live)
                    .accessibilityLabel("Vote open")
            }
        }
        .litObject()
    }
}

/// Minimal, when two activities share the island: the chamber mark alone.
public struct VoteActivityMinimal: View {
    public init() {}

    public var body: some View {
        ChamberTile(size: 16).accessibilityLabel("Floor vote")
    }
}
