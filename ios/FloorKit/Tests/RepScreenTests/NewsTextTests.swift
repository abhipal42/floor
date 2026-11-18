import DesignSystem
import Foundation
import Models
import Testing
@testable import RepScreen

private func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent()
    dir.deleteLastPathComponent()
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")))
}

/// The News section's and page's words, from the v0.2.60 fixtures: Schumer AI-read (25 headlines in
/// two stories and three others, three polls), Gillibrand not AI-read (14 headlines, no polls).
@Suite("News words")
struct NewsTextTests {
    @Test func schumersSummaryAndChips() throws {
        let news = try load("news-schumer-2026-11-17", as: MemberNews.self)
        #expect(NewsText.count(news) == "25 headlines this week")
        #expect(NewsText.spokenSummary(news) == "25 headlines this week. Read by AI: 2 favorable, 16 neutral, 7 critical.")
        #expect(NewsText.filters(news).map(\.label) == [
            "All", "Van Hollen challenges… · 20", "Polls on Schumer… · 2", "Other · 3",
        ])
        #expect(NewsText.chipTitle("Budget fight") == "Budget fight")
        #expect(NewsText.listTitle(news) == "Other headlines")
        #expect(NewsText.storyEyebrow(20) == "STORY · 20 HEADLINES")
        #expect(NewsText.more(17) == "17 more ›")
        #expect(NewsText.pollFootnote("Chuck Schumer") == "Each poll opens its release. Only polls that name Chuck Schumer are shown.")
    }

    /// Not AI-read: no counts, no chips beyond All, a plain list.
    @Test func gillibrandsWeekIsPlain() throws {
        let news = try load("news-gillibrand-2026-11-17", as: MemberNews.self)
        #expect(NewsText.spokenSummary(news) == "14 headlines this week.")
        #expect(NewsText.filters(news).map(\.label) == ["All"])
        #expect(NewsText.listTitle(news) == "Headlines")
        #expect(NewsText.noPolls("Kirsten Gillibrand") == "No published poll has named Kirsten Gillibrand in the last 90 days.")
    }

    @Test func oneHeadlineAndNone() {
        var news = MemberNews(memberId: "X", headlines: [.sample])
        #expect(NewsText.count(news) == "1 headline this week")
        news.headlines = []
        #expect(NewsText.spokenSummary(news) == "No headlines this week.")
        #expect(news.isEmpty)
    }

    /// A headline reads title, source, date and tone; the tone bar has its own sentence.
    @Test func spokenHeadlineAndBar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let news = try load("news-schumer-2026-11-17", as: MemberNews.self)
        let first = try #require(news.headlines.first)
        #expect(HeadlineRow.spoken(first, calendar: calendar)
            == "Schumer declares he has votes to beat Van Hollen and become majority leader, The Hill, Nov 17, favorable coverage")
        let office = try #require(try load("news-gillibrand-2026-11-17", as: MemberNews.self).headlines.first { $0.tone == .office })
        #expect(HeadlineRow.spoken(office, calendar: calendar).hasSuffix("Merkley (.gov), Nov 17, from their office"))
        #expect(ToneBar.spoken(news.stories[0].tone) == "Coverage tone: 2 favorable, 13 neutral, 5 critical.")
    }
}
