import APIClient
import DesignSystem
import Models
import SwiftUI

/// A member's record: who they are, how often they side with their own party, and recent votes.
///
/// Follows the v2 canvas's Player artboard, minus what needs data we do not hold: attendance
/// percentage and the rank among all 435 need every member's record computed, committee
/// assignments and term count are not in our data at all, and the live-vote strip is M3.
public struct RepScreenView: View {
    @State private var model: RepScreenModel
    private let onOpenVote: (Vote) -> Void

    public init(model: RepScreenModel, onOpenVote: @escaping (Vote) -> Void = { _ in }) {
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
        case let .loaded(record):
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(record.detail.member)
                    stats(record.detail.partyLoyalty, member: record.detail.member)
                    votes(record.votes)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
    }

    private func header(_ member: Member) -> some View {
        HStack(spacing: 14) {
            Text(initials(member))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(width: 62, height: 62)
                .background(Palette.partyTint(member.party), in: .circle)
                .overlay(
                    Circle().stroke(Palette.party(member.party), lineWidth: 2)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(member.roleLine.uppercased())
                    .font(Typography.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Palette.textMuted)
                Text(member.fullName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stats(_ loyalty: PartyLoyalty, member: Member) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("With their party")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            if let unity = loyalty.unityPercent {
                HStack(spacing: 10) {
                    tile("\(unity)%", "Party unity", Palette.party(member.party))
                    tile("\(loyalty.againstParty)", "Crossovers", Palette.nay)
                    tile("\(loyalty.votes)", "Votes counted", Palette.textMuted)
                }
                Text("Of \(loyalty.votes) votes where \(member.party) had a clear majority, \(member.fullName) sided with it \(loyalty.withParty) times.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // An independent has no party majority to be measured against — a bloc of one would
                // score 100% every time, which says nothing. See the handoff's lesson 15.
                Text("\(member.fullName) sits outside the two parties, so there is no party majority to measure against.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card, in: .rect(cornerRadius: 18))
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Palette.card, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func votes(_ votes: [MemberVote]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent votes")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("\(votes.count)")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textMuted)
            }
            if votes.isEmpty {
                Text("No votes on record yet.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textMuted)
            } else {
                ForEach(votes) { row in
                    Button { onOpenVote(row.vote) } label: {
                        voteRow(row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func voteRow(_ row: MemberVote) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.rowTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let day = row.vote.occurredAtDate {
                        Text(day.formatted(.dateTime.month(.abbreviated).day()))
                    }
                    Text(row.vote.chamber.rawValue.capitalized)
                    Text("·")
                    Text("\(row.vote.totals.yea)–\(row.vote.totals.nay)")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 8)
            positionBadge(row)
        }
        .padding(14)
        .background(Palette.card, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.rowTitle). Voted \(label(row)).")
    }

    private func positionBadge(_ row: MemberVote) -> some View {
        VStack(spacing: 2) {
            Text(label(row))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color(row.position))
            if let agreed = row.agreedWithOutcome {
                Text(agreed ? "with outcome" : "against")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(minWidth: 62, alignment: .trailing)
    }

    private func label(_ row: MemberVote) -> String {
        switch row.position {
        case .yea: "Yea"
        case .nay: "Nay"
        case .present: "Present"
        case .notVoting: "Absent"
        case .candidate: row.choice ?? "Candidate"
        }
    }

    private func color(_ position: Position) -> Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present, .notVoting: Palette.textMuted
        case .candidate: Palette.text
        }
    }

    private func initials(_ member: Member) -> String {
        let first = member.firstName.first.map(String.init) ?? ""
        let last = member.lastName.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

#Preview("Rep") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        RepScreenView(
            model: RepScreenModel(bioguideId: "A000370", api: FloorAPI(baseURL: FloorAPI.localDevelopment))
        )
    }
}
