import Foundation

// v0.2.60 (the locked mock https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW, News & sentiment
// option B): a member's headlines this week, grouped into stories by AI, and the polls that name
// them. `GET /v1/members/{id}/news`.
//
// Decoded leniently, field by field, as `Said` is: the route was built in parallel with these
// screens, so a field this build does not know is ignored, a missing one reads as nil or empty, and
// one bad headline, story or poll is dropped rather than failing the whole page.

/// How a headline frames the member, as the AI read it. `office` is not a tone: it marks a headline
/// from the member's own office or another `.gov` site, which is shown but never counted.
public enum NewsTone: String, Codable, Sendable, Hashable, CaseIterable {
    case favorable, neutral, critical, office

    /// What VoiceOver says after a headline: "critical coverage", "from their office".
    public var spoken: String {
        switch self {
        case .favorable: "favorable coverage"
        case .neutral: "neutral coverage"
        case .critical: "critical coverage"
        case .office: "from their office"
        }
    }
}

/// Favorable, neutral and critical counts over some headlines; `office` is carried but never drawn
/// in a bar or counted in a sentence.
public struct ToneCounts: Codable, Sendable, Hashable {
    public var favorable: Int
    public var neutral: Int
    public var critical: Int
    public var office: Int

    public init(favorable: Int, neutral: Int, critical: Int, office: Int = 0) {
        self.favorable = favorable
        self.neutral = neutral
        self.critical = critical
        self.office = office
    }

    private enum CodingKeys: String, CodingKey { case favorable, neutral, critical, office }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int { max(0, ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0) }
        favorable = count(.favorable)
        neutral = count(.neutral)
        critical = count(.critical)
        office = count(.office)
    }

    /// The headlines a bar or a sentence counts: everything but the office's own.
    public var counted: Int { favorable + neutral + critical }

    /// `1 favorable, 7 neutral, 4 critical`.
    public var sentence: String { "\(favorable) favorable, \(neutral) neutral, \(critical) critical" }
}

/// One headline: its title, its publisher and when, and the link. No article text is stored.
public struct Headline: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var source: String
    public var url: String
    /// ISO 8601 instant.
    public var publishedAt: String
    /// nil when it has not been AI-read.
    public var tone: NewsTone?
    public var storyId: String?

    public init(id: String, title: String, source: String, url: String, publishedAt: String,
                tone: NewsTone? = nil, storyId: String? = nil) {
        self.id = id
        self.title = title
        self.source = source
        self.url = url
        self.publishedAt = publishedAt
        self.tone = tone
        self.storyId = storyId
    }

    private enum CodingKeys: String, CodingKey { case id, title, source, url, publishedAt, tone, storyId }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        publishedAt = try c.decode(String.self, forKey: .publishedAt)
        guard URL(string: url) != nil, Formats.instant(publishedAt) != nil, !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "unreadable headline")
        }
        source = ((try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil) ?? ""
        // An unknown tone (a newer server's) reads as not AI-read rather than dropping the headline.
        tone = ((try? c.decodeIfPresent(String.self, forKey: .tone)) ?? nil).flatMap(NewsTone.init(rawValue:))
        storyId = (try? c.decodeIfPresent(String.self, forKey: .storyId)) ?? nil
    }

    public var publishedDate: Date? { Formats.instant(publishedAt) }
    public var link: URL? { URL(string: url) }

    /// The title without Google News's trailing " - Publisher", which the source line already says.
    public var displayTitle: String {
        for suffix in [" - \(source)", " | \(source)"] where !source.isEmpty && title.hasSuffix(suffix) {
            let trimmed = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return title
    }

    /// Newest first; ties keep the order they came in.
    static func newestFirst(_ headlines: [Headline]) -> [Headline] {
        headlines.enumerated().sorted { a, b in
            let (x, y) = (a.element.publishedDate ?? .distantPast, b.element.publishedDate ?? .distantPast)
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }
}

/// An AI group of two or more headlines about the same event, with a neutral title the AI wrote.
public struct NewsStory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var tone: ToneCounts
    public var headlineIds: [String]

    public init(id: String, title: String, tone: ToneCounts, headlineIds: [String]) {
        self.id = id
        self.title = title
        self.tone = tone
        self.headlineIds = headlineIds
    }

    private enum CodingKeys: String, CodingKey { case id, title, tone, headlineIds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        tone = (try? c.decodeIfPresent(ToneCounts.self, forKey: .tone)) ?? ToneCounts(favorable: 0, neutral: 0, critical: 0)
        headlineIds = ((try? c.decodeIfPresent([LossyElement<String>].self, forKey: .headlineIds)) ?? []).compactMap(\.value)
    }
}

/// One share of a poll, labelled as the pollster worded it ("favorable", "should choose a new leader").
public struct PollShare: Codable, Sendable, Hashable {
    public var label: String
    public var pct: Double

    public init(label: String, pct: Double) {
        self.label = label
        self.pct = pct
    }

    /// `22%`, or `22.5%` when the pollster gave a decimal.
    public var percent: String {
        pct.rounded() == pct ? "\(Int(pct))%" : String(format: "%.1f%%", pct)
    }

    /// `22% favorable`.
    public var line: String { "\(percent) \(label)" }
}

/// A published poll that names the member, reviewed by hand before it is served.
public struct Poll: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var pollster: String
    /// `YYYY-MM-DD`.
    public var fieldedFrom: String
    public var fieldedTo: String
    /// Who was asked: "U.S. adults", "registered voters".
    public var population: String
    public var sampleSize: Int?
    public var positive: PollShare
    public var negative: PollShare
    /// The rest, when the pollster reported it ("don't know"); nil leaves it unlabelled.
    public var other: PollShare?
    /// The release.
    public var url: String

    public init(id: String, pollster: String, fieldedFrom: String, fieldedTo: String, population: String,
                sampleSize: Int?, positive: PollShare, negative: PollShare, other: PollShare?, url: String) {
        self.id = id
        self.pollster = pollster
        self.fieldedFrom = fieldedFrom
        self.fieldedTo = fieldedTo
        self.population = population
        self.sampleSize = sampleSize
        self.positive = positive
        self.negative = negative
        self.other = other
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, pollster, fieldedFrom, fieldedTo, population, sampleSize, positive, negative, other, url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pollster = try c.decode(String.self, forKey: .pollster)
        fieldedFrom = try c.decode(String.self, forKey: .fieldedFrom)
        fieldedTo = try c.decode(String.self, forKey: .fieldedTo)
        positive = try c.decode(PollShare.self, forKey: .positive)
        negative = try c.decode(PollShare.self, forKey: .negative)
        url = try c.decode(String.self, forKey: .url)
        // A poll without a readable release, or with shares over 100, is not shown (the worker
        // rejects both too).
        guard URL(string: url) != nil, Formats.day(fieldedFrom) != nil, Formats.day(fieldedTo) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "unreadable poll")
        }
        population = ((try? c.decodeIfPresent(String.self, forKey: .population)) ?? nil) ?? ""
        sampleSize = (try? c.decodeIfPresent(Int.self, forKey: .sampleSize)) ?? nil
        other = (try? c.decodeIfPresent(PollShare.self, forKey: .other)) ?? nil
        let total = positive.pct + negative.pct + (other?.pct ?? 0)
        guard positive.pct >= 0, negative.pct >= 0, (other?.pct ?? 0) >= 0, total <= 100.5 else {
            throw DecodingError.dataCorruptedError(forKey: .positive, in: c, debugDescription: "shares over 100")
        }
    }

    public var link: URL? { URL(string: url) }

    /// The share no label covers (when `other` is nil): 100 minus the two reported, never below 0.
    public var unlabelled: Double {
        other == nil ? max(0, 100 - positive.pct - negative.pct) : 0
    }

    /// `Nov 13–16`, `Oct 30–Nov 2`, `Nov 13`; the dates are calendar days, read in UTC.
    public var dates: String {
        guard let from = Formats.day(fieldedFrom), let to = Formats.day(fieldedTo) else { return fieldedTo }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let month = Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: .gmt).month(.abbreviated)
        let (m1, m2) = (from.formatted(month), to.formatted(month))
        let (d1, d2) = (calendar.component(.day, from: from), calendar.component(.day, from: to))
        if from == to { return "\(m1) \(d1)" }
        return m1 == m2 ? "\(m1) \(d1)–\(d2)" : "\(m1) \(d1)–\(m2) \(d2)"
    }

    /// `Economist/YouGov · Nov 13–16 · U.S. adults`.
    public var heading: String {
        [pollster, dates, population.isEmpty ? nil : population].compactMap(\.self).joined(separator: " · ")
    }

    /// The card read aloud: heading, sample, then each share.
    public var spoken: String {
        var parts = [heading]
        if let sampleSize { parts.append("\(sampleSize.formatted()) asked") }
        parts.append(positive.line)
        if let other { parts.append(other.line) }
        parts.append(negative.line)
        return parts.joined(separator: ". ") + "."
    }
}

/// `GET /v1/members/{id}/news`.
public struct MemberNews: Codable, Sendable, Hashable {
    public struct Window: Codable, Sendable, Hashable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public var memberId: String
    /// ISO; nil when the member's news has never been fetched.
    public var checkedAt: String?
    public var window: Window?
    /// Over every headline in the window; nil when none was AI-read.
    public var tone: ToneCounts?
    /// Biggest first; empty when not AI-read.
    public var stories: [NewsStory]
    /// Newest first, stories' members included.
    public var headlines: [Headline]
    /// Newest first, fielded within the last 90 days.
    public var polls: [Poll]

    public init(memberId: String, checkedAt: String? = nil, window: Window? = nil, tone: ToneCounts? = nil,
                stories: [NewsStory] = [], headlines: [Headline] = [], polls: [Poll] = []) {
        self.memberId = memberId
        self.checkedAt = checkedAt
        self.window = window
        self.tone = tone
        self.stories = stories
        self.headlines = headlines
        self.polls = polls
    }

    private enum CodingKeys: String, CodingKey { case memberId, checkedAt, window, tone, stories, headlines, polls }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = ((try? c.decodeIfPresent(String.self, forKey: .memberId)) ?? nil) ?? ""
        checkedAt = (try? c.decodeIfPresent(String.self, forKey: .checkedAt)) ?? nil
        window = (try? c.decodeIfPresent(Window.self, forKey: .window)) ?? nil
        tone = (try? c.decodeIfPresent(ToneCounts.self, forKey: .tone)) ?? nil
        headlines = Headline.newestFirst(
            ((try? c.decodeIfPresent([LossyElement<Headline>].self, forKey: .headlines)) ?? []).compactMap(\.value)
        )
        // A story keeps only the headlines that are here, and goes once fewer than two are left.
        let known = Set(headlines.map(\.id))
        stories = ((try? c.decodeIfPresent([LossyElement<NewsStory>].self, forKey: .stories)) ?? [])
            .compactMap(\.value)
            .map { story in
                var story = story
                story.headlineIds = story.headlineIds.filter(known.contains)
                return story
            }
            .filter { $0.headlineIds.count >= 2 }
        polls = ((try? c.decodeIfPresent([LossyElement<Poll>].self, forKey: .polls)) ?? []).compactMap(\.value)
            .sorted { $0.fieldedTo > $1.fieldedTo }
    }

    /// An API without the route yet (its 404), or a member never checked.
    public static func none(_ memberId: String) -> MemberNews { MemberNews(memberId: memberId) }

    /// Nothing to show: no headlines and no polls. The member page leaves its chip and section out.
    public var isEmpty: Bool { headlines.isEmpty && polls.isEmpty }

    /// Whether the AI has read this week's headlines: tone counts, story chips and bars are shown.
    public var isAIRead: Bool { tone != nil }

    /// A story's headlines, newest first.
    public func headlines(in story: NewsStory) -> [Headline] {
        let ids = Set(story.headlineIds)
        return headlines.filter { ids.contains($0.id) }
    }

    /// The headlines in no story shown here, newest first.
    public var otherHeadlines: [Headline] {
        let grouped = Set(stories.flatMap(\.headlineIds))
        return headlines.filter { !grouped.contains($0.id) }
    }
}
