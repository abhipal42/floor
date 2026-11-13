import Foundation

// `GET /v1/members/{id}/funding`: a member's current campaign's money, from two FEC sources that do
// not reconcile (lesson 24). `Funding`'s totals are what the campaign reported receiving;
// `committees` is what committees reported giving. Never present one as a breakdown of the other.
//
// No individual donor is named anywhere in this response, and nothing here may add one: the FEC
// publishes them, Floor does not (product rule; lesson 23 for how earmark memos are dropped).

/// One committee's giving to a member over an FEC cycle.
///
/// `direct` is the committee's own checks; `earmarked` is individuals' money it passed through.
/// Neither is comparable to a contribution limit — the cap is per election and a cycle can hold
/// several — so never present either as "the maximum".
public struct PacCheck: Codable, Sendable, Hashable, Identifiable {
    public var committeeId: String
    /// As filed with the FEC, in capitals. Show ``displayName``.
    public var name: String
    /// "Trade group", "Company", "Union", "Membership group"… from FEC's organization type; nil
    /// when FEC classifies the committee as nothing (about 22% of PAC dollars).
    public var kind: String?
    /// The raw FEC `ORG_TP`.
    public var orgType: String?
    public var connectedOrg: String?
    public var direct: Double
    public var earmarked: Double

    public var id: String { committeeId }

    public init(
        committeeId: String, name: String, kind: String?, orgType: String?, connectedOrg: String?,
        direct: Double, earmarked: Double
    ) {
        self.committeeId = committeeId
        self.name = name
        self.kind = kind
        self.orgType = orgType
        self.connectedOrg = connectedOrg
        self.direct = direct
        self.earmarked = earmarked
    }

    /// The filed name in title case: "Motorola Solutions, Inc. PAC".
    public var displayName: String { CommitteeName.display(name) }
}

/// What a member's current campaign reported receiving, and the committees that reported giving.
public struct Funding: Codable, Sendable, Hashable {
    /// The election this campaign is for: 2030 for a senator elected in 2024. Not ``committeesCycle``.
    public var cycle: Int
    /// `yyyy-MM-dd`.
    public var coverageStart: String?
    /// `yyyy-MM-dd`, through which the figures run.
    public var coverageEnd: String?
    /// Total raised this campaign to date, as the campaign reported it.
    public var receipts: Double
    /// Individual contributions under $200 per donor (unitemized).
    public var smallDollar: Double
    /// Individual contributions itemized by FEC.
    public var itemized: Double
    /// From other political committees.
    public var pac: Double
    /// From party committees.
    public var party: Double
    /// Transfers, the candidate's own money, refunds and other receipts.
    public var other: Double
    public var cashOnHand: Double?
    /// The two-year FEC cycle ``committees`` covers — 2026 even for a senator whose campaign is for
    /// 2028 (lesson 33). nil when Floor holds no committee rows for them.
    public var committeesCycle: Int?
    /// Biggest PAC givers by direct amount. Party and joint fundraising committees are excluded.
    public var committees: [PacCheck]

    public init(
        cycle: Int, coverageStart: String?, coverageEnd: String?, receipts: Double, smallDollar: Double,
        itemized: Double, pac: Double, party: Double, other: Double, cashOnHand: Double?,
        committeesCycle: Int?, committees: [PacCheck]
    ) {
        self.cycle = cycle
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.receipts = receipts
        self.smallDollar = smallDollar
        self.itemized = itemized
        self.pac = pac
        self.party = party
        self.other = other
        self.cashOnHand = cashOnHand
        self.committeesCycle = committeesCycle
        self.committees = committees
    }
}

/// The member and their campaign's money. `funding` is nil for a member FEC has no current-campaign
/// totals for: a newly appointed senator, or one who hasn't filed for the next race.
public struct MemberFunding: Codable, Sendable, Hashable {
    public var member: Member
    public var funding: Funding?

    public init(member: Member, funding: Funding?) {
        self.member = member
        self.funding = funding
    }
}

// MARK: - Presentation

public extension Funding {
    /// The four parts of the bar, in the order the mock draws them. Party money is rarely more
    /// than a sliver, so it rides with transfers, as on the landing page.
    enum Part: String, CaseIterable, Sendable {
        case smallDollar, itemized, pac, other

        /// "Small-dollar", "Larger gifts", "PACs", "Transfers & other".
        public var label: String {
            switch self {
            case .smallDollar: "Small-dollar"
            case .itemized: "Larger gifts"
            case .pac: "PACs"
            case .other: "Transfers & other"
            }
        }
    }

    /// The part as reported. `.other` can be negative: the worker computes it as receipts minus the
    /// other parts (`apps/worker/src/fec.ts`), and refunds and adjustments can outweigh transfers.
    func amount(_ part: Part) -> Double {
        switch part {
        case .smallDollar: smallDollar
        case .itemized: itemized
        case .pac: pac
        case .other: party + other
        }
    }

    /// The part as the bar and the legend draw it: never below zero, so a negative remainder is an
    /// empty part rather than a bar that runs backwards. Both read this, so they always agree.
    func shown(_ part: Part) -> Double { max(0, amount(part)) }

    /// What the shares are of: the parts as shown. Equal to `receipts` (to the cent) unless a part
    /// was negative, when it is the other parts' sum, so the legend still adds to 100%.
    var shareBase: Double { Part.allCases.map(shown).reduce(0, +) }

    /// "45.5%" of the parts shown, or "—" when there is nothing to share out.
    func percent(_ part: Part) -> String {
        guard shareBase > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * shown(part) / shareBase)
    }

    /// Said under the legend when "Transfers & other" came to less than nothing.
    var adjustmentNote: String? {
        let other = amount(.other)
        guard other < 0 else { return nil }
        return "Transfers & other came to \(MoneyFormat.total(other)): it includes refunds/adjustments, "
            + "so it shows as 0 and the shares are of the other three."
    }

    /// "2026 campaign · Jan 2025 – Oct 14, 2026". The campaign, not the FEC cycle: a senator's
    /// reads "2030 campaign" (lesson 33).
    var period: String {
        let range = FundingDates.range(coverageStart, coverageEnd)
        return "\(cycle) campaign" + (range.isEmpty ? "" : " · \(range)")
    }

    /// The PAC list: the committees' own checks, biggest first, nothing that netted to zero or
    /// below (a voided check), at most `limit`.
    func pacChecks(limit: Int = 10) -> [PacCheck] {
        Array(committees.filter { $0.direct > 0 }.prefix(limit))
    }

    /// What the PAC list covers and what a check can be, so a senator's 2030 campaign beside a
    /// 2025–26 list is never read as the same period.
    var pacsNote: String {
        let years = committeesCycle.map { "Each PAC's own checks, from its \(FundingDates.cycleYears($0)) filings. " } ?? ""
        return years + "A PAC can give $5,000 per election — primary and general — so $10,000 is the usual most for one race."
    }

    /// Shown in place of the PAC list when it is empty.
    var pacsNone: (title: String, body: String) {
        let years = committeesCycle.map { FundingDates.cycleYears($0) }
        return (
            "No PAC checks on file" + (years.map { " for \($0)" } ?? "") + ".",
            "No committee has reported giving to this campaign" + (years.map { " in the \($0) FEC files" } ?? "") + "."
        )
    }
}

public extension MemberFunding {
    /// Why there is nothing to show, for a member with no current-campaign totals.
    var noFilings: (title: String, body: String) {
        (
            "No campaign filings yet",
            "\(member.fullName) has no totals at the FEC for a current campaign. A newly appointed member, "
                + "or one who hasn't filed for the next race, shows up here once the FEC lists their campaign."
        )
    }
}

/// Campaign money as the landing page prints it, so the two never disagree.
public enum MoneyFormat {
    /// $17.9M, $4.23M, $884K, −$12K: two decimals under $10M, one above. Rounds before it picks the
    /// unit, so $999,500 is "$1.00M" rather than "$1000K", and $9,996,000 is "$10.0M"; the sign
    /// goes before the dollar sign. Same rule as the landing page's `formatMoney`.
    public static func total(_ x: Double) -> String {
        let sign = x < 0 ? "−" : ""
        let a = abs(x)
        let thousands = (a / 1000).rounded()
        guard thousands >= 1000 else { return "\(sign)$\(Int(thousands))K" }
        let hundredths = (a / 1e4).rounded() / 100
        if hundredths < 10 { return sign + "$" + String(format: "%.2f", hundredths) + "M" }
        return sign + "$" + String(format: "%.1f", (a / 1e5).rounded() / 10) + "M"
    }

    /// The same amount for VoiceOver, in words: "17.9 million dollars", "884 thousand dollars",
    /// "minus 12 thousand dollars". The PAC rows speak whole dollars; a total is spoken at the
    /// precision it is printed at, so the ear and the eye get the same figure.
    public static func spoken(_ x: Double) -> String {
        let printed = total(x)
        let sign = printed.hasPrefix("−") ? "minus " : ""
        let digits = printed.drop(while: { $0 == "−" || $0 == "$" })
        let unit = digits.hasSuffix("M") ? "million" : "thousand"
        return "\(sign)\(digits.dropLast()) \(unit) dollars"
    }

    /// A PAC check: $10K, $5K, $2.5K, $15.3K, $750.
    public static func check(_ amount: Double) -> String {
        if abs(amount) < 1000 { return "$\(Int(amount.rounded()))" }
        let k = (amount / 100).rounded() / 10
        return "$" + (k == k.rounded() ? String(Int(k)) : String(k)) + "K"
    }
}

/// FEC dates are calendar days. Read and printed in UTC, so a phone west of Greenwich never slides
/// Oct 14 back to Oct 13.
public enum FundingDates {
    private static let utc = TimeZone(identifier: "UTC")!

    static func day(_ iso: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = utc
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: iso)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "Jan 2025 – Oct 14, 2026", or whichever end is known.
    public static func range(_ start: String?, _ end: String?) -> String {
        let a = start.flatMap(day).map { format($0, "MMM yyyy") } ?? ""
        let b = end.flatMap(day).map { format($0, "MMM d, yyyy") } ?? ""
        if !a.isEmpty, !b.isEmpty { return "\(a) – \(b)" }
        return a.isEmpty ? b : a
    }

    /// "2025–26": the two-year FEC cycle ending in `cycle`.
    public static func cycleYears(_ cycle: Int) -> String {
        "\(cycle - 1)–\(String(String(cycle).suffix(2)))"
    }
}

/// FEC committee names are filed in capitals. This is the landing page's `committeeName`
/// (`apps/web/src/locate.ts`), rule for rule, so a committee reads the same on both: parenthetical
/// nicknames dropped, letter-spaced words closed up (AFSCME's P E O P L E), "POLITICAL ACTION
/// COMMITTEE" shortened to PAC, initialisms kept in capitals. A rule, not a dictionary, so an odd one
/// (L3HARRIS) slips through.
public enum CommitteeName {
    static let acronyms: Set<String> = [
        "PAC", "AFL", "CIO", "IBEW", "SEIU", "UAW", "NEA", "AFT", "AMA", "ADA", "AARP", "NRA", "UA", "USA",
        "US", "UPS", "CVS", "IBM", "GE", "BP", "LLC", "LLP", "TIAA", "AT&T", "II", "III",
    ]
    static let small: Set<String> = ["of", "and", "the", "for", "on", "in", "to", "a", "an", "at", "by"]

    public static func display(_ raw: String) -> String {
        var keep: Set<String> = []
        var s = replace(raw, #"\s*\([^)]*\)"#, with: "")
        s = replace(s, #"\b(?:[A-Z] ){2,}[A-Z]\b"#) { match in
            let word = match.replacingOccurrences(of: " ", with: "")
            keep.insert(word)
            return word
        }
        s = replace(s, "POLITICAL ACTION COMMITTEE", with: "PAC", caseInsensitive: true)
        s = replace(s, #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
        return s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, word in
            word.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { k, part in
                casePart(String(part), first: i == 0 && k == 0, keep: keep)
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    static func casePart(_ part: String, first: Bool, keep: Set<String>) -> String {
        let bare = String(part.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "&" })
        let upper = bare.uppercased()
        let hasDigit = bare.contains(where: \.isNumber)
        // Y is a vowel in a word of three letters or more (BYRD, LYNN), not in two (MY stays a
        // guess either way, so it keeps its capitals).
        let vowels = bare.count >= 3 ? "AEIOUY" : "AEIOU"
        let hasVowel = upper.contains(where: { vowels.contains($0) })
        if acronyms.contains(upper) || keep.contains(upper) || hasDigit
            || (bare.count > 3 && upper.hasSuffix("PAC")) || (bare.count > 1 && !hasVowel) {
            return part.uppercased()
        }
        let lower = part.lowercased()
        if !first, small.contains(lower) { return lower }
        guard let index = lower.firstIndex(where: { ("a"..."z").contains($0) }) else { return lower }
        var cased = lower.replacingCharacters(in: index...index, with: lower[index].uppercased())
        // O'BRIEN, D'AMATO: the letter after a leading O' or D' is a capital too.
        let chars = Array(cased)
        if chars.count > 2, "od".contains(chars[0].lowercased()), chars[1] == "'" || chars[1] == "’",
           ("a"..."z").contains(chars[2]) {
            cased = String(chars[0...1]) + chars[2].uppercased() + String(chars[3...])
        }
        return cased
    }

    private static func replace(_ s: String, _ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func replace(_ s: String, _ pattern: String, transform: (String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
