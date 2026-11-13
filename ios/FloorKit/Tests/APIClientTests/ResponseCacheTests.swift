import Foundation
import Testing
@testable import APIClient
import Models

/// Its own stub rather than `StubURLProtocol`, because that one's state is shared with the
/// `FloorAPI` suite and Swift Testing runs the two suites in parallel.
final class CacheStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (URLRequest) -> Result<Data, URLError>)?

    static func session(_ responder: @escaping @Sendable (URLRequest) -> Result<Data, URLError>) -> URLSession {
        lock.lock()
        self.responder = responder
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responder = Self.responder
        Self.lock.unlock()
        guard let responder, let url = request.url else { return }
        switch responder(request) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .success(body):
            // A 404 body is the API's `{ "error": ... }`; anything else is a 200.
            let status = String(decoding: body, as: UTF8.self).hasPrefix("{\"error\"") ? 404 : 200
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A mutable "server": what the next request gets back.
final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Result<Data, URLError>
    init(_ next: Result<Data, URLError>) { self.next = next }
    func answer(_ result: Result<Data, URLError>) { lock.lock(); next = result; lock.unlock() }
    var current: Result<Data, URLError> { lock.lock(); defer { lock.unlock() }; return next }
}

/// A clock the test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func set(_ new: Date) { lock.lock(); date = new; lock.unlock() }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
}

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

private func api(_ server: Server, cache: SwiftDataResponseCache, clock: Clock) -> FloorAPI {
    FloorAPI(
        baseURL: URL(string: "https://api.example.test")!,
        session: CacheStubProtocol.session { _ in server.current },
        cache: cache,
        now: { clock.now }
    )
}

/// The real `member-detail` fixture, with the surname swapped so two versions can be told apart.
private func memberDetail(lastName: String) throws -> Data {
    let original = String(decoding: try fixtureData("member-detail"), as: UTF8.self)
    return Data(original.replacingOccurrences(of: "\"Adams\"", with: "\"\(lastName)\"").utf8)
}

@MainActor
@Suite("Offline cache", .serialized)
struct ResponseCacheTests {
    /// Shows the saved record at once, then replaces it with the fresh one.
    @Test func showsTheSavedResponseThenTheFreshOne() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(date("2026-11-12T10:00:00Z"))
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.member(id: "A000370")

        server.answer(.success(try memberDetail(lastName: "Fresh")))
        var shown: [String] = []
        let saved = try await revalidate(client) { api in
            shown.append(try await api.member(id: "A000370").member.lastName)
        }
        #expect(shown == ["Saved", "Fresh"])
        #expect(saved == nil)
    }

    /// Offline: the saved record stays on screen, dated by when it was fetched.
    @Test func keepsTheSavedResponseWhenTheRefreshFails() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(date("2026-11-12T10:00:00Z"))
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.member(id: "A000370")

        clock.set(date("2026-11-12T12:00:00Z"))
        server.answer(.failure(URLError(.notConnectedToInternet)))
        var shown: [String] = []
        let saved = try await revalidate(client) { api in
            shown.append(try await api.member(id: "A000370").member.lastName)
        }
        #expect(shown == ["Saved"])
        #expect(saved == SavedCopy(savedAt: date("2026-11-12T10:00:00Z"), offline: true))
    }

    /// The server answering with an error is not "offline", and the line should not say it is.
    @Test func aServerErrorKeepsTheSavedResponseButIsNotOffline() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(date("2026-11-12T10:00:00Z"))
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.member(id: "A000370")

        server.answer(.success(Data(#"{"error":"Not found"}"#.utf8)))
        let saved = try await revalidate(client) { api in _ = try await api.member(id: "A000370") }
        #expect(saved == SavedCopy(savedAt: date("2026-11-12T10:00:00Z"), offline: false))
    }

    /// Nothing saved and no network: the error reaches the screen exactly as before the cache.
    @Test func surfacesTheErrorWhenNothingIsSaved() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.failure(URLError(.notConnectedToInternet)))
        let client = api(server, cache: cache, clock: Clock(date("2026-11-12T10:00:00Z")))
        var shown = 0
        do {
            _ = try await revalidate(client) { api in
                _ = try await api.member(id: "A000370")
                shown += 1
            }
            Issue.record("Expected the refresh's error")
        } catch let error as FloorAPIError {
            guard case .transport = error else { Issue.record("Expected transport, got \(error)"); return }
        }
        #expect(shown == 0)
    }

    /// One entry per request, keyed by path and query without the origin.
    @Test func keysEntriesByPathAndQuery() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(date("2026-11-12T10:00:00Z"))
        let server = Server(.success(try fixtureData("member-votes")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.memberVotes(id: "D000399", limit: 25)
        _ = try await client.memberVotes(id: "D000399", limit: 25)
        #expect(await cache.entries().map(\.key) == ["/v1/members/D000399/votes?limit=25"])
    }

    /// Beyond `maxEntries`, the oldest go first.
    @Test func evictsTheOldestBeyondTheEntryLimit() async throws {
        let cache = try SwiftDataResponseCache.inMemory(policy: CachePolicy(maxAge: 30 * 86_400, maxEntries: 2))
        let body = Data("{}".utf8)
        await cache.save(body, for: "a", at: date("2026-11-10T10:00:00Z"))
        await cache.save(body, for: "b", at: date("2026-11-11T10:00:00Z"))
        await cache.save(body, for: "c", at: date("2026-11-12T10:00:00Z"))
        #expect(await cache.entries().map(\.key) == ["c", "b"])
        // Refreshing an old key makes it the newest rather than adding a row.
        await cache.save(body, for: "b", at: date("2026-11-12T11:00:00Z"))
        #expect(await cache.entries().map(\.key) == ["b", "c"])
    }

    /// Past `maxAge` an entry is neither served nor kept.
    @Test func dropsEntriesPastTheirAge() async throws {
        let cache = try SwiftDataResponseCache.inMemory(policy: CachePolicy(maxAge: 86_400, maxEntries: 200))
        let body = Data("{}".utf8)
        await cache.save(body, for: "old", at: date("2026-11-10T10:00:00Z"))
        #expect(await cache.load("old", now: date("2026-11-10T20:00:00Z")) != nil)
        #expect(await cache.load("old", now: date("2026-11-11T10:00:01Z")) == nil)
        #expect(await cache.entries().isEmpty)

        await cache.save(body, for: "old", at: date("2026-11-10T10:00:00Z"))
        await cache.save(body, for: "new", at: date("2026-11-12T10:00:00Z"))
        #expect(await cache.entries().map(\.key) == ["new"])
    }

    /// The street address goes to `/v1/reps` and nowhere else: not into a key, not into a body.
    @Test func neverStoresTheAddress() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(date("2026-11-12T10:00:00Z"))
        let address = "1600 Pennsylvania Ave NW, Washington DC"
        let reps = #"""
        {"district":{"congress":119,"state":"DC","district":0,"countyFips":"11001"},"members":[]}
        """#
        let server = Server(.success(Data(reps.utf8)))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.reps(address: address)

        server.answer(.success(try fixtureData("member-detail")))
        _ = try await client.member(id: "A000370")

        let entries = await cache.entries()
        #expect(entries.map(\.key) == ["/v1/members/A000370"])
        for entry in entries {
            #expect(!entry.key.contains("Pennsylvania"))
            #expect(!String(decoding: entry.body, as: UTF8.self).contains("Pennsylvania"))
        }
        // And a saved-only client has nothing to answer the lookup with.
        await #expect(throws: (any Error).self) { try await client.savedOnly()!.api.reps(address: address) }
    }

    /// Without a cache there is no saved pass: one request, straight to the network.
    @Test func withoutACacheOnlyTheNetworkIsAsked() async throws {
        let client = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!,
            session: CacheStubProtocol.session { _ in .success(try! fixtureData("member-detail")) }
        )
        #expect(client.savedOnly() == nil)
        var calls = 0
        let saved = try await revalidate(client) { api in
            _ = try await api.member(id: "A000370")
            calls += 1
        }
        #expect(calls == 1)
        #expect(saved == nil)
    }
}
