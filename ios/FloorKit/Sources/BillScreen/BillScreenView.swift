import APIClient
import DesignSystem
import Models
import SwiftUI

/// A bill, as the locked Bill mock draws it: the title, its sponsor, six levels to law with the
/// votes that moved it, your own members on it, and what it costs.
///
/// The mock's "Floor explains · AI" card is M4 and is not built. In its place sits the CRS summary,
/// labelled as such — it is the Congressional Research Service's text, not a model's.
public struct BillScreenView: View {
    @State private var model: BillScreenModel
    private let onOpenVote: (Vote) -> Void

    public init(model: BillScreenModel, onOpenVote: @escaping (Vote) -> Void) {
        _model = State(initialValue: model)
        self.onOpenVote = onOpenVote
    }

    public var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            content
        }
        .task { await model.load() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Palette.accent)
        case let .failed(message):
            VStack(spacing: 12) {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.load() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(24)
        case let .loaded(bill):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(bill)
                    levels(bill)
                    if let summary = bill.summary, !summary.isEmpty {
                        whatItDoes(summary, stage: bill.summaryStage)
                    }
                    if !model.yourMembers.isEmpty {
                        yourMembers
                    }
                    if !bill.cboEstimates.isEmpty {
                        cost(bill)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .toolbar {
                // The mocks show only the back link and this label; an empty principal item hides the
                // screen's title, which still names the back link on the next screen.
                ToolbarItem(placement: .principal) { Text(verbatim: " ").accessibilityHidden(true) }
                ToolbarItem(placement: .primaryAction) {
                    Text("\(bill.citation) · \(StateName.ordinal(bill.congress)) CONGRESS".uppercased())
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize()
                }
            }
        }
    }

    private func header(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bill.displayTitle.uppercased())
                .font(Typography.headline(46))
                .foregroundStyle(Palette.text)
                .lineLimit(4)
                .minimumScaleFactor(0.5)
            Text(sponsorLine(bill))
                .font(.system(size: 13))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func sponsorLine(_ bill: Bill) -> String {
        var parts: [String] = []
        if let sponsor = bill.sponsor { parts.append(sponsor.sponsorLine) }
        if let area = bill.policyArea { parts.append(area) }
        if let day = bill.introducedOn.flatMap(Formats.dayText) { parts.append("introduced \(day)") }
        return parts.joined(separator: " · ")
    }

    private func levels(_ bill: Bill) -> some View {
        let levels = LawLevels(bill: bill)
        let blocked = levels.levels.contains { $0.state == .stuck || $0.state == .failed }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("SIX LEVELS TO LAW").font(Typography.label(20)).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(levels.status)
                    .font(Typography.label(16))
                    .foregroundStyle(blocked ? Palette.nay : (levels.isLaw || levels.isComplete ? Palette.yea : Palette.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(levels.levels) { level in
                    levelColumn(level)
                }
            }
            if !bill.votes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(bill.votes.reversed()) { vote in
                        Button { onOpenVote(vote) } label: { play(vote) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .panel()
    }

    private func levelColumn(_ level: LawLevels.Level) -> some View {
        let bar: Color = switch level.state {
        case .done: Palette.yea
        case .stuck, .failed: Palette.nay
        case .pending, .notApplicable: Palette.panelBorder
        }
        let reached = level.state == .done || level.state == .stuck || level.state == .failed
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(bar).frame(height: 8)
            Text("\(level.number)")
                .font(Typography.label(18))
                .foregroundStyle(reached ? Palette.text : Palette.raised)
            Text(level.state == .notApplicable ? "—" : level.name)
                .font(.system(size: 9))
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if level.boss {
                SkewChip("BOSS", background: Palette.threshold, size: 9)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level.number), \(level.name): \(describe(level.state))\(level.boss ? ", supermajority" : "")")
    }

    private func describe(_ state: LawLevels.State) -> String {
        switch state {
        case .done: "done"
        case .pending: "not yet"
        case .stuck: "stuck"
        case .failed: "failed"
        case .notApplicable: "does not apply"
        }
    }

    private func play(_ vote: Vote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 48, alignment: .leading)
            Text(vote.kind == .election ? vote.question : vote.playDescription)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(vote.totals.yea)–\(vote.totals.nay)")
                .font(Typography.label(18))
                .monospacedDigit()
                .foregroundStyle(Palette.outcome(vote.outcome))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Palette.card).frame(height: 1) }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the vote")
    }

    private func whatItDoes(_ summary: String, stage: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT IT DOES").font(Typography.label(20)).foregroundStyle(Palette.text)
                Spacer()
                if let stage {
                    Text(stage).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                }
            }
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            // Not our words, and not a model's: the Congressional Research Service summary for the
            // stage named above.
            Text("Congressional Research Service summary")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
        }
        .panel()
    }

    private var yourMembers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR THREE ON THIS BILL").font(Typography.label(20)).foregroundStyle(Palette.text)
            ForEach(model.yourMembers) { entry in
                HStack(spacing: 10) {
                    MemberPortrait(entry.member).frame(width: 34, height: 34)
                    Group {
                        if let vote = entry.vote {
                            Text("**\(entry.member.lastName)** · \(vote.chamber.name) \(vote.questionKind.lowercased())")
                        } else {
                            Text("**\(entry.member.lastName)** · no \(entry.member.chamber.name) vote on it yet")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let position = entry.position {
                        Text(position == .candidate ? (entry.choice ?? "BALLOT").uppercased() : position.shortLabel)
                            .font(Typography.display(20, weight: .blackItalic))
                            .foregroundStyle(Palette.position(position))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    private func cost(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COST").font(Typography.label(20)).foregroundStyle(Palette.text)
            Text(bill.cboEstimates.count == 1
                 ? "Congressional Budget Office estimate available."
                 : "\(bill.cboEstimates.count) Congressional Budget Office estimates available.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
            ForEach(bill.cboEstimates) { estimate in
                if let url = URL(string: estimate.url) {
                    Link(destination: url) {
                        Text(bill.cboEstimates.count == 1 ? "Open the CBO estimate ›" : "\(estimate.title) ›")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.yea)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .panel()
    }
}

#Preview("Bill") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        BillScreenView(
            model: BillScreenModel(billId: "119-hr-9340", api: FloorAPI(baseURL: FloorAPI.localDevelopment)),
            onOpenVote: { _ in }
        )
    }
}
