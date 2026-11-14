import APIClient
import DesignSystem
import Models
import Onboarding
import SwiftUI

/// A bill, as the locked Bill mock draws it: the title, its sponsor, six levels to law with the
/// votes that moved it, your own members on it, and what it costs.
///
/// At the top, the AI section (`AIAnalysisSection`, section E of the locked live/AI design): an
/// analysis of the CRS summary, labelled and cited line by line. Below it the CRS summary itself,
/// labelled as such — it is the Congressional Research Service's text, not a model's.
///
/// With a follow list (Round 10, <https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>, section B):
/// Follow bill in the header, the citation moves above the title, and the bill's topic is a link
/// to the topic's page that says whether you follow it.
public struct BillScreenView: View {
    @State private var model: BillScreenModel
    private let follows: Follows?
    private let onOpenTopic: ((String) -> Void)?
    private let onOpenVote: (Vote) -> Void

    /// - Parameters:
    ///   - follows: the follow list; nil shows no Follow button (previews and the screen alone).
    ///   - onOpenTopic: opens a topic's page; nil leaves the topic out.
    public init(
        model: BillScreenModel, follows: Follows? = nil, onOpenTopic: ((String) -> Void)? = nil,
        onOpenVote: @escaping (Vote) -> Void
    ) {
        _model = State(initialValue: model)
        self.follows = follows
        self.onOpenTopic = onOpenTopic
        self.onOpenVote = onOpenVote
    }

    public var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            content
        }
        .task {
            await model.load()
            // A bill you follow: its saved row (the Following tab's Bills) follows the fresh record.
            if let follows, model.saved == nil, case let .loaded(bill) = model.phase {
                follows.refresh(record: bill)
            }
        }
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
                    if let saved = model.saved { SavedDataNote(saved) }
                    if let follows { followRow(bill, follows: follows) }
                    header(bill)
                    AIAnalysisSection(
                        phase: model.analysis,
                        openCitation: model.openCitation,
                        onToggle: { id in withAnimation(.snappy) { model.toggleCitation(id) } },
                        onRetry: { Task { await model.retryAnalysis() } }
                    )
                    levels(bill)
                    // Only one of the 32 topics: anything else has no page to open.
                    if let area = bill.policyArea.flatMap(Topic.canonical), let onOpenTopic {
                        topic(area, open: onOpenTopic)
                    }
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
                    if follows == nil {
                        citationLine(bill)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// The citation and Follow bill, above the title. In the screen rather than the navigation bar,
    /// where iOS 26 draws a toolbar item on its own glass capsule that the pill's colours fight.
    private func followRow(_ bill: Bill, follows: Follows) -> some View {
        HStack(alignment: .center, spacing: 8) {
            citationLine(bill)
                .font(Typography.label(12))
                .tracking(1.2)
                .foregroundStyle(Palette.threshold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            FollowPill(
                on: follows.isFollowing(bill: bill.id), offTitle: "FOLLOW BILL", onTitle: "✓ FOLLOWING",
                name: bill.citation, hint: "Adds its votes to Finals and lists it under Following"
            ) { follows.toggle(bill: BillListItem(bill: bill)) }
        }
    }

    private func citationLine(_ bill: Bill) -> Text {
        Text("\(bill.citation) · \(StateName.ordinal(bill.congress)) CONGRESS".uppercased())
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

    /// The topic card: the bill's CRS policy area as a link to its page, saying whether you follow it.
    private func topic(_ area: String, open: @escaping (String) -> Void) -> some View {
        let following = follows?.isFollowing(topic: area) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Text("TOPIC").font(Typography.label(20)).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Button { open(area) } label: {
                Text(following ? "\(area) ✓ Following" : "\(area) ›")
                    .scaledFont(12, weight: .bold)
                    .foregroundStyle(Palette.threshold)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.threshold, lineWidth: 1))
                    .padding(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(following ? "Topic: \(area), following" : "Topic: \(area)")
            .accessibilityHint("Opens every bill in \(area)")
        }
        .panel()
    }

    private func whatItDoes(_ summary: String, stage: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // With an analysis above, "What it does" is its first heading, so this one names
                // its source instead.
                Text(model.analysis.isShown ? "CRS SUMMARY" : "WHAT IT DOES")
                    .font(Typography.label(20)).foregroundStyle(Palette.text)
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
            Text("YOUR MEMBERS ON THIS BILL").font(Typography.label(20)).foregroundStyle(Palette.text)
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
