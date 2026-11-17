import BillScreen
import DesignSystem
import Models
import SwiftUI

/// One measure's story on the Finals feed (the locked option B, styled "Arena"): a band in its
/// topic's colour with the title and the verdict, then what it does in CRS's words, every vote it
/// took, the party split of the one that decided it, and how your members voted.
///
/// The band and the summary open the bill; each step opens its vote. A nomination has no screen of
/// its own yet, so its band opens the vote that decided it.
struct StoryCard: View {
    let story: Story
    let members: [StoryMember]
    let calendar: Calendar
    let onOpen: (HomeModel.Route) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let radius: CGFloat = 22

    private var openMeasure: HomeModel.Route {
        if let measure = story.measure, measure.kind == .bill { return .bill(id: measure.id) }
        return .vote(id: story.main.vote.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onOpen(openMeasure) } label: { band }
                .buttonStyle(.plain)
                .accessibilityLabel(Stories.spoken(story, members: members))
                .accessibilityHint(story.measure?.kind == .bill ? "Opens the bill" : "Opens the vote")
            VStack(alignment: .leading, spacing: 11) {
                if let lead = story.measure?.summaryLead {
                    Button { onOpen(openMeasure) } label: { what(lead) }
                        .buttonStyle(.plain)
                }
                steps
                PartySplitBar(totals: story.main.partyTotals)
                if !members.isEmpty { yours }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 14)
        }
        .background(Palette.card)
        .clipShape(.rect(cornerRadius: Self.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(
                    LinearGradient(stops: [.init(color: Palette.storyEdge, location: 0.18),
                                           .init(color: Palette.storyEdgeFaint, location: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .top) {
            // Arena's inset top highlight: a 1pt light inside the card's top edge.
            Rectangle().fill(Palette.storyInnerHighlight).frame(height: 1).padding(.horizontal, Self.radius).padding(.top, 1)
                .accessibilityHidden(true)
        }
        .shadow(color: Palette.storyShadow, radius: 20, y: 14)
        .accessibilityElement(children: .contain)
    }

    // MARK: Band

    private var band: some View {
        let verdict = story.main.vote.verdict
        // At the largest sizes the chip sits above the topic line rather than over the title.
        let stacked = dynamicTypeSize.isAccessibilitySize
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                if stacked, let verdict { verdictChip(verdict).padding(.bottom, 8) }
                HStack(spacing: 6) {
                    TopicIcon(story.group).fill(Palette.bandText).frame(width: 14, height: 14)
                    Text(Stories.topicLine(story).uppercased())
                        .scaledFont(Typography.Story.topic, weight: .heavy)
                        .tracking(1.2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(0.9)
                .padding(.trailing, stacked || verdict == nil ? 0 : 96)
                Text(story.title.uppercased())
                    .font(Typography.storyTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .padding(.trailing, stacked || verdict == nil ? 0 : 70)
                if let measure = story.measure {
                    Text(Stories.citationLine(measure))
                        .scaledFont(Typography.Story.citation)
                        .opacity(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if !stacked, let verdict { verdictChip(verdict).padding(13) }
        }
        .foregroundStyle(Palette.bandText)
        .background {
            ZStack {
                Palette.topic(story.group)
                RadialGradient(colors: [Palette.bandHighlight, .clear], center: .topTrailing, startRadius: 0, endRadius: 240)
                LinearGradient(colors: [.clear, Palette.bandShade], startPoint: .top, endPoint: .bottom)
            }
        }
        .contentShape(.rect)
    }

    private func verdictChip(_ text: String) -> some View {
        Text(text)
            .font(Typography.verdict)
            .tracking(1)
            .foregroundStyle(Palette.verdictInk)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .background(Palette.verdict, in: .rect(cornerRadius: 7))
    }

    // MARK: Body

    /// CRS's own sentence, so it carries the CRS label and no AI label (product rule: AI is
    /// labelled; this is not AI).
    private func what(_ lead: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WHAT IT DOES · CRS SUMMARY")
                .scaledFont(Typography.Story.whatLabel, weight: .heavy)
                .tracking(1.1)
                .foregroundStyle(Palette.textMuted)
            Text(lead)
                .scaledFont(Typography.Story.what)
                .lineSpacing(3)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the bill")
    }

    private var steps: some View {
        let main = story.main.id
        return VStack(spacing: 0) {
            ForEach(Array(story.steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Rectangle().fill(Palette.cardBorder).frame(height: 1) }
                Button { onOpen(.vote(id: step.vote.id)) } label: { stepRow(step, main: step.id == main) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Stories.stepLabel(step, calendar: calendar)), \(step.vote.totals.yea) to \(step.vote.totals.nay)")
                    .accessibilityHint("Opens the vote")
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: FeedItem, main: Bool) -> some View {
        let name = Text(Stories.stepLabel(step, calendar: calendar))
            .scaledFont(Typography.Story.step, weight: main ? .bold : .regular)
            .foregroundStyle(main ? Palette.text : Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        let score = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(step.vote.totals.yea)").foregroundStyle(Palette.yea)
            Text("–").foregroundStyle(Palette.textMuted)
            Text("\(step.vote.totals.nay)").foregroundStyle(Palette.nay)
        }
        .font(main ? Typography.mainScore : Typography.stepScore)
        .monospacedDigit()
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 9) {
                    dot(main).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) { name; score }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 9) {
                    dot(main)
                    name
                    Spacer(minLength: 8)
                    score
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
    }

    private func dot(_ main: Bool) -> some View {
        Circle()
            .fill(main ? Palette.yea : Palette.raised)
            .frame(width: 9, height: 9)
            .background { if main { Circle().fill(Palette.yea.opacity(0.22)).frame(width: 17, height: 17) } }
            .frame(width: 14)
    }

    private var yours: some View {
        FlowLayout(spacing: 6) {
            ForEach(members) { m in
                HStack(spacing: 7) {
                    MemberPortrait(m.member).frame(width: 24, height: 24)
                    (Text(m.member.lastName + " ")
                        + Text(Self.word(m.position)).fontWeight(.heavy).foregroundColor(Self.color(m.position))
                        + Text(m.everyStep.map { " " + $0 } ?? ""))
                        .scaledFont(Typography.Story.member, weight: .semibold)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
                // A radius under half the chip's height: a larger one draws stray ticks (lesson 68).
                .background(Palette.cardSunken, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardBorder, lineWidth: 1))
            }
        }
        // Read in the band's sentence.
        .accessibilityHidden(true)
    }

    static func word(_ position: Models.Position) -> String {
        switch position {
        case .yea: "YEA"
        case .nay: "NAY"
        case .present: "PRESENT"
        case .notVoting: "DIDN'T VOTE"
        case .candidate: "VOTED"
        }
    }

    static func color(_ position: Models.Position) -> Color {
        switch position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        default: Palette.textMuted
        }
    }
}

/// The deciding vote's party split: yea segments in full party colour, then nay segments at 30% of
/// it over the track, each as wide as its count. Drawn only when the feed has the split.
struct PartySplitBar: View {
    let totals: [PartyTotals]

    private struct Segment: Identifiable {
        let id: String
        let party: String
        let count: Int
        let yea: Bool
    }

    private var segments: [Segment] {
        let yeas = totals.filter { $0.yea > 0 }.sorted { $0.yea > $1.yea }
            .map { Segment(id: "y\($0.party)", party: $0.party, count: $0.yea, yea: true) }
        let nays = totals.filter { $0.nay > 0 }.sorted { $0.nay > $1.nay }
            .map { Segment(id: "n\($0.party)", party: $0.party, count: $0.nay, yea: false) }
        return yeas + nays
    }

    var body: some View {
        let segments = segments
        let total = segments.reduce(0) { $0 + $1.count }
        if total > 0 {
            GeometryReader { geo in
                let gaps = CGFloat(segments.count - 1) * 3
                HStack(spacing: 3) {
                    ForEach(segments) { s in
                        ZStack {
                            if !s.yea { Palette.track }
                            Palette.party(s.party).opacity(s.yea ? 1 : 0.3)
                        }
                        .frame(width: max(0, (geo.size.width - gaps) * CGFloat(s.count) / CGFloat(total)))
                        .clipShape(.rect(cornerRadius: 4))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
    }
}

/// An "Also this week" row: a measure that only moved along, or a vote that names no measure. A
/// topic-colour bar, the title, a muted line, and the score; it opens the vote.
struct MiniStoryRow: View {
    let story: Story
    let calendar: Calendar

    var body: some View {
        let vote = story.latest.vote
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.topic(story.group)).frame(width: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title)
                    .scaledFont(Typography.Story.miniTitle, weight: .bold)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Stories.miniLine(story, calendar: calendar))
                    .scaledFont(Typography.Story.miniLine)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(vote.totals.yea)").foregroundStyle(Palette.yea)
                Text("–").foregroundStyle(Palette.textMuted)
                Text("\(vote.totals.nay)").foregroundStyle(Palette.nay)
            }
            .font(Typography.miniScore)
            .monospacedDigit()
            .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Palette.card, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.cardBorder, lineWidth: 1))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(story.title). \(Stories.miniLine(story, calendar: calendar)). \(vote.totals.yea) to \(vote.totals.nay).")
        .accessibilityHint("Opens the vote")
    }
}
