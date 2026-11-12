import Foundation
import Testing
@testable import APIClient
import Models

/// Exercises the client against a real running API rather than a stub.
///
/// Skipped unless `FLOOR_API_URL` is set, so CI and ordinary `swift test` runs do not depend on a
/// server or a database:
///
///     npm run dev -w @floor/api
///     FLOOR_API_URL=http://localhost:8787 swift test --package-path ios/FloorKit
///
/// These assert shapes and invariants rather than exact figures, since staging gains votes over
/// time. The one exception is H.Con.Res. 14's 216-214, which is a closed historical roll call.
@Suite(
    "FloorAPI against a live server",
    .enabled(if: ProcessInfo.processInfo.environment["FLOOR_API_URL"] != nil)
)
struct LiveAPITests {
    let api = FloorAPI(
        baseURL: URL(string: ProcessInfo.processInfo.environment["FLOOR_API_URL"] ?? "http://localhost:8787")!
    )

    @Test func readsAVoteWithTheDelegationsPositions() async throws {
        let detail = try await api.vote(id: "house-119-1-100", members: ["A000370", "K000401"])
        #expect(detail.vote.totals.yea == 216)
        #expect(detail.vote.totals.nay == 214)
        #expect(detail.partyTotals.reduce(0) { $0 + $1.yea } == detail.vote.totals.yea)
        #expect(detail.positions.count == 2)
    }

    @Test func readsASpeakerElection() async throws {
        let detail = try await api.vote(id: "house-118-1-10")
        #expect(detail.vote.kind == .election)
        #expect(detail.vote.electedSpeaker == nil) // this ballot elected nobody
        #expect(!detail.candidateTotals.isEmpty)
    }

    @Test func readsABillANominationAndAMember() async throws {
        #expect(try await api.bill(id: "119-hconres-14").citation == "H.Con.Res. 14")
        #expect(try await api.nomination(id: "119-pn-1093-3").part == 3)
        let member = try await api.member(id: "A000370")
        #expect(member.member.lastName == "Adams")
        #expect(member.partyLoyalty.votes > 0)
    }

    @Test func honoursTheVoteLimit() async throws {
        #expect(try await api.memberVotes(id: "A000370", limit: 3).votes.count == 3)
    }

    @Test func reportsFreshness() async throws {
        #expect(try await api.status().sources.count == 5)
    }

    @Test func surfacesARealNotFound() async throws {
        do {
            _ = try await api.vote(id: "senate-119-1-9999")
            Issue.record("expected a 404")
        } catch let error as FloorAPIError {
            #expect(error.isNotFound)
            #expect(error.errorDescription?.contains("senate-119-1-9999") == true)
        }
    }
}
