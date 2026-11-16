import Foundation

/// `GET /v1/members/{id}/disclosures`: a member's financial disclosures as filed, in ranges.
///
/// Off until the team settles 5 U.S.C. §13107 (the reports may not be used commercially other than
/// for news): then the route answers `{ enabled: false, reason }` and the app shows the reason as a
/// visible placeholder. Values are the ranges the member filed; nothing here is a total, and the app
/// never adds them up (product rule "Ranges, not net worth").
///
/// Decoded leniently, field by field: the route was built in parallel with this screen, so a field
/// this build does not know is ignored and a missing one reads as nil rather than failing the tab.
public struct Disclosures: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Why the section is off; nil when it is on, or the API gave none.
    public var reason: String?
    /// The STOCK Act's deadline for reporting a trade, in days (45).
    public var deadlineDays: Int?
    /// The latest annual report; nil when none is on file.
    public var annual: AnnualDisclosure?
    public var trades: [DisclosedTrade]
    /// Filings only on paper (scanned), linked rather than read.
    public var paperFilings: [PaperFiling]

    public init(
        enabled: Bool, reason: String?, deadlineDays: Int? = nil, annual: AnnualDisclosure? = nil,
        trades: [DisclosedTrade] = [], paperFilings: [PaperFiling] = []
    ) {
        self.enabled = enabled
        self.reason = reason
        self.deadlineDays = deadlineDays
        self.annual = annual
        self.trades = trades
        self.paperFilings = paperFilings
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, reason, deadlineDays, annual, trades, paperFilings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        deadlineDays = try? c.decodeIfPresent(Int.self, forKey: .deadlineDays)
        annual = try? c.decodeIfPresent(AnnualDisclosure.self, forKey: .annual)
        trades = ((try? c.decodeIfPresent([LossyElement<DisclosedTrade>].self, forKey: .trades)) ?? []).compactMap(\.value)
        paperFilings = ((try? c.decodeIfPresent([LossyElement<PaperFiling>].self, forKey: .paperFilings)) ?? [])
            .compactMap(\.value)
    }

    /// What a phone without the route (an API older than it) reads: off, with no reason given.
    public static let unavailable = Disclosures(enabled: false, reason: nil)

    /// The deadline the API states, else the STOCK Act's 45 days.
    public var deadline: Int { deadlineDays ?? 45 }
}

/// An annual financial disclosure report.
public struct AnnualDisclosure: Codable, Sendable, Hashable {
    /// The calendar year it covers.
    public var year: Int?
    public var filedAt: String?
    /// An amendment to an earlier report.
    public var amendment: Bool
    public var sourceUrl: String?
    /// Floor's AI transcribed these rows from a paper (handwritten or scanned) filing: shown with
    /// the AI tag, "may contain errors", and the link to the original (HANDOFF lesson 73).
    public var transcribed: Bool
    public var assets: [DisclosedAsset]

    public init(year: Int?, filedAt: String?, amendment: Bool, sourceUrl: String?, transcribed: Bool = false, assets: [DisclosedAsset]) {
        self.year = year
        self.filedAt = filedAt
        self.amendment = amendment
        self.sourceUrl = sourceUrl
        self.transcribed = transcribed
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case year, filedAt, amendment, sourceUrl, transcribed, assets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        filedAt = try? c.decodeIfPresent(String.self, forKey: .filedAt)
        amendment = (try? c.decodeIfPresent(Bool.self, forKey: .amendment)) ?? false
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
        transcribed = (try? c.decodeIfPresent(Bool.self, forKey: .transcribed)) ?? false
        assets = ((try? c.decodeIfPresent([LossyElement<DisclosedAsset>].self, forKey: .assets)) ?? []).compactMap(\.value)
    }
}

/// One asset line of an annual report, its value as the filed range (`DisclosureAsset`).
public struct DisclosedAsset: Codable, Sendable, Hashable {
    public var name: String
    /// The House code's name, or the Senate's type / subtype.
    public var type: String?
    /// The House's two-letter code; nil for the Senate.
    public var typeCode: String?
    /// The account or holding it sits in, when the filing says.
    public var account: String?
    /// `self`, `spouse`, `joint`, `dependent` (a dependent child).
    public var owner: String?
    /// The value range exactly as filed, e.g. `$15,001 - $50,000`. Never a number.
    public var value: String?
    public var incomeType: String?
    /// As filed.
    public var income: String?
    public var description: String?

    public init(
        name: String, type: String?, typeCode: String?, account: String?, owner: String?, value: String?,
        incomeType: String?, income: String?, description: String?
    ) {
        self.name = name
        self.type = type
        self.typeCode = typeCode
        self.account = account
        self.owner = owner
        self.value = value
        self.incomeType = incomeType
        self.income = income
        self.description = description
    }
}

/// A periodic transaction report's line: one trade, reported in a range.
public struct DisclosedTrade: Codable, Sendable, Hashable {
    /// `buy`, `sell` or `exchange`.
    public var type: String?
    /// The type as the filing printed it (`P`, `S (partial)`).
    public var typeFiled: String?
    public var asset: String
    public var ticker: String?
    public var assetType: String?
    public var owner: String?
    /// The range as filed, e.g. `$1,001 - $15,000`.
    public var amount: String?
    /// `YYYY-MM-DD`.
    public var transactedAt: String?
    public var notifiedAt: String?
    public var filedAt: String?
    /// Days from the trade to the filing, as the API counted them.
    public var daysToFile: Int?
    /// Filed after the deadline (``Disclosures/deadline``).
    public var pastDeadline: Bool
    public var comment: String?
    public var sourceUrl: String?

    public init(
        type: String?, typeFiled: String?, asset: String, ticker: String?, assetType: String?, owner: String?,
        amount: String?, transactedAt: String?, notifiedAt: String?, filedAt: String?, daysToFile: Int?,
        pastDeadline: Bool, comment: String?, sourceUrl: String?
    ) {
        self.type = type
        self.typeFiled = typeFiled
        self.asset = asset
        self.ticker = ticker
        self.assetType = assetType
        self.owner = owner
        self.amount = amount
        self.transactedAt = transactedAt
        self.notifiedAt = notifiedAt
        self.filedAt = filedAt
        self.daysToFile = daysToFile
        self.pastDeadline = pastDeadline
        self.comment = comment
        self.sourceUrl = sourceUrl
    }

    private enum CodingKeys: String, CodingKey {
        case type, typeFiled, asset, ticker, assetType, owner, amount, transactedAt, notifiedAt, filedAt
        case daysToFile, pastDeadline, comment, sourceUrl
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decode(String.self, forKey: .asset)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        typeFiled = try? c.decodeIfPresent(String.self, forKey: .typeFiled)
        ticker = try? c.decodeIfPresent(String.self, forKey: .ticker)
        assetType = try? c.decodeIfPresent(String.self, forKey: .assetType)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        amount = try? c.decodeIfPresent(String.self, forKey: .amount)
        transactedAt = try? c.decodeIfPresent(String.self, forKey: .transactedAt)
        notifiedAt = try? c.decodeIfPresent(String.self, forKey: .notifiedAt)
        filedAt = try? c.decodeIfPresent(String.self, forKey: .filedAt)
        daysToFile = try? c.decodeIfPresent(Int.self, forKey: .daysToFile)
        pastDeadline = (try? c.decodeIfPresent(Bool.self, forKey: .pastDeadline)) ?? false
        comment = try? c.decodeIfPresent(String.self, forKey: .comment)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
    }

    /// `Bought`, `Sold`, `Sold part` (filed `S (partial)`), `Exchanged`.
    public var verb: String {
        switch type?.lowercased() {
        case "buy": "Bought"
        case "sell": typeFiled?.lowercased().contains("partial") == true ? "Sold part" : "Sold"
        case "exchange": "Exchanged"
        default: typeFiled ?? "Traded"
        }
    }
}

/// A filing that exists only as a scanned paper form.
public struct PaperFiling: Codable, Sendable, Hashable {
    /// `annual` or `ptr` (a periodic transaction report).
    public var kind: String?
    public var reportYear: Int?
    public var filedAt: String?
    public var sourceUrl: String?
    /// `paper` (scanned, not read) or `unparsed` (electronic, could not be read).
    public var status: String?

    public init(kind: String?, reportYear: Int?, filedAt: String?, sourceUrl: String?, status: String?) {
        self.kind = kind
        self.reportYear = reportYear
        self.filedAt = filedAt
        self.sourceUrl = sourceUrl
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reportYear, filedAt, sourceUrl, status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        reportYear = try? c.decodeIfPresent(Int.self, forKey: .reportYear)
        filedAt = try? c.decodeIfPresent(String.self, forKey: .filedAt)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
    }
}

/// One array element decoded on its own: nil rather than a thrown error when it can't be read.
struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// `GET /v1/vote-kinds`.
public struct VoteKindList: Codable, Sendable, Hashable {
    public var kinds: [VoteKindInfo]

    public init(kinds: [VoteKindInfo]) {
        self.kinds = kinds
    }
}

public extension Schedule {
    /// The Monday as a date, in UTC like every calendar day here.
    var monday: Date? { Formats.day(week) }

    /// `Nov 16–20`: Monday to Friday, the days the House lists.
    var weekRange: String {
        guard let monday else { return week }
        let friday = monday.addingTimeInterval(4 * 86_400)
        let month = Date.FormatStyle(timeZone: .gmt).month(.abbreviated)
        let day = Date.FormatStyle(timeZone: .gmt).day()
        let start = "\(monday.formatted(month)) \(monday.formatted(day))"
        let sameMonth = monday.formatted(month) == friday.formatted(month)
        return sameMonth ? "\(start)–\(friday.formatted(day))" : "\(start) – \(friday.formatted(month)) \(friday.formatted(day))"
    }

    /// `Nov 16`: how a message names the week.
    var weekOf: String {
        guard let monday else { return week }
        return monday.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide).day())
    }

    /// Where a bill is on this week's lists, if it is (and was not taken off).
    func listing(billId: String) -> (chamber: Chamber, item: ScheduleItem)? {
        if let item = house.items.first(where: { $0.billId == billId && $0.removedAt == nil }) { return (.house, item) }
        if let item = senate?.items.first(where: { $0.billId == billId && $0.removedAt == nil }) { return (.senate, item) }
        return nil
    }

    /// The Monday (`YYYY-MM-DD`) of the week `date` falls in, in Washington, `offset` weeks on: the
    /// API's own rule (`scheduleWeek` in apps/api/src/app.ts), so the app asks for the week it shows.
    static func monday(of date: Date, offsetWeeks offset: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let day = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) else {
            return ""
        }
        let weekday = utc.component(.weekday, from: day) // 1 = Sunday
        let back = (weekday + 5) % 7
        let monday = day.addingTimeInterval(TimeInterval((-back + 7 * offset) * 86_400))
        return monday.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash))
    }
}

// Samples: Lloyd Doggett's (D000399) 2025 annual report and trades, as the API served them on
// 2026-11-14 with DISCLOSURES_ENABLED on (`ModelsTests/Fixtures/disclosures-doggett.json`).

public extension DisclosedAsset {
    static let sample = DisclosedAsset(
        name: "Akre Focus - Institutional (AKRIX)", type: "Mutual Funds", typeCode: "MF", account: nil, owner: "self",
        value: "$250,001 - $500,000", incomeType: "Capital Gains", income: "$15,001 - $50,000", description: nil
    )
}

public extension DisclosedTrade {
    static let sample = DisclosedTrade(
        type: "sell", typeFiled: "S", asset: "Warner Bros. Discovery, Inc. - Series A Common Stock (WBD)", ticker: "WBD",
        assetType: "Stocks (including ADRs)", owner: "spouse", amount: "$50,001 - $100,000", transactedAt: "2026-10-07",
        notifiedAt: "2026-10-07", filedAt: "2026-11-06", daysToFile: 30, pastDeadline: false, comment: nil, sourceUrl: nil
    )
}

public extension PaperFiling {
    static let sample = PaperFiling(
        kind: "ptr", reportYear: nil, filedAt: "2026-06-04",
        sourceUrl: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20034712.pdf", status: "unparsed"
    )
}

public extension AnnualDisclosure {
    static let sample = AnnualDisclosure(
        year: 2025, filedAt: "2026-07-13", amendment: false,
        sourceUrl: "https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025/10074933.pdf", assets: [.sample]
    )
}

public extension Disclosures {
    static let sample = Disclosures(
        enabled: true, reason: nil, deadlineDays: 45, annual: .sample, trades: [.sample], paperFilings: [.sample]
    )
}
