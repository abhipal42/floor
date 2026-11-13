import Foundation
import Testing
@testable import Models

/// Checks the hand-written models against the committed API contract.
///
/// `apps/api/openapi.json` is generated from the routes in `apps/api/src/app.ts` and CI fails if it
/// has drifted from them, so it is the real contract. These tests compare every model's fields with
/// the schema of the same name, which is what caught the earlier `Vote` losing `kind`,
/// `nominationId`, `billRef`, `occurredAt` and `candidates` far too late.
///
/// Field names come from `Mirror`, not from encoding a value, so a property left nil in a sample is
/// still checked. Only `Set<String>` crosses into a test case, because `@Test(arguments:)` needs
/// `Sendable` values and a decoded JSON object is not one.
@Suite("Contract")
struct ContractTests {
    /// The committed document, found relative to this file so nothing is duplicated into the bundle.
    static func document() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // ModelsTests, Tests, FloorKit, ios, repo
        let url = root.appendingPathComponent("apps/api/openapi.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func schemas() throws -> [String: [String: Any]] {
        let components = try #require(try document()["components"] as? [String: Any])
        return try #require(components["schemas"] as? [String: [String: Any]])
    }

    /// The property names a schema declares.
    static func specFields(_ name: String) throws -> Set<String> {
        let schema = try #require(try schemas()[name], "no schema named \(name)")
        let properties = try #require(schema["properties"] as? [String: Any], "\(name) has no properties")
        return Set(properties.keys)
    }

    /// The stored property names of each model, keyed by the schema it implements.
    static func modelFields() -> [String: Set<String>] {
        func fields(_ value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
        return [
            "Member": fields(Member.sample),
            "VoteTotals": fields(VoteTotals.sample),
            "Candidate": fields(Candidate.sample),
            "Vote": fields(Vote.sample),
            "PartyTotals": fields(PartyTotals.sample),
            "CandidateTotal": fields(CandidateTotal.sample),
            "MemberPosition": fields(MemberPosition.sample),
            "PartyLoyalty": fields(PartyLoyalty.sample),
            "MemberDetail": fields(MemberDetail.sample),
            "PacCheck": fields(PacCheck.sample),
            "Funding": fields(Funding.sample),
            "MemberFunding": fields(MemberFunding.sample),
            "MemberVote": fields(MemberVote.sample),
            "MeasureSummary": fields(MeasureSummary.sample),
            "District": fields(District.sample),
            "Reps": fields(Reps.sample),
            "LatestAction": fields(LatestAction.sample),
            "CboEstimate": fields(CboEstimate.sample),
            "BillAction": fields(BillAction.sample),
            "Bill": fields(Bill.sample),
            "Nomination": fields(Nomination.sample),
            "SourceStatus": fields(SourceStatus.sample),
            "Error": fields(APIError.sample),
            // Flat on the wire, nested in Swift: the vote's fields plus the three breakdowns.
            "VoteDetail": fields(Vote.sample)
                .union(["partyTotals", "candidateTotals", "positions", "measure"]),
            // Not components: these wrap a list in the route's own inline schema.
            "/v1/members/{id}/votes": fields(MemberVotes.sample),
            "/v1/status": fields(DataStatus.sample),
        ]
    }

    @Test(arguments: [
        "Member", "VoteTotals", "Candidate", "Vote", "VoteDetail", "PartyTotals", "CandidateTotal",
        "MemberPosition", "PartyLoyalty", "MemberDetail", "PacCheck", "Funding", "MemberFunding", "MemberVote", "MeasureSummary", "District",
        "Reps", "LatestAction", "CboEstimate", "BillAction", "Bill", "Nomination", "SourceStatus", "Error",
    ])
    func modelFieldsMatchItsSchema(name: String) throws {
        let model = try #require(Self.modelFields()[name], "no model registered for \(name)")
        #expect(model == (try Self.specFields(name)), "\(name) has drifted from the contract")
    }

    /// `VoteDetail` nests the vote rather than repeating its sixteen fields.
    @Test func voteDetailNestsTheVote() {
        #expect(Set(Mirror(reflecting: VoteDetail.sample).children.compactMap(\.label))
            == ["vote", "partyTotals", "candidateTotals", "positions", "measure"])
    }

    @Test(arguments: [
        ("Chamber", Set(Chamber.allCases.map(\.rawValue))),
        ("VoteKind", Set(VoteKind.allCases.map(\.rawValue))),
        ("VoteState", Set(VoteState.allCases.map(\.rawValue))),
        ("VoteThreshold", Set(VoteThreshold.allCases.map(\.rawValue))),
        ("Position", Set(Position.allCases.map(\.rawValue))),
    ])
    func enumCasesMatchTheSchema(name: String, cases: Set<String>) throws {
        let schema = try #require(try Self.schemas()[name], "no schema named \(name)")
        let values = try #require(schema["enum"] as? [String], "\(name) is not an enum")
        #expect(cases == Set(values), "\(name) has drifted from the contract")
    }

    /// Two responses wrap a list rather than naming a component, so they are checked against the
    /// route's own inline schema.
    @Test(arguments: ["/v1/members/{id}/votes", "/v1/status"])
    func wrapperResponsesMatchTheirRoute(path: String) throws {
        let paths = try #require(try Self.document()["paths"] as? [String: Any])
        let route = try #require(paths[path] as? [String: Any], "no route \(path)")
        let get = try #require(route["get"] as? [String: Any])
        let responses = try #require(get["responses"] as? [String: Any])
        let ok = try #require(responses["200"] as? [String: Any])
        let content = try #require(ok["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let model = try #require(Self.modelFields()[path], "no model registered for \(path)")
        #expect(model == Set(properties.keys), "\(path) has drifted from the contract")
    }

    /// Proves these comparisons can actually fail.
    ///
    /// Every other test here asserts that two sets are equal, which would also pass if the sets were
    /// empty or the lookup silently returned nothing. This drops one field from `Vote` — the drift
    /// that really happened — and checks the comparison rejects it.
    @Test func theComparisonRejectsADroppedField() throws {
        let schema = try Self.specFields("Vote")
        #expect(!schema.isEmpty)
        #expect(schema.contains("billRef"))

        let model = try #require(Self.modelFields()["Vote"])
        #expect(model == schema)
        #expect(model.subtracting(["billRef"]) != schema)
        #expect(model.union(["somethingTheAPINeverSends"]) != schema)
    }

    /// A schema added to the API cannot quietly go unmodelled on the phone.
    @Test func everySchemaIsModelled() throws {
        let enums: Set<String> = ["Chamber", "VoteKind", "VoteState", "VoteThreshold", "Position"]
        let modelled = Set(Self.modelFields().keys).subtracting(["/v1/members/{id}/votes", "/v1/status"])
        #expect(Set(try Self.schemas().keys) == modelled.union(enums),
                "the contract has a schema with no Swift model")
    }
}
