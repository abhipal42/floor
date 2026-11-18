import DesignSystem
import Models
import SwiftUI

// v0.2.60, News & sentiment option B of the locked mock (https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW):
// the member page's News section (the week's count and tone, the top story, "News ›") and the News
// page it opens — headlines grouped into stories with a tone bar each, the rest below, then polls.
// Every tone is the AI's read of how a headline frames the member, labelled AI READ; office releases
// are shown and never counted. Polls are shown as their pollsters reported them, each opening its
// release. Nothing here predicts anything.

// MARK: - Words

/// Everything the News section and page print, apart from the views so it can be tested.
public enum NewsText {
    /// `25 headlines this week`, `1 headline this week`.
    public static func count(_ news: MemberNews) -> String {
        let n = news.headlines.count
        return "\(n) \(n == 1 ? "headline" : "headlines") this week"
    }

    /// The summary line, read aloud: `25 headlines this week. Read by AI: 2 favorable, 16 neutral, 7 critical.`
    public static func spokenSummary(_ news: MemberNews) -> String {
        guard !news.headlines.isEmpty else { return noHeadlines }
        guard let tone = news.tone else { return count(news) + "." }
        return count(news) + ". Read by AI: \(tone.sentence)."
    }

    /// The filter chips: All, one per story (`<title> · n`), Other · n. Only All when not AI-read or
    /// when the AI found no stories.
    public static func filters(_ news: MemberNews) -> [(id: NewsFilter, label: String)] {
        var out: [(id: NewsFilter, label: String)] = [(.all, "All")]
        guard news.isAIRead, !news.stories.isEmpty else { return out }
        for story in news.stories {
            out.append((.story(story.id), "\(chipTitle(story.title)) · \(news.headlines(in: story).count)"))
        }
        let other = news.otherHeadlines.count
        if other > 0 { out.append((.other, "Other · \(other)")) }
        return out
    }

    /// A story's title shortened for its chip, as Android does: the first three words, then `…`
    /// (`Van Hollen challenges…`). A title of three words or fewer is whole.
    public static func chipTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        guard words.count > 3 else { return title }
        return words.prefix(3).joined(separator: " ") + "…"
    }

    /// `STORY · 20 HEADLINES`.
    public static func storyEyebrow(_ count: Int) -> String { "STORY · \(count) HEADLINES" }

    /// `17 more ›`.
    public static func more(_ count: Int) -> String { "\(count) more ›" }

    public static let noHeadlines = "No headlines this week."

    /// `No published poll has named Kirsten Gillibrand in the last 90 days.`
    public static func noPolls(_ name: String) -> String {
        "No published poll has named \(name) in the last 90 days."
    }

    /// `Each poll opens its release. Only polls that name Chuck Schumer are shown.`
    public static func pollFootnote(_ name: String) -> String {
        "Each poll opens its release. Only polls that name \(name) are shown."
    }

    /// The headlines section's title: "Other headlines" under stories, "Headlines" on a plain list.
    public static func listTitle(_ news: MemberNews) -> String {
        news.isAIRead && !news.stories.isEmpty ? "Other headlines" : "Headlines"
    }
}

/// What the News page's chips filter to.
public enum NewsFilter: Hashable, Sendable {
    case all
    case story(String)
    case other
}

// MARK: - The member page's section

/// "25 headlines this week · AI READ 2 favorable, 16 neutral, 7 critical", the top story as one
/// glass row with its tone bar, then "News ›".
struct NewsSection: View {
    let news: MemberNews
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NewsSummaryLine(news: news)
            if news.isAIRead, let top = news.stories.first {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NewsText.storyEyebrow(news.headlines(in: top).count))
                            .scaledFont(Typography.News.eyebrow, weight: .heavy)
                            .tracking(1)
                            .foregroundStyle(Palette.threshold)
                        Text(top.title)
                            .scaledFont(Typography.Member.rowTitle, weight: .bold)
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        ToneBar(top.tone, height: 10)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Top story, \(news.headlines(in: top).count) headlines: \(top.title). \(ToneBar.spoken(top.tone))")
                .accessibilityHint("Opens the news")
            }
            Button(action: onOpen) {
                Text("News ›")
                    .scaledFont(Typography.Member.link, weight: .bold)
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All the news")
        }
    }
}

/// `25 headlines this week · AI READ 2 favorable, 16 neutral, 7 critical`; the chip and counts only
/// when the AI has read them.
struct NewsSummaryLine: View {
    let news: MemberNews
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if news.headlines.isEmpty {
                Text(NewsText.noHeadlines)
            } else if let tone = news.tone {
                if typeSize.isAccessibilitySize {
                    // Each part on its own line, wrapping, so nothing is cut at the largest sizes.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NewsText.count(news)).fixedSize(horizontal: false, vertical: true)
                        AIReadChip()
                        Text(tone.sentence).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    FlowLayout(spacing: 5) {
                        Text(NewsText.count(news) + " ·")
                        AIReadChip()
                        Text(tone.sentence)
                    }
                }
            } else {
                Text(NewsText.count(news))
            }
        }
        .scaledFont(Typography.News.summary)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NewsText.spokenSummary(news))
    }
}

// MARK: - The News page

/// The pushed page: the member's name small at the top, NEWS, the summary, the chips, the story
/// cards, the other headlines and the polls.
public struct NewsPage: View {
    let model: NewsModel
    let member: Member?

    public init(model: NewsModel, member: Member?) {
        self.model = model
        self.member = member
    }

    public var body: some View {
        ScrollView {
            NewsContent(model: model, member: member, title: true)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
        }
        .background(Palette.ground)
        .navigationTitle(member.map { "\($0.lastName) · News" } ?? "News")
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The page's own title is NEWS; the bar names whose, small, as the mock draws it.
                Text((member?.fullName ?? "").uppercased())
                    .scaledFont(Typography.News.name, weight: .bold)
                    .tracking(1)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.ground, for: .navigationBar)
        #endif
        .opensLinksInSafariView()
        .task { if model.needsRefresh { await model.load() } }
    }
}

/// The page's content, also what Members › News shows inside ``MemberSectionPage``.
struct NewsContent: View {
    let model: NewsModel
    let member: Member?
    var title = false
    @State private var filter: NewsFilter = .all
    @State private var expanded: Set<String> = []
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    private var readerCalendar: Calendar {
        var c = calendar
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title {
                Text("NEWS")
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
            }
            switch model.phase {
            case .loading:
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
            case let .failed(message):
                BlockLine(text: message) { Task { await model.load() } }
            case let .loaded(news):
                if let saved = model.saved { SavedDataNote(saved) }
                loaded(news)
            }
        }
    }

    private var name: String { member?.fullName ?? "this member" }

    @ViewBuilder
    private func loaded(_ news: MemberNews) -> some View {
        NewsSummaryLine(news: news)
        let filters = NewsText.filters(news)
        if filters.count > 1 {
            FilterChips(filters, selection: $filter)
        }
        let shown = filters.contains { $0.id == filter } ? filter : .all
        if news.isAIRead {
            ForEach(news.stories) { story in
                if shown == .all || shown == .story(story.id) {
                    NewsStoryCard(story: story, headlines: news.headlines(in: story), calendar: readerCalendar,
                                  expanded: shown == .story(story.id) || expanded.contains(story.id)) {
                        expanded.insert(story.id)
                    }
                }
            }
        }
        let others = news.isAIRead ? news.otherHeadlines : news.headlines
        if !others.isEmpty, shown == .all || shown == .other {
            sectionTitle(NewsText.listTitle(news))
            VStack(spacing: 0) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, headline in
                    HeadlineRow(headline, calendar: readerCalendar, rule: index > 0)
                }
            }
        }
        if news.headlines.isEmpty {
            BlockLine(text: NewsText.noHeadlines)
        }
        sectionTitle("Polls")
        if news.polls.isEmpty {
            DashedNote(NewsText.noPolls(name))
        } else {
            ForEach(news.polls) { PollCard(poll: $0) }
            Text(NewsText.pollFootnote(name))
                .scaledFont(Typography.News.footnote)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.blockTitle)
            .foregroundStyle(Palette.text)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 10)
    }
}

/// A story (`.glass.hero`): the gold eyebrow, the AI's title, the tone bar, the three newest
/// headlines, then "N more ›", which opens the rest in place.
struct NewsStoryCard: View {
    let story: NewsStory
    let headlines: [Headline]
    let calendar: Calendar
    let expanded: Bool
    let onExpand: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let shown = 3

    var body: some View {
        let rows = expanded ? headlines : Array(headlines.prefix(Self.shown))
        let hidden = headlines.count - rows.count
        VStack(alignment: .leading, spacing: 0) {
            Text(NewsText.storyEyebrow(headlines.count))
                .scaledFont(Typography.News.eyebrow, weight: .heavy)
                .tracking(1)
                .foregroundStyle(Palette.threshold)
            Text(story.title.uppercased())
                .font(Typography.News.storyTitle)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ToneBar(story.tone)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ForEach(rows) { HeadlineRow($0, calendar: calendar) }
            if hidden > 0 {
                Button {
                    if reduceMotion { onExpand() } else { withAnimation(.easeOut(duration: 0.25)) { onExpand() } }
                } label: {
                    Text(NewsText.more(hidden))
                        .scaledFont(Typography.News.more, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("\(hidden) more headlines in this story")
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard(cornerRadius: 22, fill: Palette.panel)
        .accessibilityElement(children: .contain)
    }
}

/// One poll (`.glass`): "<Pollster> · <dates> · <population>", the bar positive / other / negative,
/// the labels with their percentages; opens the release.
struct PollCard: View {
    let poll: Poll
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { if let url = poll.link { openURL(url) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(poll.heading)
                    .scaledFont(Typography.News.pollHeading, weight: .bold)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                bar.padding(.top, 8).padding(.bottom, 6)
                labels
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(poll.spoken)
        .accessibilityHint("Opens the poll's release")
        .accessibilityAddTraits(.isLink)
    }

    private var bar: some View {
        let parts: [(Double, Color)] = [
            (poll.positive.pct, Palette.toneFavorable),
            (poll.other?.pct ?? poll.unlabelled, Palette.toneNeutral),
            (poll.negative.pct, Palette.toneCritical),
        ]
        let total = parts.reduce(0) { $0 + $1.0 }
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    part.1.frame(width: total > 0 ? geo.size.width * part.0 / total : 0)
                }
            }
        }
        .frame(height: 12)
        .background(Palette.track)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var labels: some View {
        let positive = Text(poll.positive.line).foregroundStyle(Palette.yea)
        let other = poll.other.map { Text($0.line).foregroundStyle(Palette.textMuted) }
        let negative = Text(poll.negative.line).foregroundStyle(Palette.nay)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    positive
                    if let other { other }
                    negative
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    positive
                    Spacer(minLength: 0)
                    if let other { other.multilineTextAlignment(.center) }
                    Spacer(minLength: 0)
                    negative.multilineTextAlignment(.trailing)
                }
            }
        }
        .scaledFont(Typography.News.pollLabel, weight: .semibold)
        .fixedSize(horizontal: false, vertical: true)
    }
}
