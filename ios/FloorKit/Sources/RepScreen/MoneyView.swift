import DesignSystem
import Models
import SwiftUI

// The member screen's Record / Money / Portfolio switch and the two segments that are not the
// record, built to the locked AppRepMoney mock (canvas round 6,
// https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU). Where this differs from the mock, and why:
//
// - The donor explainer ("✦ FLOOR EXPLAINS · AI": who a PAC is, what it lobbies on, related votes)
//   is a labelled placeholder, and PAC rows are not tappable. It needs Senate lobbying filings and
//   the AI label-and-cite pipeline (M4), neither of which exists; an invented line is not allowed.
// - The PAC list has a heading and says which FEC cycle it covers: a senator's 2030 campaign sits
//   beside a 2025–26 list (lesson 33). A footnote says totals and the list come from different
//   filings and won't add up (lesson 24).
// - The period reads "2026 campaign", as the landing page does, not "2026 cycle": for a senator
//   the campaign year and the FEC cycle differ.
// - No "NEW DATA · needs FEC ingest" banner on Money: that was the mock's note that data was
//   missing, and it is not any more. Portfolio keeps one, because it still is.
// - No back chevron in the header: the switch is how you get back to Record.

/// Record / Money / Portfolio, as the mocks' segmented control.
struct SectionSwitch: View {
    @Binding var selection: MemberSection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MemberSection.allCases) { section in
                let on = section == selection
                Button { selection = section } label: {
                    Text(section.rawValue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(on ? Palette.ground : Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(7)
                        .background(on ? Palette.text : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .accessibilityHint(section == .portfolio ? "Not loaded yet" : "")
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }
}

/// The compact header the Money and Portfolio segments put where the player card was.
struct MemberHeader: View {
    let member: Member

    var body: some View {
        HStack(spacing: 10) {
            MemberPortrait(member).frame(width: 36, height: 36)
            Text(member.fullName.uppercased())
                .font(Typography.label(24))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Everything under the member switcher for one member: the record, or the compact header, the
/// switch and the Money or Portfolio segment.
struct MemberSections: View {
    let record: RepScreenModel
    let member: Member?
    @Binding var section: MemberSection
    let fact: String?
    let onOpenVote: (Vote) -> Void

    var body: some View {
        switch section {
        case .record:
            RepRecordContent(model: record, fact: fact, onOpenVote: onOpenVote, section: $section)
        case .money, .portfolio:
            VStack(alignment: .leading, spacing: 16) {
                if let member { MemberHeader(member: member) }
                SectionSwitch(selection: $section)
                if section == .money {
                    MoneyContent(model: record.money, member: member)
                } else {
                    PortfolioPlaceholder()
                }
            }
        }
    }
}

// MARK: - Money

struct MoneyContent: View {
    let model: MoneyModel
    let member: Member?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().tint(Palette.accent)
                    Text("Loading \(name)'s FEC figures…")
                        .font(.caption).foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load \(name)'s FEC figures")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                    Text(message).font(.footnote).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                .panel()
            case let .loaded(body):
                VStack(alignment: .leading, spacing: 14) {
                    if let saved = model.saved { SavedDataNote(saved) }
                    if let funding = body.funding {
                        FundingFigures(funding: funding)
                    } else {
                        let copy = body.noFilings
                        VStack(alignment: .leading, spacing: 6) {
                            Text(copy.title).font(Typography.label(20)).foregroundStyle(Palette.text)
                            Text(copy.body)
                                .font(.footnote).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .panel()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .task { if model.needsRefresh { await model.load() } }
    }

    private var name: String { member?.lastName ?? "this member" }
}

/// The totals card, the context line, the PAC list and the explainer placeholder.
struct FundingFigures: View {
    let funding: Funding
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            totals
            contextLine
            pacList
            explainerPlaceholder
        }
    }

    /// `Tones.moneyBar`, in order, which `PaletteTests` checks part against part.
    private static let parts: [(part: Funding.Part, color: Color)] = [
        (.smallDollar, Palette.yea), (.itemized, Palette.teal), (.pac, Palette.threshold), (.other, Palette.dim),
    ]

    private var totals: some View {
        let raised = MoneyFormat.total(funding.receipts)
        let cash = funding.cashOnHand.map(MoneyFormat.total)
        let big = Text(raised)
            .font(Typography.display(54))
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        let cashStack = VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
            Text("cash on hand").font(.caption2).foregroundStyle(Palette.textMuted)
            Text(cash ?? "—").font(Typography.label(20)).foregroundStyle(Palette.text)
        }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(funding.period).font(.caption2).foregroundStyle(Palette.textMuted)
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) { big; cashStack }
                } else {
                    HStack(alignment: .bottom) { big; Spacer(minLength: 8); cashStack }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(funding.period). Raised \(MoneyFormat.spoken(funding.receipts))."
                    + (funding.cashOnHand.map { " Cash on hand \(MoneyFormat.spoken($0))." } ?? " No cash-on-hand figure.")
            )
            bar
            legend
            if let note = funding.adjustmentNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    /// The four parts in proportion, as `shown` (never below zero), so the bar and the legend agree.
    /// Decorative for VoiceOver: the legend below says the same.
    private var bar: some View {
        let amounts = Self.parts.map { funding.shown($0.part) }
        let sum = funding.shareBase
        return GeometryReader { geo in
            let gaps = CGFloat(Self.parts.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(Array(Self.parts.enumerated()), id: \.offset) { index, part in
                    part.color.frame(width: sum > 0 ? max(0, geo.size.width - gaps) * amounts[index] / sum : 0)
                }
            }
        }
        .frame(height: 18)
        .background(Palette.panelBorder)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var legend: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Self.parts, id: \.part) { part, color in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                    Text(part.label).foregroundStyle(Palette.text)
                    Spacer(minLength: 4)
                    Text(funding.percent(part)).bold().foregroundStyle(Palette.text).monospacedDigit()
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(part.label): \(funding.percent(part)), \(MoneyFormat.spoken(funding.shown(part)))")
            }
        }
    }

    private var contextLine: some View {
        (Text("CONTEXT, NOT CAUSE · ")
            .font(Typography.display(13, weight: .extraBoldItalic))
            .foregroundStyle(Palette.threshold)
            + Text("who gave, shown beside the record. Never why.")
            .foregroundStyle(Palette.textSecondary))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.threshold, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityElement(children: .combine)
    }

    private var pacList: some View {
        let checks = funding.pacChecks()
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BIGGEST PAC CHECKS").font(Typography.label(20)).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text(funding.pacsNote).font(.caption2).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if checks.isEmpty {
                let none = funding.pacsNone
                VStack(alignment: .leading, spacing: 4) {
                    Text(none.title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.text)
                    Text(none.body).font(.caption).foregroundStyle(Palette.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .overlay(alignment: .top) { Palette.panelBorder.frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
            ForEach(checks) { check in
                pacRow(check)
            }
            Text("Totals are what the campaign reported receiving; this list is what committees reported "
                + "giving. They come from different FEC filings and won't add up.")
                .font(.caption2)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Palette.panelBorder.frame(height: 1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.panelBorder, lineWidth: 1))
    }

    private func pacRow(_ check: PacCheck) -> some View {
        let name = check.displayName
        let spoken = check.direct.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        let title = Text(name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        // At accessibility sizes the name gets its own line, so the pill and amount don't squeeze it
        // to a word per line.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            title
            HStack(spacing: 8) { pacDetail(check) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Palette.panelBorder.frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, check.kind, spoken].compactMap(\.self).joined(separator: ", "))
    }

    @ViewBuilder
    private func pacDetail(_ check: PacCheck) -> some View {
            if let kind = check.kind {
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Palette.raised, lineWidth: 1))
                    .fixedSize()
            }
            Text(MoneyFormat.check(check.direct))
                .font(Typography.label(17))
                .foregroundStyle(Palette.text)
                .monospacedDigit()
                .fixedSize()
    }

    /// Where the mock's donor explainer goes. Nothing in it is written by a model: it says what
    /// will be here and why it isn't yet.
    private var explainerPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✦ FLOOR EXPLAINS · AI")
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(Palette.ai)
            Text("NOT LOADED YET")
                .font(Typography.label(22))
                .foregroundStyle(Palette.text)
            Text("Who each PAC is and what it lobbies on, beside any of this member's votes on the same "
                + "topic. It needs Senate lobbying filings, which Floor doesn't read yet, and every line "
                + "will be labelled as AI-written and cited to its filing.")
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Palette.ai, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Portfolio

/// Financial disclosures have no data and no API yet (the v0.3.0 milestone), so the segment says so
/// in the mock's own "new data" style rather than showing anything shaped like figures.
struct PortfolioPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NOT LOADED YET").fontWeight(.bold).foregroundStyle(Palette.threshold)
                Text("Needs House disclosure ingest — not in the API yet. Senate filings come later.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.threshold, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text("REPORTED ASSETS · RANGES, AS FILED")
                    .font(.caption2).tracking(0.7).foregroundStyle(Palette.textMuted)
                Text("Members report what they own and owe in value bands, and leave out their homes. "
                    + "When this loads, Floor will show those ranges as filed, and their trades — never a "
                    + "single net-worth figure.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .panel()
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview("Money · Jeffries") {
    ScrollView {
        FundingFigures(funding: .sample).padding(16)
    }
    .background(Palette.ground)
}

#Preview("Portfolio") {
    PortfolioPlaceholder().padding(16).background(Palette.ground)
}
