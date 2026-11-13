import APIClient
import BillScreen
import DesignSystem
import Models
import SwiftUI

/// One vote, as the locked Vote mock draws it: a broadcast scoreboard, the threshold bar, the box
/// score by party, your three, the bill's level of six, and the full roll as squares by party.
///
/// The mock's full roll says "tap a square to see who". The API reports a vote's party counts and
/// your own members' positions, not every member's, so the squares here are counts and carry no
/// names; the caption says what they are instead.
public struct VoteScreenView: View {
    @State private var model: VoteScreenModel
    private let onOpenMeasure: (MeasureSummary) -> Void
    private let onOpenMember: (Member) -> Void

    /// - Parameters:
    ///   - onOpenMeasure: pushes the bill or nomination this vote was on.
    ///   - onOpenMember: shows one of your own members' records.
    ///
    /// Both are passed in rather than linked directly: the bill screen links back to votes, so the
    /// navigation lives with whoever owns the stack.
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
        .task { if case .loading = model.phase { await model.load() } }
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
                    if detail.vote.kind == .election {
                        electionBoard(detail)
                        candidateTable(detail)
                    } else {
                        broadcast(detail)
                        if let line = detail.vote.line { thresholdBar(line, detail.vote.totals) }
                        boxScore(detail)
                    }
                    yourThree(detail)
                    if let measure = detail.measure {
                        measureLink(measure)
                    }
                    if detail.vote.kind == .question, !detail.rollParties.isEmpty {
                        fullRoll(detail)
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
                    Text(rollLabel(detail.vote))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize()
                }
            }
        }
    }

    private func rollLabel(_ vote: Vote) -> String {
        [vote.chamber.name.uppercased(), vote.rollNumber.map { "ROLL \($0)" }].compactMap(\.self).joined(separator: " · ")
    }

    private func when(_ vote: Vote) -> String? {
        vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: - Scoreboard

    private func turf<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background {
                Canvas { context, size in
                    var x: CGFloat = 0
                    var alt = false
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 48, height: size.height)),
                                     with: .color(alt ? Palette.turfAlt : Palette.turf))
                        x += 48
                        alt.toggle()
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.turfBorder, lineWidth: 1))
            // A broadcast scoreboard is a lit display, so it stays dark in light mode.
            .litObject()
    }

    private func broadcast(_ detail: VoteDetail) -> some View {
        let vote = detail.vote
        return turf {
            VStack(spacing: 0) {
                HStack {
                    Text([vote.questionKind, when(vote)].compactMap(\.self).joined(separator: " · "))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text("NEEDED \(vote.votesNeeded)")
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.threshold)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

                HStack(alignment: .bottom, spacing: 22) {
                    bigSide("YEA", vote.totals.yea, Palette.yea)
                    SkewChip(vote.state == .final ? "FINAL" : "VOTING", size: 16)
                        .padding(.bottom, 26)
                    bigSide("NAY", vote.totals.nay, Palette.nay)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 14)

                HStack(spacing: 0) {
                    Text(vote.outcomeWord ?? "FINAL")
                        .font(Typography.label(15))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                        .background(Palette.outcome(vote.outcome))
                    Text(detail.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.ground.opacity(0.92))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(vote.questionKind). \(detail.title). Yea \(vote.totals.yea), Nay \(vote.totals.nay). "
                + "\(vote.outcomeWord?.capitalized ?? "Final"). Needed \(vote.votesNeeded)."
        )
    }

    private func bigSide(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(label).font(Typography.label(14)).tracking(1.7).foregroundStyle(color)
            Text("\(value)")
                .font(Typography.display(96, weight: .blackItalic, scales: false))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func thresholdBar(_ line: ThresholdLine, _ totals: VoteTotals) -> some View {
        VStack(spacing: 8) {
            ThresholdBar(line: line, height: 12)
            HStack {
                if let over = line.over {
                    Text(over == 1 ? "1 vote over the line" : "\(over) votes over the line")
                } else if let short = line.short {
                    Text("\(short) short").foregroundStyle(Palette.nay)
                }
                Spacer()
                if totals.notVoting > 0 { Text("\(totals.notVoting) did not vote") }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.textMuted)
        }
    }

    private func boxScore(_ detail: VoteDetail) -> some View {
        let present = detail.anyPresent
        let totals = detail.vote.totals
        return VStack(alignment: .leading, spacing: 6) {
            Text("BOX SCORE").font(Typography.label(20)).foregroundStyle(Palette.text)
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("TEAM").gridColumnAlignment(.leading)
                    Text("YEA")
                    Text("NAY")
                    if present { Text("PRES") }
                    Text("DNP")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .padding(.vertical, 6)
                ForEach(detail.boxScore) { row in
                    Divider().overlay(Palette.panelBorder)
                    GridRow {
                        Text(PartyName.plural(row.party)).fontWeight(.semibold).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(row.yea)").fontWeight(.bold).foregroundStyle(Palette.yea)
                        Text("\(row.nay)").fontWeight(.bold).foregroundStyle(Palette.nay)
                        if present { Text("\(row.present)").foregroundStyle(Palette.textMuted) }
                        Text("\(row.notVoting)").foregroundStyle(Palette.textMuted)
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(PartyName.plural(row.party)): \(row.yea) yea, \(row.nay) nay, \(row.present) present, \(row.notVoting) did not play")
                }
                Divider().overlay(Palette.panelBorder)
                GridRow {
                    Text("TOTAL").frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(totals.yea)").foregroundStyle(Palette.yea)
                    Text("\(totals.nay)").foregroundStyle(Palette.nay)
                    if present { Text("\(totals.present)").foregroundStyle(Palette.textMuted) }
                    Text("\(totals.notVoting)").foregroundStyle(Palette.textMuted)
                }
                .font(Typography.label(18))
                .padding(.vertical, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Total: \(totals.yea) yea, \(totals.nay) nay, \(totals.notVoting) did not vote")
            }
            .monospacedDigit()
            if let sentence = detail.crossoverSentence {
                Text(sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    // MARK: - Speaker election

    private func electionBoard(_ detail: VoteDetail) -> some View {
        let leaders = detail.candidatesByStrength.prefix(2)
        let elected = detail.vote.electedSpeaker
        return turf {
            VStack(spacing: 0) {
                HStack {
                    Text([detail.vote.question, when(detail.vote)].compactMap(\.self).joined(separator: " · "))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text("MAJORITY OF NAMES CAST").fontWeight(.semibold).foregroundStyle(Palette.threshold)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(Array(leaders.enumerated()), id: \.element.candidate) { index, entry in
                        VStack(spacing: 0) {
                            Text(entry.candidate.uppercased()).font(Typography.label(14)).tracking(1.2)
                                .foregroundStyle(Palette.textSecondary).lineLimit(1)
                            Text("\(entry.total)")
                                .font(Typography.display(80, weight: .blackItalic, scales: false))
                                .foregroundStyle(index == 0 ? Palette.text : Palette.trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }
                }
                .padding(.vertical, 14)
                HStack(spacing: 0) {
                    Text(elected == nil ? "NO WINNER" : "ELECTED")
                        .font(Typography.label(15))
                        .foregroundStyle(elected == nil ? Palette.text : Palette.ground)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                        .background(elected == nil ? Palette.raised : Palette.yea)
                    // Leading a ballot is not winning it: 17 of the 20 Speaker ballots since 2023
                    // elected nobody (lesson 16).
                    Text(elected.map { "\($0.name) elected Speaker" } ?? "No candidate reached a majority; the House balloted again.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.ground.opacity(0.92))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func candidateTable(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BALLOT").font(Typography.label(20)).foregroundStyle(Palette.text)
            ForEach(detail.candidatesByStrength, id: \.candidate) { entry in
                Divider().overlay(Palette.panelBorder)
                HStack(spacing: 12) {
                    Text(entry.candidate).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    Text(entry.parties.map { "\($0.party) \($0.total)" }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                    Text("\(entry.total)").font(Typography.label(18)).monospacedDigit().foregroundStyle(Palette.text)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    // MARK: - Your three

    private func yourThree(_ detail: VoteDetail) -> some View {
        let note = detail.otherChamberNote(delegation: model.delegation)
        return VStack(alignment: .leading, spacing: 10) {
            Text("YOUR THREE").font(Typography.label(20)).foregroundStyle(Palette.text)
            ForEach(detail.positions) { position in
                Button { onOpenMember(position.member) } label: { memberRow(position, detail) }
                    .buttonStyle(.plain)
            }
            if detail.positions.isEmpty, note == nil {
                Text("None of your members were on this roll call.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textMuted)
            }
            if let note {
                HStack(spacing: 12) {
                    ZStack {
                        ForEach(Array(note.members.prefix(2).enumerated()), id: \.element.bioguideId) { index, member in
                            MemberPortrait(member).frame(width: 40, height: 40).offset(x: CGFloat(index) * 10)
                        }
                    }
                    .frame(width: 40 + CGFloat(min(note.members.count, 2) - 1) * 10, alignment: .leading)
                    Text(note.text).font(.system(size: 13)).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(0.55)
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    private func memberRow(_ position: MemberPosition, _ detail: VoteDetail) -> some View {
        let seat = position.member.chamber == .house
            ? "House · \(position.member.state)-\(position.member.district.map { $0 == 0 ? "AL" : String($0) } ?? "")"
            : "Senate · \(position.member.state)"
        let sub = [seat, detail.withParty(position)].compactMap(\.self).joined(separator: " · ")
        let label = position.position == .candidate ? (position.choice ?? "BALLOT").uppercased()
            : (position.position == .notVoting ? "DNP" : position.position.shortLabel)
        return HStack(spacing: 12) {
            MemberPortrait(position.member).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(position.member.fullName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 8)
            Text(label)
                .font(Typography.display(24, weight: .blackItalic))
                .foregroundStyle(Palette.position(position.position))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(position.member.fullName), \(sub), \(label.capitalized)")
        .accessibilityHint("Opens their record")
    }

    // MARK: - The bill

    @ViewBuilder
    private func measureLink(_ measure: MeasureSummary) -> some View {
        if measure.kind == .bill {
            Button { onOpenMeasure(measure) } label: { billCard(measure) }
                .buttonStyle(.plain)
        } else {
            // A nomination has no screen of its own yet, so this is information, not a link.
            VStack(alignment: .leading, spacing: 4) {
                Text("THE NOMINATION · \(measure.citation)").font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                Text(measure.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
            }
            .panel()
        }
    }

    private func billCard(_ measure: MeasureSummary) -> some View {
        let levels = model.bill.map(LawLevels.init(bill:))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(levels.map { "THE BILL · LEVEL \($0.reached) OF 6" } ?? "THE BILL · \(measure.citation)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textMuted)
                Text(levels?.sentence ?? measure.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let levels {
                    HStack(spacing: 3) {
                        ForEach(levels.levels) { level in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(level.state == .done ? Palette.yea
                                      : (level.state == .stuck || level.state == .failed) ? Palette.nay : Palette.panelBorder)
                                .frame(height: 5)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Text("›").font(.system(size: 20)).foregroundStyle(Palette.textMuted)
        }
        .panel()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the bill")
    }

    // MARK: - Full roll

    private func fullRoll(_ detail: VoteDetail) -> some View {
        let parties = detail.rollParties
        let selected = parties.first { $0.party == model.rollParty } ?? parties[0]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("FULL ROLL").font(Typography.label(20)).foregroundStyle(Palette.text)
                Spacer()
                Text("\(detail.rollCount) members").font(.system(size: 12)).foregroundStyle(Palette.textMuted)
            }
            HStack(spacing: 6) {
                ForEach(parties) { party in
                    let on = party.party == selected.party
                    Button { model.rollParty = party.party } label: {
                        Text(PartyName.plural(party.party))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Palette.ground : Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(on ? Palette.text : .clear, in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 22), spacing: 2) {
                ForEach(Array(selected.squares.enumerated()), id: \.offset) { _, position in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(squareColor(position))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(PartyName.plural(selected.party)): \(selected.yea) yea, \(selected.nay) nay, "
                    + "\(selected.present) present, \(selected.notVoting) did not vote"
            )
            Text("One square per member, by count: yea · nay · present · did not vote.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
        }
        .panel()
    }

    private func squareColor(_ position: Position) -> Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present: Palette.textMuted
        case .notVoting, .candidate: Palette.raised
        }
    }
}

#Preview("Vote") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        VoteScreenView(
            model: VoteScreenModel(
                voteId: "house-119-2-321",
                memberIds: ["J000294", "S000148", "G000555"],
                api: FloorAPI(baseURL: FloorAPI.localDevelopment)
            )
        )
    }
}
