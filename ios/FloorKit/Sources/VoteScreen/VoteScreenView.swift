import APIClient
import DesignSystem
import Models
import SwiftUI

/// One vote in full: the score with each party's split, how close it came to its threshold, and how
/// your own members voted.
///
/// Follows the v2 canvas's Matchup artboard minus what needs data we do not have — the live timer,
/// pending-member count, projection and "what it means for you" block are M3 and M4.
public struct VoteScreenView: View {
    @State private var model: VoteScreenModel
    private let onOpenMeasure: (MeasureSummary) -> Void
    private let onOpenMember: (Member) -> Void

    /// - Parameters:
    ///   - onOpenMeasure: pushes the bill or nomination this vote was on.
    ///   - onOpenMember: pushes one of your own members' records.
    ///
    /// Both are passed in rather than linked directly, so this package need not depend on the bill
    /// or rep screens — the bill screen links back to votes, which would be a cycle.
    public init(
        model: VoteScreenModel,
        onOpenMeasure: @escaping (MeasureSummary) -> Void = { _ in },
        onOpenMember: @escaping (Member) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.onOpenMeasure = onOpenMeasure
        self.onOpenMember = onOpenMember
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
        case let .loaded(detail):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(detail)
                    if detail.vote.kind == .election {
                        electionBoard(detail)
                    } else {
                        scoreboard(detail)
                        thresholdBar(detail)
                    }
                    if !detail.positions.isEmpty {
                        yourMembers(detail)
                    }
                    partyTable(detail)
                    if let measure = detail.measure {
                        measureLink(measure)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
    }

    private func header(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow(detail.vote))
                .font(Typography.eyebrow)
                .tracking(0.9)
                .foregroundStyle(Palette.textMuted)
            Text(detail.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if detail.measure != nil {
                // The question is the headline only when there is no measure to name.
                Text(detail.vote.question)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = detail.vote.result {
                Text(result.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(outcomeColor(detail))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(outcomeColor(detail).opacity(0.14), in: .capsule)
                    .padding(.top, 2)
            }
        }
    }

    private func eyebrow(_ vote: Vote) -> String {
        var parts = [vote.chamber.rawValue.uppercased()]
        if let roll = vote.rollNumber { parts.append("ROLL CALL \(roll)") }
        if let date = vote.occurredAtDate {
            parts.append(date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private func outcomeColor(_ detail: VoteDetail) -> Color {
        guard detail.vote.kind == .question else { return Palette.textSecondary }
        return detail.votesShortOfThreshold == nil && detail.vote.leader == .yea
            ? Palette.yea
            : Palette.nay
    }

    private func scoreboard(_ detail: VoteDetail) -> some View {
        HStack(spacing: 0) {
            sideColumn(
                label: "Yea", value: detail.vote.totals.yea, split: detail.partySplit(.yea),
                color: Palette.yea, leading: detail.vote.leader != .nay
            )
            Rectangle()
                .fill(Palette.track)
                .frame(width: 1, height: 68)
            sideColumn(
                label: "Nay", value: detail.vote.totals.nay, split: detail.partySplit(.nay),
                color: Palette.nay, leading: detail.vote.leader != .yea
            )
        }
        .padding(.vertical, 18)
        .background(Palette.card, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.cardBorder, lineWidth: 1))
    }

    private func sideColumn(
        label: String, value: Int, split: String, color: Color, leading: Bool
    ) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text("\(value)")
                .font(Typography.score(52))
                .monospacedDigit()
                .foregroundStyle(leading ? Palette.text : Palette.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(split)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value). \(split)")
    }

    private func thresholdBar(_ detail: VoteDetail) -> some View {
        let totals = detail.vote.totals
        let cast = max(totals.voting, 1)
        let needed = detail.vote.votesNeeded
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    HStack(spacing: 0) {
                        Rectangle().fill(Palette.yea)
                            .frame(width: width * CGFloat(totals.yea) / CGFloat(cast))
                        Rectangle().fill(Palette.nay)
                            .frame(width: width * CGFloat(totals.nay) / CGFloat(cast))
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                    // The line the winning side had to cross.
                    Rectangle()
                        .fill(Palette.text)
                        .frame(width: 2, height: 16)
                        .offset(x: min(width - 2, width * CGFloat(needed) / CGFloat(cast)))
                }
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                Text("Needed \(needed) of \(cast) cast")
                if let short = detail.votesShortOfThreshold {
                    Text("· \(short) short").foregroundStyle(Palette.nay)
                }
                Spacer()
                if totals.notVoting > 0 {
                    Text("\(totals.notVoting) did not vote")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func electionBoard(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ballot")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            ForEach(detail.candidatesByStrength, id: \.candidate) { entry in
                HStack(spacing: 12) {
                    Text(entry.candidate)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    Text(entry.parties.map { "\($0.party) \($0.total)" }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                    Text("\(entry.total)")
                        .font(Typography.score(26))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Palette.card, in: .rect(cornerRadius: 16))
            }
            if let elected = detail.vote.electedSpeaker {
                Text("\(elected.name) elected Speaker")
                    .font(Typography.body)
                    .foregroundStyle(Palette.yea)
            } else {
                // Most ballots of a contested election settle nothing, and the card must not imply
                // the leader won.
                Text("No candidate reached a majority; the House balloted again.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func yourMembers(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your members")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            ForEach(detail.positions) { position in
                Button { onOpenMember(position.member) } label: {
                    memberRow(position)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func memberRow(_ position: MemberPosition) -> some View {
        HStack(spacing: 12) {
                    Text(position.member.party)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.party(position.member.party))
                        .frame(width: 28, height: 28)
                        .background(Palette.party(position.member.party).opacity(0.16), in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(position.member.fullName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        Text(position.member.partyAndSeat)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textMuted)
                    }
                    Spacer(minLength: 8)
            Text(positionLabel(position))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(positionColor(position.position))
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.textMuted)
        }
        .padding(14)
        .background(Palette.card, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position.member.fullName) \(positionLabel(position))")
    }

    private func positionLabel(_ position: MemberPosition) -> String {
        switch position.position {
        case .yea: "Yea"
        case .nay: "Nay"
        case .present: "Present"
        case .notVoting: "Did not vote"
        case .candidate: position.choice ?? "Candidate"
        }
    }

    private func positionColor(_ position: Position) -> Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present, .notVoting: Palette.textMuted
        case .candidate: Palette.text
        }
    }

    private func partyTable(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By party")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            VStack(spacing: 0) {
                ForEach(Array(detail.significantParties.enumerated()), id: \.element.party) { index, row in
                    if index > 0 { Divider().overlay(Palette.track) }
                    HStack(spacing: 10) {
                        Text(row.party)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Palette.party(row.party))
                            .frame(width: 28, height: 28)
                            .background(Palette.party(row.party).opacity(0.16), in: .circle)
                        cell("Yea", row.yea, Palette.yea)
                        cell("Nay", row.nay, Palette.nay)
                        cell("Present", row.present, Palette.textMuted)
                        cell("Absent", row.notVoting, Palette.textMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(row.party): \(row.yea) yea, \(row.nay) nay, \(row.present) present, \(row.notVoting) did not vote"
                    )
                }
            }
            .background(Palette.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.cardBorder, lineWidth: 1))
        }
    }

    private func measureLink(_ measure: MeasureSummary) -> some View {
        Button { onOpenMeasure(measure) } label: {
            HStack(spacing: 10) {
                Image(systemName: measure.kind == .bill ? "doc.text" : "person.crop.square")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(measure.kind == .bill ? "The bill" : "The nomination")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(measure.citation)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(14)
            .background(Palette.card, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        // A nomination has no screen yet, so only offer the one that does.
        .disabled(measure.kind != .bill)
        .opacity(measure.kind == .bill ? 1 : 0.5)
    }

    private func cell(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? Palette.text : Palette.trailing)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Vote") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        VoteScreenView(
            model: VoteScreenModel(
                voteId: "house-119-1-100",
                memberIds: ["A000370", "K000401"],
                api: FloorAPI(baseURL: FloorAPI.localDevelopment)
            )
        )
    }
}
