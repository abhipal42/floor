import Foundation
import Testing
@testable import Models

/// `GET /v1/members/{id}/disclosures`, from real responses: off as production serves it, and on
/// (DISCLOSURES_ENABLED) for Lloyd Doggett on 2026-11-14.
@Suite("Disclosures")
struct DisclosuresTests {
    @Test func offCarriesItsReason() throws {
        let off = try fixture("disclosures-off", as: Disclosures.self)
        #expect(!off.enabled)
        #expect(off.reason?.contains("13107") == true)
        #expect(off.annual == nil)
        #expect(off.trades.isEmpty)
    }

    @Test func onReadsRangesAsFiled() throws {
        let on = try fixture("disclosures-doggett", as: Disclosures.self)
        #expect(on.enabled)
        #expect(on.deadline == 45)
        let annual = try #require(on.annual)
        #expect(annual.year == 2025)
        #expect(annual.assets.count == 75)
        // Every value is a range string as filed, never a number Floor could add up.
        // Every value is a band or a word as filed, never a single figure Floor could add up.
        let isBand = { (value: String) in value.range(of: #"^\$[\d,]+ - \$[\d,]+$"#, options: .regularExpression) != nil }
        let values = annual.assets.compactMap(\.value)
        #expect(values.allSatisfy { isBand($0) || ["None", "Undetermined"].contains($0) })
        #expect(values.contains("$5,000,001 - $25,000,000"))
        #expect(on.trades.count == 11)
        #expect(on.trades.compactMap(\.amount).allSatisfy(isBand))
        #expect(on.paperFilings.count == 5)
    }

    /// The route was built beside this screen; anything it cannot read reads as off, not a crash.
    @Test func lenientWhereTheShapeMoves() throws {
        let odd = Data(#"{"enabled":true,"trades":[{"asset":"X","type":"buy","daysToFile":"soon"},{"nope":1}],"paperFilings":[{}]}"#.utf8)
        let read = try JSONDecoder().decode(Disclosures.self, from: odd)
        #expect(read.trades.count == 1)
        #expect(read.trades[0].daysToFile == nil)
        #expect(read.trades[0].verb == "Bought")
        #expect(read.paperFilings.count == 1)
        #expect(read.annual == nil)
    }

    @Test func tradeVerbs() {
        var trade = DisclosedTrade.sample
        #expect(trade.verb == "Sold")
        trade.typeFiled = "S (partial)"
        #expect(trade.verb == "Sold part")
        trade.type = "exchange"
        #expect(trade.verb == "Exchanged")
    }
}
