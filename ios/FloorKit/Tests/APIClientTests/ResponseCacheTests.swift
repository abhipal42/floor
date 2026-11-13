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

/// A mutable "server": how the next request is answered, by its URL path.
final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: @Sendable (String) -> Result<Data, URLError>
    init(_ result: Result<Data, URLError>) { answer = { _ in result } }
    func answer(_ result: Result<Data, URLError>) { set { _ in result } }
    func set(_ new: @escaping @Sendable (String) -> Result<Data, URLError>) { lock.lock(); answer = new; lock.unlock() }
    func respond(to path: String) -> Result<Data, URLError> {
        lock.lock()
        let answer = self.answer
        lock.unlock()
        return answer(path)
    }
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
        session: CacheStubProtocol.session { server.respond(to: $0.url?.path ?? "") },
        cache: cache,
        now: { clock.now }
    )
}

/// The real `member-detail` fixture, with the surname swapped so two versions can be told apart.
private func memberDetail(lastName: String) throws -> Data {
    let original = String(decoding: try fixtureData("member-detail"), as: UTF8.self)
    return Data(original.replacingOccurrences(of: "\"Adams\"", with: "\"\(lastName)\"").utf8)
}

private let ten = date("2026-11-12T10:00:00Z")

@MainActor
@Suite("Offline cache", .serialized)
struct ResponseCacheTests {
    /// Shows the saved record at once, says it is refreshing, then replaces it and clears the note.
    @Test func showsTheSavedResponseThenTheFreshOne() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(ten)
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.member(id: "A000370")

        server.answer(.success(try memberDetail(lastName: "Fresh")))
        var shown: [String] = []
        var reports: [SavedCopy?] = []
        try await revalidate(client, report: { reports.append($0) }) { pass in
            shown.append(try await pass.api.member(id: "A000370").member.lastName)
        }
        #expect(shown == ["Saved", "Fresh"])
        #expect(reports == [SavedCopy(savedAt: ten, status: .refreshing), nil])
    }

    /// Offline: the saved record stays on screen, and the note goes from refreshing to offline.
    @Test func keepsTheSavedResponseWhenTheRefreshFails() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(ten)
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.member(id: "A000370")

        clock.set(date("2026-11-12T12:00:00Z"))
        server.answer(.failure(URLError(.notConnectedToInternet)))
        var shown: [String] = []
        var reports: [SavedCopy?] = []
        try await revalidate(client, report: { reports.append($0) }) { pass in
            shown.append(try await pass.api.member(id: "A000370").member.lastName)
        }
        #expect(shown == ["Saved"])
        #expect(reports == [
            SavedCopy(savedAt: ten, status: .refreshing), SavedCopy(savedAt: ten, status: .offline),
        ])
    }

    /// The server answering with an error is not "offline", and the line should not say it is.
    @Test func aServerErrorKeepsTheSavedResponseButIsNotOffline() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.member(id: "A000370")

        server.answer(.success(Data(#"{"error":"Not found"}"#.utf8)))
        var reports: [SavedCopy?] = []
        try await revalidate(client, report: { reports.append($0) }) { pass in
            _ = try await pass.api.member(id: "A000370")
        }
        #expect(reports.last == SavedCopy(savedAt: ten, status: .refreshFailed))
    }

    /// Nothing saved and no network: the error reaches the screen exactly as before the cache.
    @Test func surfacesTheErrorWhenNothingIsSaved() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.failure(URLError(.notConnectedToInternet)))
        let client = api(server, cache: cache, clock: Clock(ten))
        var shown = 0
        var reports: [SavedCopy?] = []
        do {
            try await revalidate(client, report: { reports.append($0) }) { pass in
                _ = try await pass.api.member(id: "A000370")
                shown += 1
            }
            Issue.record("Expected the refresh's error")
        } catch let error as FloorAPIError {
            guard case .transport = error else { Issue.record("Expected transport, got \(error)"); return }
        }
        #expect(shown == 0)
        #expect(reports.isEmpty)
    }

    /// A cancelled request (a pushed screen cancels the tab's task) is not being offline: no
    /// verdict, and `CancellationError` so the screen knows to refresh again later.
    @Test func aCancelledRefreshReportsNoVerdict() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try memberDetail(lastName: "Saved")))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.member(id: "A000370")

        server.answer(.failure(URLError(.cancelled)))
        var reports: [SavedCopy?] = []
        await #expect(throws: CancellationError.self) {
            try await revalidate(client, report: { reports.append($0) }) { pass in
                _ = try await pass.api.member(id: "A000370")
            }
        }
        #expect(reports == [SavedCopy(savedAt: ten, status: .refreshing)])
    }

    /// The main request refreshes but a best-effort one falls back to its saved copy: the screen is
    /// partly saved and the note stays up, dated by that copy.
    @Test func aBestEffortFallbackKeepsTheNoteUp() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let clock = Clock(ten)
        let server = Server(.success(try fixtureData("bill")))
        let client = api(server, cache: cache, clock: clock)
        _ = try await client.bill(id: "119-hconres-14")
        server.answer(.success(try memberDetail(lastName: "Saved")))
        _ = try await client.member(id: "A000370")

        clock.set(date("2026-11-12T12:00:00Z"))
        let member = try memberDetail(lastName: "Fresh")
        server.set { path in path.hasPrefix("/v1/bills") ? .failure(URLError(.timedOut)) : .success(member) }
        var reports: [SavedCopy?] = []
        var bills: [String] = []
        try await revalidate(client, report: { reports.append($0) }) { pass in
            _ = try await pass.api.member(id: "A000370")
            if let bill = await pass.bestEffort({ try await $0.bill(id: "119-hconres-14") }) { bills.append(bill.citation) }
        }
        // The saved pass and the network pass's fallback both drew the saved bill.
        #expect(bills == ["H.Con.Res. 14", "H.Con.Res. 14"])
        #expect(reports.last == SavedCopy(savedAt: ten, status: .offline))
    }

    /// One entry per request, keyed by host, path and query.
    @Test func keysEntriesByHostPathAndQuery() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try fixtureData("member-votes")))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.memberVotes(id: "D000399", limit: 25)
        _ = try await client.memberVotes(id: "D000399", limit: 25)
        #expect(await cache.entries().map(\.key) == ["api.example.test/v1/members/D000399/votes?limit=25"])
    }

    /// A port is part of the host, so a dev server's responses are not a deployment's.
    @Test func keysIncludeThePort() {
        #expect(FloorAPI.cacheKey(URL(string: "http://localhost:8787/v1/bills/119-hr-1")!) == "localhost:8787/v1/bills/119-hr-1")
    }

    /// `&` and `=` inside a value stay encoded, so they cannot read as another parameter.
    @Test func keysKeepQueryValuesEncoded() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try fixtureData("vote-question")))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.vote(id: "house-119-1-1", members: ["A&limit=1"])
        #expect(await cache.entries().map(\.key) == ["api.example.test/v1/votes/house-119-1-1?members=A%26limit%3D1"])
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

    /// Changing district forgets every saved response: they name the old members.
    @Test func clearingForgetsEverySavedResponse() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try fixtureData("member-detail")))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.member(id: "A000370")
        #expect(await cache.entries().count == 1)
        await client.clearSavedResponses()
        #expect(await cache.entries().isEmpty)
    }

    /// The street address goes to `/v1/reps` and nowhere else: not into a key, not into a body.
    @Test func neverStoresTheAddress() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let address = "1600 Pennsylvania Ave NW, Washington DC"
        let reps = #"""
        {"district":{"congress":119,"state":"DC","district":0,"countyFips":"11001"},"members":[]}
        """#
        let server = Server(.success(Data(reps.utf8)))
        let client = api(server, cache: cache, clock: Clock(ten))
        _ = try await client.reps(address: address)

        server.answer(.success(try fixtureData("member-detail")))
        _ = try await client.member(id: "A000370")

        let entries = await cache.entries()
        #expect(entries.map(\.key) == ["api.example.test/v1/members/A000370"])
        for entry in entries {
            #expect(!entry.key.contains("Pennsylvania"))
            #expect(!String(decoding: entry.body, as: UTF8.self).contains("Pennsylvania"))
        }
        // And a saved-only client has nothing to answer the lookup with.
        await #expect(throws: (any Error).self) { try await client.savedOnly()!.api.reps(address: address) }
    }

    /// Nor does the point a location lookup sends: the key would be the coordinates themselves.
    @Test func neverStoresTheCoordinates() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let server = Server(.success(try fixtureData("reps-location-dc")))
        let client = api(server, cache: cache, clock: Clock(ten))
        let reps = try await client.reps(latitude: 38.8977, longitude: -77.0365)
        #expect(reps.members.map(\.lastName) == ["Norton"])
        #expect(await cache.entries().isEmpty)

        server.answer(.success(try fixtureData("member-detail")))
        _ = try await client.member(id: "A000370")
        let entries = await cache.entries()
        #expect(entries.map(\.key) == ["api.example.test/v1/members/A000370"])
        for entry in entries {
            #expect(!entry.key.contains("38.8977"))
            #expect(!entry.key.contains("lat="))
        }
        // And a saved-only client has nothing to answer the lookup with.
        await #expect(throws: (any Error).self) {
            try await client.savedOnly()!.api.reps(latitude: 38.8977, longitude: -77.0365)
        }
    }

    /// Nor does URLSession keep one: the session FloorAPI uses by default has no URLCache, which
    /// would otherwise write `/v1/reps?address=…` to `Caches/Cache.db`.
    @Test func theDefaultSessionHasNoURLCache() {
        let configuration = FloorAPI.defaultSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// A store that will not open is deleted and recreated, not abandoned for good.
    @Test func recoversFromAStoreThatWillNotOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "floor-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "FloorResponses.store")
        try Data("this is not a database".utf8).write(to: url)
        try Data("nor this".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let cache = try #require(SwiftDataResponseCache.onDisk(at: url, policy: CachePolicy()))
        await cache.save(Data("{}".utf8), for: "k", at: ten)
        #expect(await cache.load("k", now: ten) == CachedBody(body: Data("{}".utf8), fetchedAt: ten))
    }

    /// Without a cache there is no saved pass: one request, straight to the network.
    @Test func withoutACacheOnlyTheNetworkIsAsked() async throws {
        let client = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!,
            session: CacheStubProtocol.session { _ in .success(try! fixtureData("member-detail")) }
        )
        #expect(client.savedOnly() == nil)
        var calls = 0
        var reports: [SavedCopy?] = []
        try await revalidate(client, report: { reports.append($0) }) { pass in
            _ = try await pass.api.member(id: "A000370")
            calls += 1
        }
        #expect(calls == 1)
        #expect(reports == [nil])
    }
}
