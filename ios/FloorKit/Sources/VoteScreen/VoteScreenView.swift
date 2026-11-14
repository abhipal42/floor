import APIClient
import BillScreen
import DesignSystem
import Models
import SwiftUI

/// One vote, as the locked Vote mock draws it: a broadcast scoreboard, the threshold bar, the box
/// score by party, your members, the bill's level of six, and the full roll as squares by party.
///
/// The mock's full roll says "tap a square to see who". The API reports a vote's party counts and
/// your own members' positions, not every member's, so the squares here are counts and carry no
/// names; the caption says what they are instead.
///
/// Dynamic Type: every line of text grows with the reader's setting (`scaledFont`). Rows the mock
/// draws side by side stack when there is no room for them (`ViewThatFits`, or a column layout at
/// accessibility sizes for your members' rows); the big scores stay fixed and shrink to fit, as
/// on the cards.
public struct VoteScreenView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The zone the vote's time is printed in: the device's, unless the environment sets one (the
    /// snapshot tests pin Eastern so a runner in UTC draws the same picture). `.formatted()` alone
    /// reads `TimeZone.current` and ignores the environment, which is what turned CI red (lesson 69).
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @State private var model: VoteScreenModel
    @State private var showingKinds = false
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
        .task { if model.needsRefresh { await model.load() } }
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
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Palette.accent)
            }
            .padding(24)
        case let .loaded(detail):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let saved = model.saved { SavedDataNote(saved) }
                    // No explainer is no card: an unknown kind of vote gets no line, never a guess.
                    if let explainer = detail.vote.explainer { explainerCard(explainer) }
                    if detail.vote.kind == .election {
                        electionBoard(detail)
                        candidateTable(detail)
                    } else {
                        broadcast(detail)
                        if let line = detail.vote.line { thresholdBar(line, detail.vote.totals) }
                        boxScore(detail)
                    }
                    // With no district and nobody followed there is nobody to list.
                    if !model.delegation.isEmpty { yourMembers(detail) }
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
                        .font(.system(size: 12)) // Fixed: a navigation bar does not grow, and this is fixedSize.
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize()
                }
            }
        }
    }

    /// "What this vote is" (round 11, section B): one hand-written line on what the vote does and
    /// doesn't do, with the rule it rests on. Written by Floor from House and Senate rules, not AI.
    /// Folds to its header; "?" opens every kind of vote.
    private func explainerCard(_ explainer: VoteExplainer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button { withAnimation(.snappy) { model.explainerOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("WHAT THIS VOTE IS")
                            .font(Typography.label(11))
                            .tracking(1.1)
                            .foregroundStyle(Palette.threshold)
                        Image(systemName: model.explainerOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.threshold)
                    }
                    .frame(minHeight: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What this vote is")
                .accessibilityValue(model.explainerOpen ? "Expanded" : "Collapsed")
                .accessibilityHint(model.explainerOpen ? "Folds the explanation" : "Shows the explanation")
                Spacer()
                Button { showingKinds = true } label: {
                    Text("?")
                        .font(Typography.label(15))
                        .foregroundStyle(Palette.threshold)
                        .frame(minWidth: 30, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kinds of vote")
                .accessibilityHint("Lists every kind of vote and what each one does")
            }
            if model.explainerOpen {
                Text(explainer.text)
                    .scaledFont(12.5)
                    .foregroundStyle(Palette.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(explainer.source)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityLabel("Source: \(explainer.source)")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.raised, lineWidth: 1))
        .sheet(isPresented: $showingKinds) {
            NavigationStack {
                VoteKindsView(load: { await model.voteKinds() })
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func rollLabel(_ vote: Vote) -> String {
        [vote.chamber.name.uppercased(), vote.rollNumber.map { "ROLL \($0)" }].compactMap(\.self).joined(separator: " · ")
    }

    /// "Sep 30 at 11:58 AM": when a vote happened, in `timeZone` (the environment's, so the device's
    /// in the app and Eastern in the snapshot tests), never `TimeZone.current` behind its back.
    static func whenLabel(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private func when(_ vote: Vote) -> String? {
        vote.occurredAtDate.map { Self.whenLabel($0, timeZone: timeZone, locale: locale) }
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
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text([vote.questionKind, when(vote)].compactMap(\.self).joined(separator: " · "))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text("NEEDED \(vote.votesNeeded)")
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.threshold)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text([vote.questionKind, when(vote)].compactMap(\.self).joined(separator: " · "))
                            .foregroundStyle(Palette.textSecondary)
                        Text("NEEDED \(vote.votesNeeded)")
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.threshold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scaledFont(11)
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

                outcomeStrip {
                    Text(vote.outcomeWord ?? "FINAL")
                        .font(Typography.label(15))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                               maxHeight: .infinity, alignment: .leading)
                        .background(Palette.outcome(vote.outcome))
                    Text(detail.title)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Palette.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.ground.opacity(0.92))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        // Your members are read in their own section below, so not here as well.
        .accessibilityLabel(
            Spoken.scoreboard(
                vote: vote, title: detail.measure?.title ?? vote.question,
                citation: detail.measure?.citation, positions: [], day: when(vote)
            )
        )
    }

    /// The result word beside the title, as the mock draws it — or above it at accessibility
    /// sizes, where a word column beside the title leaves the title a few letters a line.
    private func outcomeStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout(content)
    }

    private func bigSide(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(label).font(Typography.label(14)).tracking(1.7).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.5)
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
            ViewThatFits(in: .horizontal) {
                HStack {
                    lineCaption(line)
                    Spacer()
                    if totals.notVoting > 0 { Text("\(totals.notVoting) did not vote") }
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    lineCaption(line)
                    if totals.notVoting > 0 { Text("\(totals.notVoting) did not vote") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaledFont(12)
            .foregroundStyle(Palette.textMuted)
        }
    }

    @ViewBuilder
    private func lineCaption(_ line: ThresholdLine) -> some View {
        if let over = line.over {
            Text(over == 1 ? "1 vote over the line" : "\(over) votes over the line")
        } else if let short = line.short {
            Text("\(short) short").foregroundStyle(Palette.nay)
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
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Palette.textMuted)
                .padding(.vertical, 6)
                ForEach(detail.boxScore) { row in
                    Divider().overlay(Palette.panelBorder)
                    // At accessibility sizes "Republicans" and four numbers cannot share a row, so
                    // the team's name takes a row of its own above its numbers.
                    if dynamicTypeSize.isAccessibilitySize {
                        GridRow {
                            Text(PartyName.plural(row.party)).fontWeight(.semibold).foregroundStyle(Palette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridCellColumns(present ? 5 : 4)
                        }
                        .scaledFont(14)
                        .padding(.top, 9)
                        .accessibilityHidden(true)
                    }
                    GridRow {
                        Text(dynamicTypeSize.isAccessibilitySize ? "" : PartyName.plural(row.party))
                            .fontWeight(.semibold).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(row.yea)").fontWeight(.bold).foregroundStyle(Palette.yea)
                        Text("\(row.nay)").fontWeight(.bold).foregroundStyle(Palette.nay)
                        if present { Text("\(row.present)").foregroundStyle(Palette.textMuted) }
                        Text("\(row.notVoting)").foregroundStyle(Palette.textMuted)
                    }
                    .scaledFont(14)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(PartyName.plural(row.party)): \(row.yea) yea, \(row.nay) nay, "
                        + (present ? "\(row.present) present, " : "") + "\(row.notVoting) did not vote")
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
                .accessibilityLabel("Total: \(totals.yea) yea, \(totals.nay) nay, "
                    + (present ? "\(totals.present) present, " : "") + "\(totals.notVoting) did not vote")
            }
            .monospacedDigit()
            // Five columns cannot grow without limit on a phone: past what fits, each cell shrinks
            // rather than wrapping a number or clipping a party name.
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            if let sentence = detail.crossoverSentence {
                Text(sentence)
                    .scaledFont(12)
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
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text([detail.vote.question, when(detail.vote)].compactMap(\.self).joined(separator: " · "))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text("MAJORITY OF NAMES CAST").fontWeight(.semibold).foregroundStyle(Palette.threshold)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text([detail.vote.question, when(detail.vote)].compactMap(\.self).joined(separator: " · "))
                            .foregroundStyle(Palette.textSecondary)
                        Text("MAJORITY OF NAMES CAST").fontWeight(.semibold).foregroundStyle(Palette.threshold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scaledFont(11)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(Array(leaders.enumerated()), id: \.element.candidate) { index, entry in
                        VStack(spacing: 0) {
                            Text(entry.candidate.uppercased()).font(Typography.label(14)).tracking(1.2)
                                .foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.5)
                            Text("\(entry.total)")
                                .font(Typography.display(80, weight: .blackItalic, scales: false))
                                .foregroundStyle(index == 0 ? Palette.text : Palette.trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }
                }
                .padding(.vertical, 14)
                outcomeStrip {
                    Text(elected == nil ? "NO WINNER" : "ELECTED")
                        .font(Typography.label(15))
                        .foregroundStyle(elected == nil ? Palette.text : Palette.ground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                               maxHeight: .infinity, alignment: .leading)
                        .background(elected == nil ? Palette.raised : Palette.yea)
                    // Leading a ballot is not winning it: 17 of the 20 Speaker ballots since 2023
                    // elected nobody (lesson 16).
                    Text(elected.map { "\($0.name) elected Speaker" } ?? "No candidate reached a majority; the House balloted again.")
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Palette.text)
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
            Spoken.scoreboard(vote: detail.vote, title: detail.vote.question, citation: nil, positions: [], day: when(detail.vote))
        )
    }

    private func candidateTable(_ detail: VoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BALLOT").font(Typography.label(20)).foregroundStyle(Palette.text)
            ForEach(detail.candidatesByStrength, id: \.candidate) { entry in
                Divider().overlay(Palette.panelBorder)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(entry.candidate).scaledFont(14, weight: .semibold).foregroundStyle(Palette.text)
                        Spacer(minLength: 8)
                        Text(entry.parties.map { "\($0.party) \($0.total)" }.joined(separator: " · "))
                            .scaledFont(12)
                            .foregroundStyle(Palette.textMuted)
                        Text("\(entry.total)").font(Typography.label(18)).monospacedDigit().foregroundStyle(Palette.text)
                    }
                    .lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.candidate).scaledFont(14, weight: .semibold).foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Text("\(entry.total)").font(Typography.label(18)).monospacedDigit().foregroundStyle(Palette.text)
                        }
                        Text(entry.parties.map { "\($0.party) \($0.total)" }.joined(separator: " · "))
                            .scaledFont(12)
                            .foregroundStyle(Palette.textMuted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    // MARK: - Your members

    private func yourMembers(_ detail: VoteDetail) -> some View {
        let note = detail.otherChamberNote(delegation: model.delegation)
        return VStack(alignment: .leading, spacing: 10) {
            Text("YOUR MEMBERS").font(Typography.label(20)).foregroundStyle(Palette.text)
            ForEach(detail.positions) { position in
                Button { onOpenMember(position.member) } label: { memberRow(position, detail) }
                    .buttonStyle(.plain)
            }
            if detail.positions.isEmpty, note == nil {
                Text("None of your members were on this roll call.")
                    .scaledFont(13)
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
                    Text(note.text).scaledFont(13).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(0.55)
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    private func memberRow(_ position: MemberPosition, _ detail: VoteDetail) -> some View {
        let seat = position.member.seatCaption
        let sub = [seat, detail.withParty(position)].compactMap(\.self).joined(separator: " · ")
        let label = position.position == .candidate ? (position.choice ?? "BALLOT").uppercased()
            : (position.position == .notVoting ? "DNP" : position.position.shortLabel)
        // At accessibility sizes the name, seat and position each get the full width, one under the
        // other, rather than squeezing beside a portrait.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            MemberPortrait(position.member).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(position.member.fullName).scaledFont(15, weight: .semibold).foregroundStyle(Palette.text)
                Text(sub).scaledFont(12).foregroundStyle(Palette.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(label)
                .font(Typography.display(24, weight: .blackItalic))
                .foregroundStyle(Palette.position(position.position))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.memberPosition(position, partyNote: detail.withParty(position)))
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
                Text("THE NOMINATION · \(measure.citation)").scaledFont(11).foregroundStyle(Palette.textMuted)
                Text(measure.title).scaledFont(15, weight: .semibold).foregroundStyle(Palette.text)
            }
            .panel()
        }
    }

    private func billCard(_ measure: MeasureSummary) -> some View {
        let levels = model.bill.map(LawLevels.init(bill:))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(levels.map { "THE BILL · LEVEL \($0.reached) OF 6" } ?? "THE BILL · \(measure.citation)")
                    .scaledFont(11)
                    .foregroundStyle(Palette.textMuted)
                Text(levels?.sentence ?? measure.title)
                    .scaledFont(15, weight: .semibold)
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
            Text("›").scaledFont(20).foregroundStyle(Palette.textMuted)
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("FULL ROLL").font(Typography.label(20)).foregroundStyle(Palette.text)
                    Spacer()
                    Text("\(detail.rollCount) members").scaledFont(12).foregroundStyle(Palette.textMuted)
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FULL ROLL").font(Typography.label(20)).foregroundStyle(Palette.text)
                    Text("\(detail.rollCount) members").scaledFont(12).foregroundStyle(Palette.textMuted)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { partyButtons(parties, selected: selected) }
                VStack(alignment: .leading, spacing: 4) { partyButtons(parties, selected: selected) }
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
                .scaledFont(12)
                .foregroundStyle(Palette.textMuted)
        }
        .panel()
    }

    private func partyButtons(_ parties: [PartyTotals], selected: PartyTotals) -> some View {
        ForEach(parties) { party in
            let on = party.party == selected.party
            Button { model.rollParty = party.party } label: {
                Text(PartyName.plural(party.party))
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(on ? Palette.ground : Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(on ? Palette.text : .clear, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected] : [])
        }
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

/// "Kinds of vote" (round 11, section B): every kind Floor explains, its line and its rule, in the
/// registry's order. Reached from the "?" on any vote.
public struct VoteKindsView: View {
    let load: () async -> [VoteKindInfo]?
    @State private var kinds: [VoteKindInfo]?
    @State private var failed = false

    public init(load: @escaping () async -> [VoteKindInfo]?) {
        self.load = load
    }

    public init(kinds: [VoteKindInfo]) {
        load = { kinds }
        _kinds = State(initialValue: kinds)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("KINDS OF VOTE")
                    .font(Typography.headline(28))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                if let kinds {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in row(kind) }
                    Text("Written by Floor from House and Senate rules, not by AI. A kind of vote not listed here gets no explanation rather than a guess.")
                        .scaledFont(10.5, weight: .medium)
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } else if failed {
                    Text("Couldn't load the kinds of vote. Check your connection and try again.")
                        .scaledFont(13)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(Palette.ground)
        .task {
            guard kinds == nil else { return }
            kinds = await load()
            failed = kinds == nil
        }
    }

    private func row(_ kind: VoteKindInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(kind).uppercased())
                .font(Typography.display(14, weight: .blackItalic))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(kind.text)
                .scaledFont(10.5)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text([kind.chamber?.name, kind.when.map { "When: \($0)" }, kind.source].compactMap(\.self).joined(separator: " · "))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The question as roll calls print it, less "On": `Suspend the Rules and Pass`, `Cloture Motion`.
    static func title(_ kind: VoteKindInfo) -> String {
        guard let first = kind.questions.first else { return kind.kind.replacingOccurrences(of: "_", with: " ") }
        var title = first
        for prefix in ["On Motion to ", "On the ", "On ", "Motion to "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
            break
        }
        return title
    }
}
