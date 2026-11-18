import Foundation
import Testing
@testable import Models

/// `MeasureSummary.stage` (v0.2.59): decoded leniently, so an absent, null or unknown stage is nil
/// and never fails the row it rides on.
@Suite("MeasureSummary stage")
struct MeasureStageTests {
    private func measure(_ stage: String?) throws -> MeasureSummary {
        let field = stage.map { #","stage":\#($0)"# } ?? ""
        let json = #"{"id":"119-hr-2102","kind":"bill","citation":"H.R. 2102","title":"Major Richard Star Act","policyArea":null,"sponsor":null,"summaryLead":null,"position":null,"forBillId":null"#
            + field + "}"
        return try JSONDecoder().decode(MeasureSummary.self, from: Data(json.utf8))
    }

    @Test func knownUnknownNullAndAbsent() throws {
        #expect(try measure(#""passed_house""#).stage == .passedHouse)
        #expect(try measure(#""passed_the_moon""#).stage == nil)
        #expect(try measure("null").stage == nil)
        #expect(try measure(nil).stage == nil)
    }

    @Test func roundTrips() throws {
        let original = MeasureSummary(id: "119-s-2403", kind: .bill, citation: "S. 2403", title: "Retire through Ownership Act", stage: .law)
        let decoded = try JSONDecoder().decode(MeasureSummary.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// The captured feed: every bill's stage decodes, nominations carry none.
    @Test func theCapturedFeedCarriesStages() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        let data = try Data(contentsOf: dir.appendingPathComponent("Fixtures/votes-recent-40-2026-11-17.json"))
        let rows = try JSONDecoder().decode(RecentVotes.self, from: data).votes.compactMap(\.measure)
        #expect(rows.filter { $0.kind == .bill }.allSatisfy { $0.stage != nil })
        #expect(rows.filter { $0.kind == .nomination }.allSatisfy { $0.stage == nil })
        #expect(rows.first { $0.id == "119-s-2403" }?.stage == .law)
    }
}
