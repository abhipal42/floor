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
            let name = url.path.hasSuffix("/votes") ? "member-votes"
                // Every member's money is Jeffries' capture, except the appointed senator with none.
                : url.path.hasSuffix("A000383/funding") ? "funding-A000383"
                : url.path.hasSuffix("/funding") ? "funding-J000294" : "member-detail"
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

    // MARK: - Money (`/v1/members/{id}/funding`)

    @Test func loadsTheMembersMoney() async throws {
        let model = MoneyModel(bioguideId: "J000294", api: api)
        #expect(model.phase == .loading)
        await model.load()
        guard case let .loaded(body) = model.phase else {
            Issue.record("Expected the funding, got \(model.phase)")
            return
        }
        #expect(body.member.lastName == "Jeffries")
        #expect(body.funding.map { MoneyFormat.total($0.receipts) } == "$17.9M")
        #expect(model.saved == nil)
        #expect(!model.needsRefresh)
    }

    /// Opened offline, the Money segment shows what it last saw, and says it is saved.
    @Test func opensOnTheSavedMoneyWhenOffline() async throws {
        FixtureProtocol.mode = .online
        await MoneyModel(bioguideId: "J000294", api: api).load()
        FixtureProtocol.mode = .offline
        let model = MoneyModel(bioguideId: "J000294", api: api)
        await model.load()
        guard case .loaded = model.phase else {
            Issue.record("Expected the saved funding, got \(model.phase)")
            return
        }
        #expect(model.saved == SavedCopy(savedAt: fetchedAt, status: .offline))
        #expect(model.needsRefresh)
    }

    @Test func moneyFailsVisiblyWhenNothingIsSaved() async throws {
        FixtureProtocol.mode = .offline
        let model = MoneyModel(bioguideId: "J000294", api: api)
        await model.load()
        #expect(model.phase == .failed("Couldn't reach Floor. Check your connection and try again."))
        #expect(model.needsRefresh)
    }

    /// No current campaign is an answer, not an error: the segment says so.
    @Test func aMemberWithNoFilingsLoadsAsNoFunding() async throws {
        let model = MoneyModel(bioguideId: "A000383", api: api)
        await model.load()
        guard case let .loaded(body) = model.phase else {
            Issue.record("Expected an answer, got \(model.phase)")
            return
        }
        #expect(body.funding == nil)
        #expect(body.noFilings.title == "No campaign filings yet")
    }

    /// The pushed member screen names its header from the money when the record never loaded.
    @Test func theScreenKnowsWhoItIsFromEitherHalf() async throws {
        FixtureProtocol.mode = .offline
        let model = RepScreenModel(bioguideId: "J000294", api: api)
        await model.load()
        #expect(model.member == nil)
        FixtureProtocol.mode = .online
        await model.money.load()
        #expect(model.member?.lastName == "Jeffries")
        await model.load()
        #expect(model.member?.lastName == "Adams") // the record's own member wins once it loads
    }

    /// The picked grid square lives on the model, so a trip to Money and back (which rebuilds the
    /// record view) keeps it, and a reload keeps it too.
    @Test func thePickedCallSurvivesASectionSwitch() async throws {
        let three = YourThreeModel(members: [.sample], api: api)
        let record = try #require(three.selected)
        await record.load()
        record.selectedCall = 1
        three.section = .money
        three.section = .record
        #expect(three.selected?.selectedCall == 1)
        await record.load()
        #expect(record.selectedCall == 1)
    }

    /// Switching member keeps the segment, so you can compare your members' money.
    @Test func yourThreeKeepsTheSectionAcrossMembers() {
        let three = YourThreeModel(members: [.sample, .sampleSenator], api: api)
        #expect(three.section == .record)
        three.section = .money
        three.selectedId = Member.sampleSenator.bioguideId
        #expect(three.section == .money)
        #expect(three.selected?.money.phase == .loading) // not fetched until the segment is shown
        #expect(MemberSection.allCases.map(\.rawValue) == ["Record", "Money", "Portfolio"])
    }
}
