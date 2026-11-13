import APIClient
import DesignSystem
import Models
import SwiftUI

/// Your three, as the locked AppRep mock draws it: a switcher across your members, then the
/// selected one's record.
///
/// The mock's Record / Money / Portfolio switch is not built: Money and Portfolio need data the API
/// does not serve, and a switch with one live option is dead UI.
public struct YourThreeView: View {
    @State private var model: YourThreeModel
    private let onOpenVote: (Vote) -> Void

    public init(model: YourThreeModel, onOpenVote: @escaping (Vote) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.onOpenVote = onOpenVote
    }

    public var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switcher
                    if let member = model.members.first(where: { $0.bioguideId == model.selectedId }),
                       let record = model.selected {
                        RepRecordContent(model: record, fact: model.fact(for: member), onOpenVote: onOpenVote)
                            .id(member.bioguideId)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .task { await model.loadAll() }
    }

    private var switcher: some View {
        HStack(spacing: 8) {
            ForEach(model.members) { member in
                let on = member.bioguideId == model.selectedId
                Button { model.selectedId = member.bioguideId } label: {
                    HStack(spacing: 6) {
                        MemberPortrait(member).frame(width: 28, height: 28)
                        Text(member.lastName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                    .padding(EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 8))
                    .frame(maxWidth: .infinity)
                    .background(on ? Palette.card : Palette.panel, in: .capsule)
                    .overlay(Capsule().stroke(on ? Palette.yea : Palette.panelBorder, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(member.fullName)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

/// One member's record pushed on its own, e.g. from a vote's "Your three".
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
            ScrollView {
                RepRecordContent(model: model, fact: nil, onOpenVote: onOpenVote)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
        }
        .task { if case .loading = model.phase { await model.load() } }
    }
}

/// The player card, the three rings, the last-40 grid and the fact.
struct RepRecordContent: View {
    let model: RepScreenModel
    /// A fact computed with the rest of the delegation in view; nil computes one from this record.
    let fact: String?
    let onOpenVote: (Vote) -> Void
    @State private var selectedCall: Int?

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 60)
        case let .failed(message):
            VStack(spacing: 12) {
                Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
                Button("Try again") { Task { await model.load() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        case let .loaded(record):
            let stats = RecordStats(votes: record.votes)
            let member = record.detail.member
            VStack(alignment: .leading, spacing: 16) {
                playerCard(record.detail)
                rings(record.detail.partyLoyalty, stats, member: member)
                grid(stats)
                if let text = fact ?? RecordFacts.didYouKnow(member: member, votes: record.votes) {
                    HStack(alignment: .top, spacing: 10) {
                        Text("DID YOU KNOW")
                            .font(Typography.display(15, weight: .blackItalic))
                            .foregroundStyle(Palette.threshold)
                            .fixedSize()
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panel()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func playerCard(_ detail: MemberDetail) -> some View {
        let member = detail.member
        let loyalty = detail.partyLoyalty
        let unity = loyalty.withPartyShare.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        return HStack(spacing: 0) {
            MemberPortrait(member, cornerRadius: 0).frame(width: 130, height: 170)
            VStack(alignment: .leading, spacing: 6) {
                SkewChip("\(Tier(crossovers: loyalty.againstParty).rawValue) · \(member.badge)",
                         foreground: Palette.silverInk, background: Palette.silver[2], size: 11)
                Text(member.fullName.uppercased())
                    .font(Typography.label(26))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(-4)
                    .minimumScaleFactor(0.6)
                Text(member.seatLine).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 4)
                Rectangle().fill(Palette.panelBorder).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(unity).font(Typography.label(22)).foregroundStyle(Palette.text)
                        Text("W/ PARTY").font(.system(size: 9)).foregroundStyle(Palette.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(loyalty.againstParty)").font(Typography.label(22)).foregroundStyle(Palette.threshold)
                        Text("CROSSOVERS").font(.system(size: 9)).foregroundStyle(Palette.textMuted)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
        .background(Palette.panel)
        .clipShape(.rect(cornerRadius: 14))
        .padding(5)
        .background(LinearGradient(colors: Palette.silver, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.fullName), \(member.seatLine). \(Tier(crossovers: loyalty.againstParty).rawValue.capitalized). "
                + (loyalty.withPartyShare == nil ? "No party-loyalty figure. " : "\(unity) with party. ")
                + "\(loyalty.againstParty) crossovers."
        )
    }

    private func rings(_ loyalty: PartyLoyalty, _ stats: RecordStats, member: Member) -> some View {
        let withParty = loyalty.withPartyShare
        let showedSub = stats.present > 0 ? "\(stats.present) present"
            : stats.missed > 0 ? "\(stats.missed) missed" : "last \(stats.calls.count)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ring(share: withParty, color: Palette.yea,
                     big: withParty.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                     label: "With party",
                     sub: withParty == nil ? "party of one" : "\(loyalty.withParty.formatted()) of \(loyalty.votes.formatted())")
                ring(share: stats.showedUpShare, color: Palette.text,
                     big: "\(stats.showedUp)/\(stats.calls.count)", label: "Showed up", sub: showedSub)
                ring(share: stats.winningShare, color: Palette.nay,
                     big: "\(stats.sidedWithOutcome)/\(stats.decided)", label: "Winning side",
                     sub: "last \(stats.calls.count)")
            }
            // The denominator, spelled out, because a bare percentage invites the wrong reading
            // (lesson 15): votes where their party had a clear majority, not every vote cast.
            Text(withParty == nil
                 ? "\(member.fullName) sits outside the two parties, so there is no party majority to measure against."
                 : "With party counts votes where \(member.party) had a clear majority, not every vote cast.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Palette.panel, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.panelBorder, lineWidth: 1))
    }

    private func ring(share: Double?, color: Color, big: String, label: String, sub: String) -> some View {
        VStack(spacing: 4) {
            Ring(share: share, color: color, lineWidth: 6.5) {
                Text(big).font(Typography.label(20)).foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 8)
            }
            .frame(width: 78, height: 78)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
            Text(sub).font(.system(size: 10)).foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(big == "—" ? "no figure" : big), \(sub)")
    }

    private func grid(_ stats: RecordStats) -> some View {
        let calls = stats.calls
        let selected = calls.isEmpty ? nil : min(selectedCall ?? calls.count - 1, calls.count - 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("LAST \(calls.count) CALLS").font(Typography.label(20)).foregroundStyle(Palette.text)
            if calls.isEmpty {
                Text("No votes on record yet.").font(.system(size: 13)).foregroundStyle(Palette.textMuted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 10), spacing: 5) {
                ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                    Button { selectedCall = index } label: { square(call, on: index == selected) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(call.spokenSummary)
                        .accessibilityAddTraits(index == selected ? [.isSelected] : [])
                }
            }
            if let selected {
                readout(calls[selected])
            }
        }
        .panel()
    }

    private func square(_ call: MemberVote, on: Bool) -> some View {
        let fill: Color = switch call.position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present: Palette.textMuted
        case .candidate: Palette.textSecondary
        case .notVoting: .clear
        }
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .overlay {
                if call.position == .notVoting {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Palette.textMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(1)
            .overlay {
                if on { RoundedRectangle(cornerRadius: 5).stroke(Palette.text, lineWidth: 2) }
            }
    }

    private func readout(_ call: MemberVote) -> some View {
        let tone = Palette.position(call.position)
        let label = call.position == .candidate ? (call.choice ?? "BALLOT").uppercased() : call.position.shortLabel
        return Button { onOpenVote(call.vote) } label: {
            HStack(spacing: 10) {
                Text(label)
                    .font(Typography.label(15))
                    .foregroundStyle(call.position == .notVoting ? Palette.textMuted : tone)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(call.position == .yea || call.position == .nay ? tone.opacity(0.16) : Palette.panelBorder,
                                in: .rect(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(call.cite) · \(call.vote.questionKind)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    Text([call.vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day()), call.vote.result]
                        .compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if call.vote.kind == .question {
                    (Text("\(call.vote.totals.yea)").foregroundStyle(Palette.yea)
                        + Text("–").foregroundStyle(Palette.text)
                        + Text("\(call.vote.totals.nay)").foregroundStyle(Palette.nay))
                        .font(Typography.label(20))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.ground, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the vote")
    }
}

#Preview("Your three") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        YourThreeView(model: YourThreeModel(members: [.sample, .sampleSenator], api: FloorAPI(baseURL: FloorAPI.localDevelopment)))
    }
}
