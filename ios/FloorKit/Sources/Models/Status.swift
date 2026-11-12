import Foundation

/// Freshness of one ingest source.
public struct SourceStatus: Codable, Sendable, Hashable, Identifiable {
    public var source: String
    /// ISO 8601, or nil if the source has never loaded successfully.
    public var lastSuccessAt: String?
    public var lastError: String?
    /// True when the source has gone longer than its window without a successful run.
    public var stale: Bool

    public var id: String { source }

    public init(source: String, lastSuccessAt: String?, lastError: String?, stale: Bool) {
        self.source = source
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.stale = stale
    }

    public var lastSuccessDate: Date? {
        lastSuccessAt.flatMap(Formats.instant)
    }
}

/// `GET /v1/status` — `ok` is false when any source is stale.
public struct DataStatus: Codable, Sendable, Hashable {
    public var ok: Bool
    public var sources: [SourceStatus]

    public init(ok: Bool, sources: [SourceStatus]) {
        self.ok = ok
        self.sources = sources
    }

    public var staleSources: [SourceStatus] { sources.filter(\.stale) }
}

/// The error body every route returns on 4xx.
public struct APIError: Codable, Sendable, Hashable, Error {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

/// Date parsers for the two shapes the API sends.
///
/// The models keep these fields as the strings they arrive as, so decoding never depends on a
/// decoder-wide date strategy — the API mixes calendar days (`2025-02-18`) with instants
/// (`2025-04-10T15:08:00.000Z`), and one strategy cannot read both.
///
/// These are functions over `FormatStyle`, not stored `DateFormatter`s: the older formatters are not
/// `Sendable`, so holding one in a `static let` is rejected under Swift 6 concurrency checking.
public enum Formats {
    /// `YYYY-MM-DD`, read in UTC so a day never shifts with the reader's time zone.
    public static func day(_ string: String) -> Date? {
        try? Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: .gmt)
            .year().month().day()
            .parse(string)
    }

    /// An ISO 8601 instant, with or without fractional seconds.
    public static func instant(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
