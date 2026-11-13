import APIClient
import Foundation
import Testing
@testable import RepScreen

/// Answers every request from the captured fixtures, or fails every one while `offline` is set.
final class FixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var isOffline = false

    static var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isOffline }
        set { lock.lock(); isOffline = newValue; lock.unlock() }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let name = url.path.hasSuffix("/votes") ? "member-votes" : "member-detail"
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent() // RepScreenTests
        dir.deleteLastPathComponent() // Tests
        let body = (try? Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let fetchedAt = ISO8601DateFormatter().date(from: "2026-11-12T09:30:00Z")!

@MainActor
@Suite("Rep screen offline", .serialized)
struct RepScreenOfflineTests {
    /// A second launch with no network opens on the record the first one saw.
    @Test func opensOnTheSavedRecordWhenOffline() async throws {
        let cache = try SwiftDataResponseCache.inMemory()
        let api = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!, session: FixtureProtocol.session(),
            cache: cache, now: { fetchedAt }
        )
        FixtureProtocol.offline = false
        let first = RepScreenModel(bioguideId: "A000370", api: api)
        await first.load()
        #expect(first.saved == nil)

        FixtureProtocol.offline = true
        defer { FixtureProtocol.offline = false }
        let second = RepScreenModel(bioguideId: "A000370", api: api)
        await second.load()
        guard case let .loaded(record) = second.phase else {
            Issue.record("Expected the saved record, got \(second.phase)")
            return
        }
        // Alma Adams and her three votes, as captured in the fixtures.
        #expect(record.detail.member.lastName == "Adams")
        #expect(record.votes.count == 3)
        #expect(second.saved == SavedCopy(savedAt: fetchedAt, offline: true))
    }

    /// Nothing saved and no network: the screen's existing error state, unchanged.
    @Test func failsAsBeforeWhenNothingIsSaved() async throws {
        let api = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!, session: FixtureProtocol.session(),
            cache: try SwiftDataResponseCache.inMemory()
        )
        FixtureProtocol.offline = true
        defer { FixtureProtocol.offline = false }
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        await model.load()
        #expect(model.phase == .failed("Couldn't reach Floor. Check your connection and try again."))
        #expect(model.saved == nil)
    }
}
