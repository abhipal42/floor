import Foundation
import Models
import Onboarding

/// One hero card at the top of the Week tab (v0.2.59, "Headliners"): a Senate bill the Daily
/// Digest's program names, or a House bill coming up under a rule.
public struct Headliner: Identifiable, Sendable, Hashable {
    public enum Chamber: Sendable, Hashable {
        /// `SENATE · IN DEBATE`.
        case senate
        /// `HOUSE · FULL DEBATE`.
        case house
    }

    public var chamber: Chamber
    public var item: ScheduleItem
    /// The title in display caps: the bill's, or for a legislative vehicle what it carries.
    public var headline: String
    /// `Riding on Survivor Justice Tax Prevention Act.`, the program's sentence, or `Up under a rule (H.Res. 1665) …`.
    public var context: String?
    /// Up to two of the bill's latest votes: `Mon ✓ cloture 70–27`.
    public var chips: [String]
    /// You follow it, or its topic: the gold edge.
    public var followed: Bool

    public var group: TopicGroup { TopicGroup.of(policyArea: item.policyArea) }
    public var id: String { "\(chamber)|\(item.billId ?? item.label)" }
}

/// One fast-track tile: a topic family and how many suspension bills of it are listed.
public struct FastTrackTile: Identifiable, Sendable, Hashable {
    public var group: TopicGroup
    public var count: Int
    public var id: String { group.rawValue }
}

/// What the Week tab shows, worked out from the week's schedule (and, for the headliners' chips, the
/// votes already loaded) apart from the view, so it can be tested on the real week.
public enum WeekPlan {
    /// Washington's zone: the schedule's days and times are its.
    static let washington = TimeZone(identifier: "America/New_York")!

    // MARK: Summary

    /// `Both chambers in · 17 measures listed`, from the schedule alone: a chamber is "in" when the
    /// House posted a list with something on it, or the Senate named a meeting that is not pro forma.
    /// nil when the schedule supports neither half.
    public static func summary(_ schedule: Schedule) -> String? {
        let houseIn = schedule.house.inSession == true && schedule.house.items.contains { $0.removedAt == nil }
        let meetings = schedule.senate?.meetings ?? []
        let senateIn = meetings.contains { !$0.proForma }
        let who: String? = switch (houseIn, senateIn) {
        case (true, true): "Both chambers in"
        case (true, false): meetings.isEmpty ? "House in" : "House in · Senate pro forma"
        case (false, true): "Senate in"
        case (false, false): meetings.isEmpty ? nil : "Senate pro forma"
        }
        let listed = listedCount(schedule)
        let count = listed == 0 ? nil : "\(listed) measure\(listed == 1 ? "" : "s") listed"
        let parts = [who, count].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Items still on either chamber's list, each measure once.
    static func listedCount(_ schedule: Schedule) -> Int {
        let items = schedule.house.items + (schedule.senate?.items ?? [])
        return Set(items.filter { $0.removedAt == nil }.map { $0.billId ?? $0.label }).count
    }

    // MARK: Headliners

    /// The Senate's bills the program names, then the House's bills under a rule, in the lists' order.
    public static func headliners(
        _ schedule: Schedule, state: FollowState, votes: [FeedItem], calendar: Calendar
    ) -> [Headliner] {
        let rows = Dictionary(
            WeekSort.groups(schedule.house.items + (schedule.senate?.items ?? []), state: state)
                .flatMap(\.rows).map { ($0.item.billId ?? $0.item.label, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        func followed(_ item: ScheduleItem) -> Bool { rows[item.billId ?? item.label]?.followed != nil }
        let week = weekDays(schedule.week)
        var found: [Headliner] = []

        let programs = (schedule.senate?.meetings ?? []).sorted { $0.date > $1.date }.compactMap(\.program)
        for item in senateNamed(schedule) {
            let vehicle = programs.lazy.compactMap { vehicleName(of: item.label, in: $0) }.first
            let sentence = programs.lazy.compactMap { sentences($0).first { $0.contains(item.label) } }.first
            found.append(Headliner(
                chamber: .senate, item: item,
                headline: vehicle ?? item.title,
                context: vehicle != nil ? "Riding on \(item.title)." : sentence,
                chips: chips(for: item, votes: votes, weekOf: week, calendar: calendar),
                followed: followed(item)
            ))
        }
        let house = schedule.house.items
        for item in house where item.category == .rule && item.removedAt == nil {
            found.append(Headliner(
                chamber: .house, item: item, headline: item.title,
                context: ruleContext(item, in: house),
                chips: chips(for: item, votes: votes, weekOf: week, calendar: calendar),
                followed: followed(item)
            ))
        }
        return found
    }

    /// The Senate's listed items its program names, once each.
    static func senateNamed(_ schedule: Schedule) -> [ScheduleItem] {
        let programs = (schedule.senate?.meetings ?? []).compactMap(\.program)
        var seen = Set<String>()
        return (schedule.senate?.items ?? []).filter { item in
            item.removedAt == nil && programs.contains { $0.contains(item.label) }
                && seen.insert(item.billId ?? item.label).inserted
        }
    }

    /// `X` when the program names the bill followed by the literal `(legislative vehicle for X)`,
    /// a leading "the" dropped: `H.R. 2347, Survivor Justice Tax Prevention Act (legislative vehicle
    /// for the Bipartisan American Affordability and Jobs Act)`.
    public static func vehicleName(of label: String, in program: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: label) + #"(?:,[^()]*?)?\s*\(legislative vehicle for ([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: program, range: NSRange(program.startIndex..., in: program)),
              let range = Range(match.range(at: 1), in: program) else { return nil }
        var name = program[range].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        return name.isEmpty ? nil : name
    }

    /// `Up under a rule (H.Res. 1665) with Direct Seller and Real Estate Agent Harmonization Act.`:
    /// the listed H.Res. whose title names the bill, and the other listed bills that same rule
    /// brings up. `Up under a rule.` when no listed H.Res. names it.
    public static func ruleContext(_ item: ScheduleItem, in items: [ScheduleItem]) -> String {
        guard let rule = items.first(where: { $0.category == .other && $0.title.contains("(\(item.label))") }) else {
            return "Up under a rule."
        }
        let others = items.filter {
            $0.category == .rule && $0.label != item.label && $0.removedAt == nil && rule.title.contains("(\($0.label))")
        }
        let with = others.isEmpty ? "" : " with " + others.map(\.title).joined(separator: " and ")
        return "Up under a rule (\(compactLabel(rule.label)))\(with)."
    }

    /// `H.Res. 1665` from the Majority Leader's `H. Res. 1665`.
    static func compactLabel(_ label: String) -> String {
        label.replacingOccurrences(of: #"\.\s+(?=[A-Z][A-Za-z]*\.)"#, with: ".", options: .regularExpression)
    }

    /// Up to two of the bill's most recent votes in `votes`: `Mon ✓ cloture 70–27`. The weekday when
    /// the vote fell in the schedule's week, else its date (`Nov 11`).
    static func chips(for item: ScheduleItem, votes: [FeedItem], weekOf days: Set<String>, calendar: Calendar) -> [String] {
        guard let id = item.billId else { return [] }
        let mine = HomeModel.newestFirst(votes.filter { $0.measure?.id == id && $0.vote.outcome != nil })
        return mine.prefix(2).map { chip($0.vote, weekOf: days, calendar: calendar) }
    }

    static func chip(_ vote: Vote, weekOf days: Set<String>, calendar: Calendar) -> String {
        var when: String?
        if let at = vote.occurredAtDate {
            var weekdays = Date.FormatStyle.dateTime.weekday(.abbreviated)
            weekdays.timeZone = calendar.timeZone
            weekdays.locale = calendar.locale ?? Locale(identifier: "en_US")
            weekdays.calendar = calendar
            when = days.contains(day(at)) ? at.formatted(weekdays) : Stories.shortDate(at, calendar: calendar)
        }
        let mark = vote.outcome == .carried ? "✓" : "✗"
        let what = "\(mark) \(vote.stepName.lowercased()) \(vote.totals.yea)–\(vote.totals.nay)"
        return [when, what].compactMap(\.self).joined(separator: " ")
    }

    /// The seven `YYYY-MM-DD` days from the week's Monday.
    static func weekDays(_ monday: String) -> Set<String> {
        guard let start = Formats.day(monday) else { return [] }
        let f = formatter("yyyy-MM-dd", zone: .gmt)
        return Set((0..<7).map { f.string(from: start.addingTimeInterval(Double($0) * 86_400)) })
    }

    // MARK: Senate next

    /// Today's meeting (`today` is `YYYY-MM-DD` in Washington), else the next one, else the last.
    public static func senateNext(_ senate: Schedule.Senate?, today: String) -> SenateMeeting? {
        let meetings = (senate?.meetings ?? []).sorted { $0.date < $1.date }
        return meetings.first { $0.date >= today } ?? meetings.last
    }

    /// `YYYY-MM-DD` for `date` in Washington.
    public static func day(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = washington
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// The card's left column: `TODAY` or the weekday (`TUE`), then `10:00` and `AM` in Washington's
    /// time; no time when senate.gov gave none.
    public static func meetingClock(_ meeting: SenateMeeting, today: String) -> (day: String, time: String?, half: String?) {
        let label: String
        if meeting.date == today {
            label = "TODAY"
        } else if let date = Formats.day(meeting.date) {
            label = formatter("EEE", zone: .gmt).string(from: date).uppercased()
        } else {
            label = meeting.date
        }
        guard let at = meeting.convenesAt.flatMap(Formats.instant) else { return (label, nil, nil) }
        return (label, formatter("h:mm").string(from: at), formatter("a").string(from: at).uppercased())
    }

    private static func formatter(_ format: String, zone: TimeZone = washington) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// The program's sentences. A period after a citation's or a name's abbreviation (`H.R.`, `No.`,
    /// `St.`, a middle initial) does not end one; `p.m.` before a capital does.
    public static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1] == " " {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                let nextIsStart = j < chars.count && (chars[j].isUppercase || chars[j] == "(")
                let token = current.split(separator: " ").last.map { String($0.dropLast()) } ?? ""
                if nextIsStart, !abbreviation(token) {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i = j
                    continue
                }
            }
            i += 1
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private static func abbreviation(_ token: String) -> Bool {
        let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "("))
        if ["a.m", "p.m"].contains(bare.lowercased()) { return false }
        if abbreviations.contains(bare) { return true }
        // A citation's dotted letters (`H.R`, `S.J.Res`) or a lone initial.
        if bare.contains(".") || (bare.count == 1 && bare.first?.isUppercase == true) { return true }
        return false
    }

    private static let abbreviations: Set<String> = [
        "No", "Nos", "Res", "St", "Mr", "Mrs", "Ms", "Dr", "Jr", "Sr", "Sec", "Gen", "Lt", "Col", "Sen", "Rep", "Rept", "Cong",
    ]

    // MARK: Fast track and the rest

    /// The House's suspension rows, what you follow first, anything pulled last.
    public static func fastTrack(_ schedule: Schedule, state: FollowState) -> [WeekSort.Row] {
        WeekSort.groups(schedule.house.items, state: state).first { $0.category == .suspension }?.rows ?? []
    }

    /// One tile per topic family among the rows still listed, the most first; ties in the families' order.
    public static func tiles(_ rows: [WeekSort.Row]) -> [FastTrackTile] {
        var counts: [TopicGroup: Int] = [:]
        for row in rows where !row.pulled { counts[TopicGroup.of(policyArea: row.item.policyArea), default: 0] += 1 }
        let order = Dictionary(uniqueKeysWithValues: TopicGroup.allCases.enumerated().map { ($1, $0) })
        return counts.map { FastTrackTile(group: $0.key, count: $0.value) }
            .sorted { ($1.count, order[$0.group]!) < ($0.count, order[$1.group]!) }
    }

    /// A family's rows, or with nil every row.
    public static func rows(_ rows: [WeekSort.Row], in group: TopicGroup?) -> [WeekSort.Row] {
        guard let group else { return rows }
        return rows.filter { TopicGroup.of(policyArea: $0.item.policyArea) == group }
    }

    /// Everything listed that is neither a headliner nor fast track: the House's other items, a rule
    /// bill taken off the list, and Senate items the program does not name — each once.
    public static func alsoListed(_ schedule: Schedule, state: FollowState) -> [WeekSort.Row] {
        let named = Set(senateNamed(schedule).map { $0.billId ?? $0.label })
        let house = schedule.house.items.filter { $0.category == .other || ($0.category == .rule && $0.removedAt != nil) }
        let houseKeys = Set(schedule.house.items.map { $0.billId ?? $0.label })
        var seen = Set<String>()
        let senate = (schedule.senate?.items ?? []).filter {
            let key = $0.billId ?? $0.label
            return !named.contains(key) && !houseKeys.contains(key) && seen.insert(key).inserted
        }
        return WeekSort.groups(house + senate, state: state).flatMap(\.rows)
    }
}
