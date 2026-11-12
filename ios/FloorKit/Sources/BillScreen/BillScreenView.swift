import APIClient
import DesignSystem
import Models
import SwiftUI

/// Loads one bill.
@MainActor
@Observable
public final class BillScreenModel {
    public enum Phase: Equatable {
        case loading
        case loaded(Bill)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    private let billId: String
    private let api: FloorAPI

    public init(billId: String, api: FloorAPI) {
        self.billId = billId
        self.api = api
    }

    public func load() async {
        phase = .loading
        do {
            phase = .loaded(try await api.bill(id: billId))
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load this bill.")
        } catch {
            phase = .failed("Couldn't load this bill.")
        }
    }
}

/// A bill: what it is, where it has got to, what it cost, and every vote on it.
///
/// Follows the v2 canvas's Bill artboard minus what needs data we do not have — the live vote
/// strip, the "what it means for you" block, the derived impact tiles and the supporters/opponents
/// quotes are M3 and M4.
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
                VStack(alignment: .leading, spacing: 22) {
                    header(bill)
                    pathToLaw(bill)
                    if let summary = bill.summary, !summary.isEmpty {
                        whatItDoes(summary, stage: bill.summaryStage)
                    }
                    if !bill.cboEstimates.isEmpty {
                        cboEstimates(bill)
                    }
                    if !bill.votes.isEmpty {
                        votes(bill)
                    }
                    latestAction(bill)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
    }

    private func header(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(bill.citation) · \(bill.congress)TH CONGRESS")
                .font(Typography.eyebrow)
                .tracking(0.9)
                .foregroundStyle(Palette.textMuted)
            Text(bill.displayTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            // The full title goes below the short one, unless they are the same string — some
            // bills carry an identical short title, and printing it twice reads as a bug.
            if let short = bill.shortTitle, short != bill.title {
                Text(bill.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sponsor = bill.sponsor {
                Text("Sponsored by \(sponsor.fullName) (\(sponsor.partyAndSeat))")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
            if let area = bill.policyArea {
                Text(area)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accentSoft)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Palette.accent.opacity(0.14), in: .capsule)
            }
        }
    }

    private func pathToLaw(_ bill: Bill) -> some View {
        let progress = BillProgress(bill: bill)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Path to law")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(progress.steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, isLast: index == progress.steps.count - 1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.cardBorder, lineWidth: 1))
        }
    }

    /// Its own function because inline this expression exceeds the type-checker's budget.
    private func stepRow(_ step: BillProgress.Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker(step.state)
                if !isLast {
                    Rectangle()
                        .fill(step.state == .done ? Palette.yea.opacity(0.5) : Palette.track)
                        .frame(width: 2, height: 26)
                }
            }
            stepLabel(step)
                .padding(.bottom, isLast ? 0 : 10)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.label): \(describe(step.state))")
    }

    private func stepLabel(_ step: BillProgress.Step) -> some View {
        let day = step.on.flatMap(Formats.dayText)
        return VStack(alignment: .leading, spacing: 1) {
            Text(step.label)
                .font(.system(size: 15, weight: step.state == .pending ? .regular : .semibold))
                .foregroundStyle(step.state == .pending ? Palette.textMuted : Palette.text)
            if let day {
                Text(day)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
            } else if step.state == .failed {
                Text("Rejected here")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.nay)
            }
        }
    }

    private func describe(_ state: BillProgress.State) -> String {
        switch state {
        case .done: "done"
        case .failed: "rejected"
        case .pending: "not yet"
        }
    }

    @ViewBuilder
    private func marker(_ state: BillProgress.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Palette.ground)
                .frame(width: 20, height: 20)
                .background(Palette.yea, in: .circle)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Palette.ground)
                .frame(width: 20, height: 20)
                .background(Palette.nay, in: .circle)
        case .pending:
            Circle()
                .stroke(Palette.track, lineWidth: 2)
                .frame(width: 20, height: 20)
        }
    }

    private func whatItDoes(_ summary: String, stage: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("What it does")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.text)
                Spacer()
                if let stage {
                    Text(stage)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Text(summary)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            // Not our words, and not a model's: this is the Congressional Research Service summary
            // for the stage named above.
            Text("Congressional Research Service summary")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 18))
    }

    private func cboEstimates(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost estimates")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            ForEach(bill.cboEstimates) { estimate in
                if let url = URL(string: estimate.url) {
                    Link(destination: url) {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.accent)
                            Text(estimate.title)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.text)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Palette.textMuted)
                        }
                        .padding(14)
                        .background(Palette.card, in: .rect(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private func votes(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Votes on this bill")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            ForEach(bill.votes) { vote in
                Button { onOpenVote(vote) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vote.chamber.rawValue.uppercased()) · \(vote.question)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.text)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            if let result = vote.result {
                                Text(result)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("\(vote.totals.yea)–\(vote.totals.nay)")
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.text)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .padding(14)
                    .background(Palette.card, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func latestAction(_ bill: Bill) -> some View {
        if let latest = bill.latestAction {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest action")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.text)
                Text(latest.text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let day = Formats.dayText(latest.on) {
                    Text(day)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 18))
        }
    }
}

#Preview("Bill") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        BillScreenView(
            model: BillScreenModel(billId: "118-hr-3746", api: FloorAPI(baseURL: FloorAPI.localDevelopment)),
            onOpenVote: { _ in }
        )
    }
}
