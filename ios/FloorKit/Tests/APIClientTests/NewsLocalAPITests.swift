import Foundation
import Testing
@testable import APIClient
import Models

private let base = URL(string: "https://api.example.test")!

/// v0.2.60's routes. In `FloorAPITests` (an extension), so they share its serialization.
extension FloorAPITests {
    @Test func asksForAMembersNewsAndSavesIt() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("news-schumer-2026-11-17")))
        let api = FloorAPI(baseURL: base, session: session, cache: cache)
        let news = try await api.memberNews(id: "S000148")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/members/S000148/news")
        #expect(news.headlines.count == 25)
        let offline = try #require(api.savedOnly())
        #expect(try await offline.api.memberNews(id: "S000148") == news)
    }

    /// An API without the route yet: no news, saved as such, so the section stays out offline too.
    @Test func anAPIWithoutNewsReadsAsNone() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let session = StubURLProtocol.session(always: .json(#"{"error":"Not found"}"#, status: 404))
        let api = FloorAPI(baseURL: base, session: session, cache: cache)
        #expect(try await api.memberNews(id: "S000148").isEmpty)
        let offline = try #require(api.savedOnly())
        #expect(try await offline.api.memberNews(id: "S000148").isEmpty)
    }

    @Test func asksForTheRegistryAndAHub() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("local-nyc-2026-11-17")))
        let api = FloorAPI(baseURL: base, session: session)
        let hub = try await api.localHub(id: "nyc")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/local/nyc")
        #expect(hub.jurisdiction.name == "New York City")

        let missing = StubURLProtocol.session(always: .json(#"{"error":"Not found"}"#, status: 404))
        #expect(try await FloorAPI(baseURL: base, session: missing).localJurisdictions().jurisdictions.isEmpty)
        // An unknown hub is an error, not an empty hub.
        await #expect(throws: FloorAPIError.self) { try await FloorAPI(baseURL: base, session: missing).localHub(id: "atlantis") }
    }

    /// The legislators are asked for by the stored district codes; with none, no request is made.
    @Test func asksForStateLegislatorsByDistrict() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("local-ny-legislators-sd59")))
        let api = FloorAPI(baseURL: base, session: session)
        #expect(try await api.stateLegislators(state: "NY", upper: nil, lower: nil) == .none)
        #expect(StubURLProtocol.requests.isEmpty)

        let found = try await api.stateLegislators(state: "NY", upper: "59", lower: "74")
        let url = try #require(StubURLProtocol.lastURL)
        #expect(url.path == "/v1/local/ny/legislators")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.map(\.name) == ["upper", "lower"])
        #expect(query.map(\.value) == ["59", "74"])
        #expect(found.legislators.map(\.name) == ["Kristen Gonzalez"])
    }
}
