import Foundation
import Models

/// The Bills tab's segmented control: every bill, or only those whose latest vote carried or failed.
public enum BillsFilter: String, CaseIterable, Sendable, Hashable {
    case all = "All"
    case passed = "Passed"
    case blocked = "Blocked"

    /// Whether a card whose latest vote ended `outcome` shows under this filter. A vote that settled
    /// nothing shows under All only.
    public func admits(_ outcome: Vote.Outcome?) -> Bool {
        switch self {
        case .all: true
        case .passed: outcome == .carried
        case .blocked: outcome == .failed
        }
    }
}

/// One bill on the Bills tab (v0.2.59, the locked Bills A card): its latest vote, the special-rule
/// votes that brought it to the floor folded in, and where it stands.
public struct LedgerCard: Identifiable, Sendable, Hashable {
    /// The bill's id, or the rule's own for a rule whose bill is not in the list.
    public var id: String
    public var measure: MeasureSummary
    /// The latest vote on the measure itself.
    public var latest: FeedItem
    /// The folded votes on the special rule for it, newest first.
    public var rules: [FeedItem]
    /// Set on a rule whose bill is not in the list: the bill's citation, from ``MeasureSummary/forBillId``.
    public var ruleFor: String?

    public var group: TopicGroup { TopicGroup.of(measure) }

    /// The card's newest vote, its rules' included: what the tab orders by.
    public var latestDate: Date? { ([latest] + rules).compactMap(\.vote.occurredAtDate).max() }

    /// The bill's title, or `Rule for H.R. 2102`.
    public var title: String { ruleFor.map { "Rule for \($0)" } ?? measure.title }

    /// CRS's lead; none on a rule's card.
    public var summary: String? { ruleFor == nil ? measure.summaryLead : nil }

    /// The progress track from the bill's stage; none on a rule's card or an unstaged bill.
    public var track: BillTrack? {
        guard ruleFor == nil, let stage = measure.stage else { return nil }
        return BillTrack(billId: measure.id, stage: stage, lastChamber: latest.vote.chamber)
    }
}

/// One topic family's cards, under its header.
public struct LedgerSection: Identifiable, Sendable, Hashable {
    public var group: TopicGroup
    public var cards: [LedgerCard]
    public var id: String { group.rawValue }
}

public enum BillsLedger {
    /// Every bill in `items` as one card, newest first.
    ///
    /// A vote on a House special rule whose ``MeasureSummary/forBillId`` names a bill also in
    /// `items` folds into that bill's card; a rule whose bill is not here keeps a card of its own,
    /// titled after the bill. Nominations and votes on no measure are left out.
    public static func cards(_ items: [FeedItem]) -> [LedgerCard] {
        let bills = items.filter { $0.measure?.kind == .bill }
        let ids = Set(bills.compactMap(\.measure?.id))
        func key(_ measure: MeasureSummary) -> String {
            if let bill = measure.forBillId, bill != measure.id, ids.contains(bill) { return bill }
            return measure.id
        }
        var byKey: [String: [FeedItem]] = [:]
        var order: [String] = []
        for item in HomeModel.newestFirst(bills) {
            guard let measure = item.measure else { continue }
            let k = key(measure)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(item)
        }
        let cards: [LedgerCard] = order.compactMap { k in
            let votes = byKey[k]!
            let own = votes.filter { $0.measure?.id == k }
            // A bill only its rule's votes named has no vote of its own to lead with.
            guard let latest = own.first, let measure = fullest(own.compactMap(\.measure)) else { return nil }
            let rules = votes.filter { $0.measure?.id != k }
            let ruleFor = measure.forBillId.flatMap { $0 == measure.id ? nil : citation(billId: $0) }
            return LedgerCard(id: k, measure: measure, latest: latest, rules: rules, ruleFor: ruleFor)
        }
        return newestFirst(cards)
    }

    /// The cards that pass `filter`, by topic family: each family's newest first, the families in the
    /// order of their most recent vote.
    public static func sections(_ items: [FeedItem], filter: BillsFilter) -> [LedgerSection] {
        let shown = cards(items).filter { filter.admits($0.latest.vote.outcome) }
        var byGroup: [TopicGroup: [LedgerCard]] = [:]
        var order: [TopicGroup] = []
        for card in shown {
            if byGroup[card.group] == nil { order.append(card.group) }
            byGroup[card.group, default: []].append(card)
        }
        // `shown` is newest first, so each family first appears at its most recent vote.
        return order.map { LedgerSection(group: $0, cards: byGroup[$0]!) }
    }

    /// `+ Rule adopted 271–135, Nov 12 · 245–175, Nov 11`: the rule's votes newest first, a day's
    /// scores together before its date. The word is the latest rule vote's: adopted or rejected.
    public static func ruleLine(_ rules: [FeedItem], calendar: Calendar) -> String? {
        guard let newest = rules.first else { return nil }
        var days: [(String?, [String])] = []
        for rule in rules {
            let day = rule.vote.occurredAtDate.map { Stories.shortDate($0, calendar: calendar) }
            let score = "\(rule.vote.totals.yea)–\(rule.vote.totals.nay)"
            if let last = days.last, last.0 == day {
                days[days.count - 1].1.append(score)
            } else {
                days.append((day, [score]))
            }
        }
        let word = newest.vote.outcome == .failed ? "rejected" : "adopted"
        let parts = days.map { day, scores in
            [scores.joined(separator: " · "), day].compactMap(\.self).joined(separator: ", ")
        }
        return "+ Rule \(word) \(parts.joined(separator: " · "))"
    }

    /// The footer's first line: `Passed House` / `Passed Senate` for a deciding vote that passed, else
    /// the question's kind (`Cloture`, `Motion to refer`): the House records a motion that carried as
    /// "Passed" too.
    public static func kindLine(_ vote: Vote) -> String {
        if vote.outcomeWord == "PASSED", !vote.isProcedural { return "Passed \(vote.chamber.name)" }
        return vote.questionKind
    }

    /// `R 182–18 · D 210–0`, with `I` when independents voted: yea–nay by party, R, D, I, then any other.
    public static func partyLine(_ totals: [PartyTotals]) -> String? {
        let rank = ["R": 0, "D": 1, "I": 2]
        let shown = totals.filter { $0.yea + $0.nay > 0 }
            .sorted { (rank[$0.party] ?? 3, $0.party) < (rank[$1.party] ?? 3, $1.party) }
        guard !shown.isEmpty else { return nil }
        return shown.map { "\($0.party) \($0.yea)–\($0.nay)" }.joined(separator: " · ")
    }

    /// `H.R. 2102` from `119-hr-2102`; nil for an id that is not a bill's.
    public static func citation(billId: String) -> String? {
        let parts = billId.split(separator: "-")
        guard parts.count == 3, let prefix = prefixes[String(parts[1])] else { return nil }
        return "\(prefix) \(parts[2])"
    }

    private static let prefixes = [
        "hr": "H.R.", "s": "S.", "hres": "H.Res.", "sres": "S.Res.", "hjres": "H.J.Res.", "sjres": "S.J.Res.",
        "hconres": "H.Con.Res.", "sconres": "S.Con.Res.",
    ]

    /// The copy of a measure that carries the most: rows from different routes can differ.
    private static func fullest(_ copies: [MeasureSummary]) -> MeasureSummary? {
        guard var best = copies.first else { return nil }
        for copy in copies.dropFirst() { best = best.filled(from: copy) }
        return best
    }

    private static func newestFirst(_ cards: [LedgerCard]) -> [LedgerCard] {
        cards.sorted { lhs, rhs in
            switch (lhs.latestDate, rhs.latestDate) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.id > rhs.id
            }
        }
    }
}

/// A bill's road drawn as dots: which steps it has passed, where it stands, and where it stopped.
///
/// House bills (H.R., H.J.Res.) go Introduced → House → Senate → Law, Senate bills (S., S.J.Res.)
/// Introduced → Senate → House → Law, simple resolutions Introduced → Adopted, and concurrent ones
/// through both chambers, the originating one first, to Adopted.
public struct BillTrack: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case done
        /// Done, and the furthest it has got.
        case current
        case upcoming
        /// Where it stopped: vetoed or failed.
        case stopped
    }

    public struct Step: Sendable, Hashable {
        public var name: String
        public var state: State
        /// `House ✓`, `Senate`, `Vetoed`.
        public var label: String
    }

    public var steps: [Step]
    /// The track as one sentence for VoiceOver: `Passed the House; next, the Senate`.
    public var spoken: String

    /// - Parameter lastChamber: the chamber of the latest vote, where a failed measure stopped.
    public init?(billId: String, stage: BillStage, lastChamber: Chamber?) {
        let parts = billId.split(separator: "-")
        guard parts.count == 3 else { return nil }
        let names: [String]
        switch parts[1] {
        case "hr", "hjres": names = ["Introduced", "House", "Senate", "Law"]
        case "s", "sjres": names = ["Introduced", "Senate", "House", "Law"]
        case "hres", "sres": names = ["Introduced", "Adopted"]
        case "hconres": names = ["Introduced", "House", "Senate", "Adopted"]
        case "sconres": names = ["Introduced", "Senate", "House", "Adopted"]
        default: return nil
        }
        let last = names.count - 1
        let house = names.firstIndex(of: "House")
        let senate = names.firstIndex(of: "Senate")
        let chambers = [house, senate].compactMap(\.self)
        // How far it got, and the step it stopped at with the word for it.
        var furthest: Int
        var stop: (index: Int, word: String)?
        switch stage {
        case .introduced: furthest = 0
        case .passedHouse: furthest = house ?? last
        case .passedSenate: furthest = senate ?? last
        case .passedBoth, .toPresident: furthest = chambers.max() ?? last
        case .law, .adopted: furthest = last
        case .vetoed:
            furthest = chambers.max() ?? 0
            stop = (last, "Vetoed")
        case .failed:
            let at = lastChamber.flatMap { $0 == .house ? house : senate } ?? 1
            furthest = at - 1
            stop = (at, "Failed")
        }
        // A resolution's road has no chamber steps: any passage is its adoption.
        if chambers.isEmpty, stage != .introduced, stop == nil { furthest = last }
        steps = names.enumerated().map { index, name in
            if let stop, stop.index == index { return Step(name: name, state: .stopped, label: stop.word) }
            let state: State = index < furthest ? .done : index == furthest && stop == nil ? .current : index <= furthest ? .done : .upcoming
            let done = state == .done || state == .current
            return Step(name: name, state: state, label: done && index > 0 ? "\(name) ✓" : name)
        }

        let passed = chambers.sorted().filter { $0 <= furthest && $0 > 0 }.map { "the \(names[$0])" }
        var sentence = passed.isEmpty ? "" : "Passed " + passed.joined(separator: " and ")
        func joined(_ tail: String) -> String { sentence.isEmpty ? tail.prefix(1).uppercased() + tail.dropFirst() : "\(sentence); \(tail)" }
        if let stop {
            sentence = stop.word == "Vetoed" ? joined("vetoed") : joined("failed in the \(names[stop.index])")
        } else if furthest == last {
            switch names[last] {
            case "Law": sentence = joined("became law")
            default: sentence = chambers.isEmpty ? "Adopted" : joined("adopted")
            }
        } else if furthest == 0 {
            sentence = "Introduced; next, " + Self.next(names[1])
        } else if stage == .toPresident {
            sentence = joined("next, the President")
        } else {
            sentence = joined("next, " + Self.next(names[furthest + 1]))
        }
        spoken = sentence
    }

    private static func next(_ step: String) -> String {
        switch step {
        case "House", "Senate": "the \(step)"
        case "Law": "the President"
        default: "adoption"
        }
    }
}
