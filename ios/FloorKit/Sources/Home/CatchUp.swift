import Foundation
import Models

/// The catch-up deck: which five finals it deals, and the one computed line each card leads with.
///
/// **The selection rule**, in order of preference:
/// 1. Votes that **failed despite more yeas than nays** — the ones a bare score misreads, because a
///    supermajority was needed and not reached.
/// 2. Then the **closest margins against their own threshold**: the smallest distance, either way,
///    between the yea count and the votes it needed. A 215–209 rule vote that cleared by two ranks
///    above a 417–3 suspension that cleared by 137.
/// 3. Then the **most recent**, and finally the vote ID, so the same feed always deals the same deck.
///
/// Only final yea/nay questions are eligible: a Speaker ballot has no threshold line to sit near.
public enum CatchUp {
    public static func select(_ items: [FeedItem], count: Int = 5) -> [FeedItem] {
        let eligible = items.filter { $0.vote.kind == .question && $0.vote.outcome != nil && $0.vote.line != nil }
        return Array(eligible.sorted(by: ranksAhead).prefix(count))
    }

    /// True when `a` is dealt before `b`.
    static func ranksAhead(_ a: FeedItem, _ b: FeedItem) -> Bool {
        let (fa, fb) = (failedDespiteMajority(a.vote), failedDespiteMajority(b.vote))
        if fa != fb { return fa }
        let (ma, mb) = (abs(a.vote.line?.margin ?? .max), abs(b.vote.line?.margin ?? .max))
        if ma != mb { return ma < mb }
        switch (a.vote.occurredAtDate, b.vote.occurredAtDate) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.vote.id > b.vote.id
        }
    }

    static func failedDespiteMajority(_ vote: Vote) -> Bool {
        vote.outcome == .failed && vote.totals.yea > vote.totals.nay
    }

    /// The twist: one sentence computed from the numbers on the card and nothing else — no model,
    /// no claim the counts do not carry. The first rule that applies wins:
    ///
    /// 1. Failed with more yeas than nays: what it was short of.
    /// 2. Carried with three or fewer against: how lopsided.
    /// 3. Your members split: who went which way.
    /// 4. Within five of the line either way: how close.
    /// 5. Otherwise: how far past or short of the line it finished.
    public static func twist(_ item: FeedItem) -> String {
        let vote = item.vote
        guard let line = vote.line, let outcome = vote.outcome else { return vote.question }
        let chamber = vote.chamber.name

        if failedDespiteMajority(vote), let short = line.short {
            switch line.threshold {
            case .twoThirds:
                return "Won the room by \(line.yea - line.nay) and fell \(short) short of two-thirds."
            case .threeFifthsSworn:
                return "A majority voted yes and it still lost: \(short) short of \(line.needed)."
            case .majority:
                return "More yeas than nays, and it still lost: \(short) short of a majority of those voting."
            }
        }
        if outcome == .carried, line.nay <= 3 {
            if line.nay == 0 { return "Not one vote against in the entire \(chamber)." }
            return "\(word(line.nay).capitalized) vote\(line.nay == 1 ? "" : "s") against in the entire \(chamber)."
        }
        let sides = item.positions.filter { $0.position == .yea || $0.position == .nay }
        if Set(sides.map(\.position)).count > 1 {
            let who = sides.map { "\($0.member.lastName) \($0.position.rawValue)" }.joined(separator: ", ")
            return "Your \(chamber == "Senate" ? "senators" : "members") split: \(who)."
        }
        if let over = line.over, over <= 5 {
            return over == 0
                ? "Not a vote to spare: exactly the \(line.needed) it needed."
                : "Cleared the line by \(over): \(line.yea) yea against the \(line.needed) it needed."
        }
        if let short = line.short, short <= 5 {
            return "\(word(short).capitalized) vote\(short == 1 ? "" : "s") from carrying: \(line.yea) yea against the \(line.needed) it needed."
        }
        if let over = line.over {
            return line.threshold == .majority
                ? "Won by \(line.yea - line.nay), \(over) past the line."
                : "Cleared \(line.threshold == .twoThirds ? "two-thirds" : "sixty") with \(over) to spare."
        }
        return "Fell \(line.short ?? 0) short of the \(line.needed) it needed."
    }

    private static func word(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n < words.count ? words[n] : "\(n)"
    }
}

/// The split-flap board's three rows, sixteen cells each, as the Home mock lays them out.
public enum FlapBoard {
    public static let width = 16

    /// `HOUSE  ROLL 321` / `H.R. 1013 PASSED` / `YEA 295 NAY 128`, each centred and cut to fit.
    public static func rows(_ item: FeedItem) -> [String] {
        let vote = item.vote
        let first = [vote.chamber.name.uppercased(), vote.rollNumber.map { "ROLL \($0)" }]
            .compactMap(\.self).joined(separator: "  ")
        if vote.kind == .election {
            let leader = vote.leadingCandidate
            return [
                first,
                vote.electedSpeaker == nil ? "NO SPEAKER YET" : "SPEAKER ELECTED",
                leader.map { "\($0.name.uppercased()) \($0.total)" } ?? "",
            ].map(pad)
        }
        let cite = item.measure?.citation.uppercased() ?? vote.questionKind.uppercased()
        let word = vote.outcomeWord ?? "FINAL"
        let second = cite.count + 1 + word.count <= width ? "\(cite) \(word)" : word
        return [first, second, "YEA \(vote.totals.yea) NAY \(vote.totals.nay)"].map(pad)
    }

    /// Centred in sixteen cells, the extra space on the right, as the mock's `pad` does.
    static func pad(_ text: String) -> String {
        let cut = String(text.prefix(width))
        let left = (width - cut.count) / 2
        return String(repeating: " ", count: left) + cut + String(repeating: " ", count: width - cut.count - left)
    }
}
