import Foundation
import Testing
@testable import APIClient
import Models

/// The real staging responses captured in `ModelsTests/Fixtures`, read from the source tree so
/// there is one copy to keep current rather than a second bundle that can fall behind.
func fixtureData(_ name: String) throws -> Data {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // APIClientTests
    dir.deleteLastPathComponent() // Tests
    let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
    return try Data(contentsOf: url)
}

private let base = URL(string: "https://api.example.test")!

/// Serialized because `StubURLProtocol` keeps its responder in shared state.
@Suite("FloorAPI", .serialized)
struct FloorAPITests {
    // MARK: - Request building

    @Test func asksForTheRightURLAndAcceptsJSON() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("status")))
        _ = try await FloorAPI(baseURL: base, session: session).status()

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.absoluteString == "https://api.example.test/v1/status")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// An id is one path segment: a `/` in it is escaped, not read as a separator, and nothing is
    /// encoded twice.
    @Test func anIdCannotAddAPathSegment() async throws {
        let session = StubURLProtocol.session(always: .response(status: 404, body: Data(#"{"error":"no"}"#.utf8)))
        _ = try? await FloorAPI(baseURL: base, session: session).vote(id: "../status")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/votes/..%2Fstatus")

        _ = try? await FloorAPI(baseURL: base, session: session).memberVotes(id: "a b/votes", limit: 1)
        #expect(StubURLProtocol.lastURL?.absoluteString
            == "https://api.example.test/v1/members/a%20b%2Fvotes/votes?limit=1")
        #expect(FloorAPI.escaped("house-119-2-321") == "house-119-2-321")
    }

    @Test func aBaseURLWithAPathKeepsIt() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("status")))
        _ = try await FloorAPI(baseURL: URL(string: "https://api.example.test/api/")!, session: session).status()
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/api/v1/status")
    }

    @Test func passesTheDelegationAsOneCommaSeparatedParameter() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("vote-question")))
        _ = try await FloorAPI(baseURL: base, session: session)
            .vote(id: "house-119-1-100", members: ["A000370", "K000401"])

        let url = try #require(StubURLProtocol.lastURL)
        #expect(url.path == "/v1/votes/house-119-1-100")
        let members = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "members" })?.value
        )
        #expect(members == "A000370,K000401")
    }

    @Test func omitsTheMembersParameterWhenNoneAreAskedFor() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("vote-question")))
        _ = try await FloorAPI(baseURL: base, session: session).vote(id: "house-119-1-100")

        let url = try #require(StubURLProtocol.lastURL)
        #expect(url.query == nil)
        #expect(url.absoluteString == "https://api.example.test/v1/votes/house-119-1-100")
    }

    @Test func escapesAnAddressRatherThanBuildingABrokenURL() async throws {
        let session = StubURLProtocol.session(always: .json("""
        {"district":{"congress":119,"state":"TX","district":37,"countyFips":"48453"},"members":[]}
        """))
        _ = try await FloorAPI(baseURL: base, session: session)
            .reps(address: "1100 Congress Ave, Austin, TX 78701")

        let url = try #require(StubURLProtocol.lastURL)
        #expect(url.path == "/v1/reps")
        // The raw URL must not contain bare spaces, and the value must survive round-tripping.
        #expect(!url.absoluteString.contains(" "))
        let address = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "address" })?.value
        )
        #expect(address == "1100 Congress Ave, Austin, TX 78701")
    }

    /// The phone sends no more precision than the API keeps (4 decimals, ~11 m), and sends the point
    /// as `lat`/`lng` with no address beside it — the API answers 400 to both at once.
    @Test func roundsCoordinatesToFourDecimalsBeforeSendingThem() async throws {
        let session = StubURLProtocol.session(always: .response(
            status: 200, body: try fixtureData("reps-location-austin")
        ))
        let reps = try await FloorAPI(baseURL: base, session: session)
            .reps(latitude: 30.274_712_9, longitude: -97.740_389_6)
        #expect(reps.district.name == "TX-37")

        let url = try #require(StubURLProtocol.lastURL)
        #expect(url.path == "/v1/reps")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["lat", "lng"])
        #expect(items.first { $0.name == "lat" }?.value == "30.2747")
        #expect(items.first { $0.name == "lng" }?.value == "-97.7404")
    }

    @Test func roundsToTheNearestAndPadsToFourPlaces() {
        #expect(FloorAPI.coordinate(41.14) == "41.1400")
        #expect(FloorAPI.coordinate(-0.127_76) == "-0.1278")
        #expect(FloorAPI.coordinate(51.507_449) == "51.5074")
        #expect(FloorAPI.coordinate(0) == "0.0000")
    }

    /// Captured from `/v1/reps?lat=51.5074&lng=-0.1278` (London) on 2026-11-12.
    @Test func reportsAPointOutsideTheUSAsNotFoundWithTheAPIsWording() async throws {
        let session = StubURLProtocol.session(always: .response(
            status: 404, body: try fixtureData("reps-location-london")
        ))
        do {
            _ = try await FloorAPI(baseURL: base, session: session).reps(latitude: 51.5074, longitude: -0.1278)
            Issue.record("expected a 404")
        } catch let error as FloorAPIError {
            #expect(error.isNotFound)
            #expect(error.errorDescription
                == "That location isn't in a U.S. congressional district. Try entering an address instead.")
        }
    }

    /// The parameter names are the contract's, not a guess: read them from `openapi.json`.
    @Test func sendsTheParameterNamesTheContractDeclares() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // APIClientTests, Tests, FloorKit, ios, repo
        let data = try Data(contentsOf: root.appendingPathComponent("apps/api/openapi.json"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = try #require(document["paths"] as? [String: Any])
        let route = try #require((paths["/v1/reps"] as? [String: Any])?["get"] as? [String: Any])
        let parameters = try #require(route["parameters"] as? [[String: Any]])
        let query = Set(parameters.filter { $0["in"] as? String == "query" }.compactMap { $0["name"] as? String })
        #expect(query == ["address", "lat", "lng"])
    }

    @Test func sendsTheVoteLimitItWasGivenAndTwentyByDefault() async throws {
        let body = try fixtureData("member-votes")
        var session = StubURLProtocol.session(always: .response(status: 200, body: body))
        _ = try await FloorAPI(baseURL: base, session: session).memberVotes(id: "A000370")
        var url = try #require(StubURLProtocol.lastURL)
        #expect(url.query == "limit=20")
        #expect(url.path == "/v1/members/A000370/votes")

        session = StubURLProtocol.session(always: .response(status: 200, body: body))
        _ = try await FloorAPI(baseURL: base, session: session).memberVotes(id: "A000370", limit: 5)
        url = try #require(StubURLProtocol.lastURL)
        #expect(url.query == "limit=5")
    }

    @Test func asksForTheFundingRouteWithTenCommitteesByDefault() async throws {
        let body = try fixtureData("funding-J000294")
        var session = StubURLProtocol.session(always: .response(status: 200, body: body))
        let money = try await FloorAPI(baseURL: base, session: session).funding(id: "J000294")
        var url = try #require(StubURLProtocol.lastURL)
        #expect(url.path == "/v1/members/J000294/funding")
        #expect(url.query == "committees=10")
        #expect(money.funding?.committees.count == 10)

        // The API refuses anything outside 0-50, so the client never asks for it.
        session = StubURLProtocol.session(always: .response(status: 200, body: body))
        _ = try await FloorAPI(baseURL: base, session: session).funding(id: "J000294", committees: 500)
        url = try #require(StubURLProtocol.lastURL)
        #expect(url.query == "committees=50")
    }

    @Test func decodesAMemberWithNoCampaignFilings() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("funding-A000383")))
        let money = try await FloorAPI(baseURL: base, session: session).funding(id: "A000383")
        #expect(money.member.lastName == "Armstrong")
        #expect(money.funding == nil)
    }

    /// Saved like the member's record, so the Money tab opens offline on what it last showed.
    @Test func savesTheFundingResponseForOffline() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("funding-C001098")))
        _ = try await FloorAPI(baseURL: base, session: session, cache: cache).funding(id: "C001098")
        let keys = await cache.entries().map(\.key)
        #expect(keys == ["api.example.test/v1/members/C001098/funding?committees=10"])
        let saved = try #require(FloorAPI(baseURL: base, session: session, cache: cache).savedOnly())
        #expect(try await saved.api.funding(id: "C001098").funding?.cycle == 2030)
    }

    // MARK: - Decoding real responses

    @Test func decodesEveryRouteFromARealResponse() async throws {
        let api = { (fixture: String) async throws -> FloorAPI in
            FloorAPI(baseURL: base, session: StubURLProtocol.session(
                always: .response(status: 200, body: try fixtureData(fixture))
            ))
        }
        #expect(try await api("vote-question").vote(id: "house-119-1-100").vote.totals.yea == 216)
        #expect(try await api("bill").bill(id: "119-hconres-14").citation == "H.Con.Res. 14")
        #expect(try await api("nomination-split").nomination(id: "119-pn-1093-3").part == 3)
        #expect(try await api("member-detail").member(id: "A000370").partyLoyalty.votes == 1871)
        #expect(try await api("member-votes").memberVotes(id: "A000370").votes.isEmpty == false)
        #expect(try await api("status").status().sources.count == 5)
    }

    @Test func carriesTheBreakdownThroughToTheCaller() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("vote-question")))
        let detail = try await FloorAPI(baseURL: base, session: session).vote(id: "house-119-1-100")
        #expect(detail.partyTotals.map(\.party) == ["R", "D"])
        #expect(detail.positions.map(\.member.lastName) == ["Adams", "Kiley"])
    }

    // MARK: - Failures

    @Test func reportsTheAPIsOwnWordingForA404() async throws {
        let session = StubURLProtocol.session(always: .json(
            #"{"error":"No vote with ID senate-119-1-9999"}"#, status: 404
        ))
        await #expect(throws: FloorAPIError.self) {
            _ = try await FloorAPI(baseURL: base, session: session).vote(id: "senate-119-1-9999")
        }
        do {
            _ = try await FloorAPI(baseURL: base, session: session).vote(id: "senate-119-1-9999")
            Issue.record("expected a 404")
        } catch let error as FloorAPIError {
            #expect(error.isNotFound)
            guard case let .http(status, message) = error else { Issue.record("wrong case"); return }
            #expect(status == 404)
            // The API phrases 4xx for people; a screen should be able to show it as-is.
            #expect(message == "No vote with ID senate-119-1-9999")
            #expect(error.errorDescription == "No vote with ID senate-119-1-9999")
        }
    }

    @Test func keepsTheStatusWhenAnErrorBodyIsNotTheAPIs() async throws {
        // e.g. a proxy or load balancer returning HTML.
        let session = StubURLProtocol.session(always: .json("<html>502 Bad Gateway</html>", status: 502))
        do {
            _ = try await FloorAPI(baseURL: base, session: session).status()
            Issue.record("expected a 502")
        } catch let error as FloorAPIError {
            guard case let .http(status, message) = error else { Issue.record("wrong case"); return }
            #expect(status == 502)
            #expect(message == nil)
            #expect(error.isNotFound == false)
            #expect(error.errorDescription?.contains("502") == true)
        }
    }

    @Test func distinguishesBeingOfflineFromABadResponse() async throws {
        let session = StubURLProtocol.session(always: .failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await FloorAPI(baseURL: base, session: session).status()
            Issue.record("expected a transport failure")
        } catch let error as FloorAPIError {
            guard case .transport = error else { Issue.record("wrong case: \(error)"); return }
            #expect(error.isNotFound == false)
            #expect(error.errorDescription?.contains("connection") == true)
        }
    }

    @Test func reportsABodyThatDoesNotMatchTheContract() async throws {
        let session = StubURLProtocol.session(always: .json(#"{"totally":"unexpected"}"#))
        do {
            _ = try await FloorAPI(baseURL: base, session: session).status()
            Issue.record("expected a decoding failure")
        } catch let error as FloorAPIError {
            guard case .decoding = error else { Issue.record("wrong case: \(error)"); return }
        }
    }

    @Test func doesNotTreatA404BodyAsAResult() async throws {
        // A 404 body still parses as JSON, so the status must be checked before decoding.
        let session = StubURLProtocol.session(always: .json(#"{"error":"No bill with ID 119-hr-404"}"#, status: 404))
        do {
            _ = try await FloorAPI(baseURL: base, session: session).bill(id: "119-hr-404")
            Issue.record("expected a 404")
        } catch let error as FloorAPIError {
            #expect(error.isNotFound)
        }
    }
}
