import Foundation
import Testing
@testable import APIClient
import Models

private let base = URL(string: "https://api.example.test")!

/// Round 13's routes. In `FloorAPITests` (an extension), so they share its serialization: the stub
/// keeps its responder in shared state.
extension FloorAPITests {
    @Test func asksForAMembersPromises() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("promises-slotkin")))
        let said = try await FloorAPI(baseURL: base, session: session).promises(id: "S001208")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/members/S001208/promises")
        #expect(said.promises.count == 3)
    }

    /// An API without the route yet: not checked, and saved as such for offline.
    @Test func anAPIWithoutPromisesReadsAsUnchecked() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let session = StubURLProtocol.session(always: .json(#"{"error":"Not found"}"#, status: 404))
        let api = FloorAPI(baseURL: base, session: session, cache: cache)
        #expect(try await api.promises(id: "S001208").status == .unchecked)
        let offline = try #require(api.savedOnly())
        #expect(try await offline.api.promises(id: "S001208").status == .unchecked)
    }

    @Test func asksForAMembersPostsAndSavesThem() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("posts-schumer")))
        let api = FloorAPI(baseURL: base, session: session, cache: cache)
        let posts = try await api.posts(id: "S000148")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/members/S000148/posts")
        #expect(posts.posts.count == 3)
        let offline = try #require(api.savedOnly())
        #expect(try await offline.api.posts(id: "S000148") == posts)
    }

    @Test func anAPIWithoutPostsReadsAsNone() async throws {
        let session = StubURLProtocol.session(always: .json(#"{"error":"Not found"}"#, status: 404))
        #expect(try await FloorAPI(baseURL: base, session: session).posts(id: "S000148") == .none)
    }

    /// The wall asks for at most 12 members, in your order; none is no request.
    @Test func theWallAsksForTwelveMembersAtMost() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("posts-wall-schumer-nadler")))
        let api = FloorAPI(baseURL: base, session: session)
        #expect(try await api.posts(members: []) == .none)
        #expect(StubURLProtocol.requests.isEmpty)

        let ids = (1...14).map { String(format: "A%06d", $0) }
        _ = try await api.posts(members: ids)
        let url = try #require(StubURLProtocol.lastURL)
        let members = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "members" }?.value
        #expect(url.path == "/v1/posts")
        #expect(members == ids.prefix(12).joined(separator: ","))
    }
}
