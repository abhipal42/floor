import APIClient
import Foundation
import Models
import Testing
@testable import RepScreen

/// Answers every request from the captured fixtures, or fails it as `mode` says.
final class FixtureProtocol: URLProtocol {
    enum Mode: Sendable {
        case online
        case offline
        /// What a task cancelled mid-request sees: a pushed screen, a tab switched away.
        case cancelled
        /// Offline, but only after a delay — a refresh still in flight on weak signal.
        case slowOffline
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Mode = .online

    static var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
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
        switch Self.mode {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .cancelled:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .slowOffline:
            nonisolated(unsafe) let this = self
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                this.client?.urlProtocol(this, didFailWithError: URLError(.notConnectedToInternet))
            }
        case .online:
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
    }

    override func stopLoading() {}
}

private let fetchedAt = ISO8601DateFormatter().date(from: "2026-11-12T09:30:00Z")!

@MainActor
@Suite("Rep screen offline", .serialized)
struct RepScreenOfflineTests {
    private let cache: SwiftDataResponseCache
    private let api: FloorAPI

    init() throws {
        cache = try SwiftDataResponseCache.inMemory()
        api = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!, session: FixtureProtocol.session(),
            cache: cache, now: { fetchedAt }
        )
        FixtureProtocol.mode = .online
    }

    /// One launch online, so the next has something saved.
    private func seed() async {
        FixtureProtocol.mode = .online
        await RepScreenModel(bioguideId: "A000370", api: api).load()
    }

    /// A second launch with no network opens on the record the first one saw.
    @Test func opensOnTheSavedRecordWhenOffline() async throws {
        await seed()
        FixtureProtocol.mode = .offline
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        await model.load()
        guard case let .loaded(record) = model.phase else {
            Issue.record("Expected the saved record, got \(model.phase)")
            return
        }
        // Alma Adams and her three votes, as captured in the fixtures.
        #expect(record.detail.member.lastName == "Adams")
        #expect(record.votes.count == 3)
        #expect(model.saved == SavedCopy(savedAt: fetchedAt, status: .offline))
        #expect(model.needsRefresh)
    }

    /// Nothing saved and no network: the screen's existing error state, unchanged.
    @Test func failsAsBeforeWhenNothingIsSaved() async throws {
        FixtureProtocol.mode = .offline
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        await model.load()
        #expect(model.phase == .failed("Couldn't reach Floor. Check your connection and try again."))
        #expect(model.saved == nil)
    }

    /// A refresh cancelled part-way is not "offline", and the screen refreshes when it reappears.
    @Test func aCancelledRefreshIsNotOfflineAndRunsAgain() async throws {
        await seed()
        FixtureProtocol.mode = .cancelled
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        await model.load()
        #expect(model.saved == SavedCopy(savedAt: fetchedAt, status: .refreshing))
        #expect(model.needsRefresh)

        FixtureProtocol.mode = .online
        await model.load()
        #expect(model.saved == nil)
        #expect(!model.needsRefresh)
    }

    /// Saved data never passes for fresh: while the network pass is out, the note says so.
    @Test func saysItIsRefreshingWhileTheNetworkPassRuns() async throws {
        await seed()
        FixtureProtocol.mode = .slowOffline
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        let load = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.saved == SavedCopy(savedAt: fetchedAt, status: .refreshing))
        await load.value
        #expect(model.saved == SavedCopy(savedAt: fetchedAt, status: .offline))
    }

    /// A slow load overtaken by a newer one (pull-to-refresh beside the screen's own task) must not
    /// write its "offline" over the newer load's fresh record.
    @Test func anOvertakenLoadDropsItsResult() async throws {
        await seed()
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        FixtureProtocol.mode = .slowOffline
        let slow = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(150))
        FixtureProtocol.mode = .online
        await model.load()
        #expect(model.saved == nil)
        await slow.value
        #expect(model.saved == nil)
        guard case .loaded = model.phase else {
            Issue.record("Expected the fresh record, got \(model.phase)")
            return
        }
    }

    /// A failed load leaves no note from an earlier one behind.
    @Test func aFailedLoadClearsAnEarlierNote() async throws {
        await seed()
        FixtureProtocol.mode = .offline
        let model = RepScreenModel(bioguideId: "A000370", api: api)
        await model.load()
        #expect(model.saved?.status == .offline)

        await cache.removeAll()
        await model.load()
        #expect(model.phase == .failed("Couldn't reach Floor. Check your connection and try again."))
        #expect(model.saved == nil)
    }
}
