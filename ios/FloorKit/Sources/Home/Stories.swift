import Foundation
import Models

/// One measure's finals on the Finals feed: a bill or a nomination with every final vote on it, or
/// a single vote that names no measure.
///
/// Built by ``Stories/group(_:now:calendar:)`` from the feed's one-card-per-vote items, so the
/// feed's loading, scope and chamber filter stay as they were; only how the cards are drawn moved.
public struct Story: Identifiable, Sendable, Hashable {
    /// The measure's id, or `vote:<id>` for a vote with no measure.
    public var id: String
    /// What the story is about: the bill itself even when a special rule's votes joined it. nil for
    /// a vote that names no measure.
    public var measure: MeasureSummary?
    /// Every vote on it, oldest first.
    public var steps: [FeedItem]
    /// A story card: at least one step decided something (``Vote/isProcedural`` is false). Otherwise
    /// an "Also this week" row.
    public var isFull: Bool

    /// The step the card leads with: the latest that decided something, or on a mini row the latest.
    public var main: FeedItem {
        steps.last { !$0.vote.isProcedural } ?? latest
    }

    public var latest: FeedItem { steps[steps.count - 1] }

    public var latestDate: Date? { steps.compactMap(\.vote.occurredAtDate).max() }

    public var group: TopicGroup { TopicGroup.of(measure) }

    /// What the card's band and the mini row call it: the bill's short title, the nominee, or for
    /// a vote with no measure what kind of vote it was.
    public var title: String { measure?.title ?? latest.vote.stepName }
}

/// One week of the feed: its story cards, newest first, then its "Also this week" rows.
public struct StoryWeek: Identifiable, Sendable, Hashable {
    /// The week's first day, as `yyyy-MM-dd` in the reader's zone, or `undated`.
    public var id: String
    /// "This week", "Last week", "Week of Nov 2".
    public var title: String
    /// "Also this week", "Also last week", "Also that week".
    public var alsoTitle: String
    public var stories: [Story]
    public var minis: [Story]
}

/// How a story card speaks about one of your members.
public struct StoryMember: Identifiable, Sendable, Hashable {
    public var member: Member
    /// Their position on the main step, or on their latest step when they did not vote on it.
    public var position: Models.Position
    /// "on all three", "on both": set when they voted the same way on every step of their chamber.
    public var everyStep: String?

    public var id: String { member.bioguideId }
}

public enum Stories {
    /// The feed as stories, grouped by week, newest week first.
    ///
    /// - A vote files under its measure's id. A House special rule whose ``MeasureSummary/forBillId``
    ///   names a bill that is also in `items` files under that bill instead; one whose bill is not
    ///   here is a story of its own. A vote with no measure is its own entry.
    /// - A story is full when any step decided something; otherwise it is a mini row.
    /// - Each story goes in the week of its latest vote, in `calendar`'s zone and first weekday.
    ///   Within a week full stories come first, then minis, each newest first.
    ///
    /// - Parameters:
    ///   - now: when "this week" is; passed in so a test, a snapshot and the reader agree.
    ///   - calendar: the reader's, with their zone and locale set; never read inside (lesson 69).
    public static func group(_ items: [FeedItem], now: Date, calendar: Calendar) -> [StoryWeek] {
        let ids = Set(items.compactMap(\.measure?.id))
        func key(_ item: FeedItem) -> String {
            guard let measure = item.measure else { return "vote:\(item.vote.id)" }
            if let bill = measure.forBillId, bill != measure.id, ids.contains(bill) { return bill }
            return measure.id
        }
        var byKey: [String: [FeedItem]] = [:]
        var order: [String] = []
        for item in items {
            let k = key(item)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(item)
        }
        let stories: [Story] = order.map { k in
            let steps = oldestFirst(byKey[k]!)
            // The bill's own measure, not its rule's; the fullest copy when the rows differ.
            let own = steps.compactMap(\.measure).filter { $0.id == k }
            let measure = own.first { $0.summaryLead != nil || $0.sponsor != nil || $0.position != nil } ?? own.first
            return Story(id: k, measure: measure, steps: steps, isFull: steps.contains { !$0.vote.isProcedural })
        }

        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let lastWeek = thisWeek.flatMap { calendar.date(byAdding: .weekOfYear, value: -1, to: $0) }
        var weeks: [Date?: [Story]] = [:]
        for story in stories {
            let start = story.latestDate.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }
            weeks[start, default: []].append(story)
        }
        let starts = weeks.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (l?, r?): l > r
            case (_?, nil): true
            default: false
            }
        }
        return starts.map { start in
            let week = newestFirst(weeks[start]!)
            let (title, also): (String, String) = switch start {
            case nil: ("Undated", "Also undated")
            case thisWeek: ("This week", "Also this week")
            case lastWeek: ("Last week", "Also last week")
            case let day?: ("Week of \(shortDate(day, calendar: calendar))", "Also that week")
            }
            return StoryWeek(
                id: start.map { dayId($0, calendar: calendar) } ?? "undated",
                title: title, alsoTitle: also,
                stories: week.filter(\.isFull), minis: week.filter { !$0.isFull }
            )
        }
    }

    /// Your members who voted on any of the story's steps, in the order the steps list them, with
    /// their position on the main step. `allowed` narrows them to some members (your three in
    /// "All"); nil keeps everyone the feed carries.
    public static func members(_ story: Story, allowed: Set<String>? = nil) -> [StoryMember] {
        let main = story.main
        var seen: [Member] = []
        for step in [main] + story.steps.reversed() {
            for p in step.positions where !seen.contains(where: { $0.bioguideId == p.member.bioguideId }) {
                if allowed?.contains(p.member.bioguideId) ?? true { seen.append(p.member) }
            }
        }
        return seen.map { member in
            let theirs = story.steps.compactMap { step in step.positions.first { $0.id == member.bioguideId }?.position }
            let position = main.positions.first { $0.id == member.bioguideId }?.position ?? theirs.last ?? .notVoting
            let inChamber = story.steps.filter { $0.vote.chamber == member.chamber }.count
            let same = theirs.count >= 2 && theirs.count == inChamber && Set(theirs).count == 1
            return StoryMember(member: member, position: position, everyStep: same ? onEvery(theirs.count) : nil)
        }
    }

    /// "on both", "on all three", up to "on all ten", then digits.
    static func onEvery(_ count: Int) -> String {
        let words = ["", "", "", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        if count == 2 { return "on both" }
        return "on all \(count < words.count ? words[count] : String(count))"
    }

    // MARK: - Words on the card

    /// The band's topic line: the policy area, or `Nomination · Tenth Circuit`.
    public static func topicLine(_ story: Story) -> String {
        guard let measure = story.measure else { return "Vote" }
        switch measure.kind {
        case .bill: return measure.policyArea ?? "Bill"
        case .nomination: return ["Nomination", measure.position.flatMap(postPlace)].compactMap(\.self).joined(separator: " · ")
        }
    }

    /// The band's citation line: `H.R. 2102 · Sponsor Bilirakis (R-FL)`, `U.S. Circuit Judge · PN999-2`.
    public static func citationLine(_ measure: MeasureSummary) -> String {
        switch measure.kind {
        case .bill:
            return [measure.citation, measure.sponsor.map { "Sponsor \($0.label)" }].compactMap(\.self).joined(separator: " · ")
        case .nomination:
            return [measure.position.map(postTitle), measure.citation].compactMap(\.self).joined(separator: " · ")
        }
    }

    /// A step's name with its short date: `Rule for debate · Nov 12`.
    public static func stepLabel(_ step: FeedItem, calendar: Calendar) -> String {
        [step.vote.stepName, step.vote.occurredAtDate.map { shortDate($0, calendar: calendar) }]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// The mini row's muted line: `Fifth Circuit · Cloture agreed Nov 12`, `H.R. 2347 · Motion to take
    /// it up agreed Nov 11`, or `Measure not named in the record · Nov 16`.
    public static func miniLine(_ story: Story, calendar: Calendar) -> String {
        let vote = story.latest.vote
        let date = vote.occurredAtDate.map { shortDate($0, calendar: calendar) }
        guard let measure = story.measure else {
            return ["Measure not named in the record", date].compactMap(\.self).joined(separator: " · ")
        }
        let place = measure.kind == .nomination ? measure.position.flatMap(postPlace) ?? measure.citation : measure.citation
        let what = [vote.stepName, vote.outcomeWord?.lowercased(), date].compactMap(\.self).joined(separator: " ")
        return "\(place) · \(what)"
    }

    /// The card read as one sentence: title, verdict, the main score, your members' votes.
    public static func spoken(_ story: Story, members: [StoryMember]) -> String {
        let main = story.main.vote
        var parts = [story.title]
        if let verdict = main.verdict { parts.append(verdict.capitalized) }
        parts.append("\(main.stepName), \(main.totals.yea) to \(main.totals.nay)")
        for m in members {
            let how = m.position == .notVoting ? "did not vote" : "voted \(m.position.rawValue)"
            parts.append([m.member.lastName, how, m.everyStep].compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: ". ") + "."
    }

    /// `Tenth Circuit` from `United States Circuit Judge for the Tenth Circuit`; nil when the post
    /// names no place.
    static func postPlace(_ position: String) -> String? {
        guard let range = position.range(of: " for the ") else { return nil }
        return String(position[range.upperBound...])
    }

    /// `U.S. Circuit Judge` from `United States Circuit Judge for the Tenth Circuit`.
    static func postTitle(_ position: String) -> String {
        let title = position.range(of: " for the ").map { String(position[..<$0.lowerBound]) } ?? position
        return title.replacingOccurrences(of: "United States ", with: "U.S. ")
    }

    // MARK: - Dates

    /// The days a week's votes span, for its header: `Nov 11 – 16`, `Oct 30 – Nov 2`, or one day.
    public static func range(_ week: StoryWeek, calendar: Calendar) -> String? {
        let dates = (week.stories + week.minis).flatMap { $0.steps.compactMap(\.vote.occurredAtDate) }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        if calendar.isDate(first, inSameDayAs: last) { return shortDate(first, calendar: calendar) }
        var day = Date.FormatStyle.dateTime.day()
        day.timeZone = calendar.timeZone
        day.locale = calendar.locale ?? Locale(identifier: "en_US")
        day.calendar = calendar
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        return "\(shortDate(first, calendar: calendar)) – \(sameMonth ? last.formatted(day) : shortDate(last, calendar: calendar))"
    }

    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? Locale(identifier: "en_US")
        style.calendar = calendar
        return date.formatted(style)
    }

    private static func dayId(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func oldestFirst(_ items: [FeedItem]) -> [FeedItem] {
        HomeModel.newestFirst(items).reversed()
    }

    private static func newestFirst(_ stories: [Story]) -> [Story] {
        stories.sorted { lhs, rhs in
            switch (lhs.latestDate, rhs.latestDate) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.id > rhs.id
            }
        }
    }
}
