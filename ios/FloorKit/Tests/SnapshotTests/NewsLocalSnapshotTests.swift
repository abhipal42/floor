#if os(iOS)
import APIClient
import DesignSystem
import Foundation
import Home
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing

/// FixtureServer's routes plus v0.2.60's: Schumer's and Gillibrand's news, and the Local routes.
/// A server of its own, so the older suites' member pages draw exactly as they were recorded.
final class NewsLocalServer: URLProtocol {
    static let routes: [String: String] = FixtureServer.routes.merging([
        "/v1/members/S000148/news": "news-schumer-2026-11-17",
        "/v1/members/G000555/news": "news-gillibrand-2026-11-17",
        "/v1/local": "local-jurisdictions",
        "/v1/local/ny": "local-ny-2026-11-17",
        "/v1/local/nyc": "local-nyc-2026-11-17",
        "/v1/local/seattle": "local-seattle-2026-11-17",
        "/v1/local/houston": "local-houston-empty",
        "/v1/local/ny/legislators": "local-ny-legislators-sd59",
    ]) { _, new in new }

    static var api: FloorAPI { FixtureServer.api(NewsLocalServer.self) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.routes[url.path].flatMap { try? fixtureData($0) }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A Manhattan district stored before v0.2.60 (no state districts yet) whose city is New York.
private let manhattanOld = District(congress: 119, state: "NY", district: 10, countyFips: "36061")

/// v0.2.60 (https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW): the News page (option B) and the
/// Local tab (option A). Real headlines, polls and items from Nov 10–17 2026; the tones and stories
/// are hand-labelled in the fixtures, standing in for the worker's AI read.
@MainActor
@Suite("News and Local snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct NewsLocalSnapshotTests {
    init() { _ = NoPortraits.installed }

    private func news(_ id: String) async throws -> (NewsModel, Member) {
        let model = RepScreenModel(bioguideId: id, api: NewsLocalServer.api)
        await model.load()
        await model.news.load()
        return (model.news, try #require(model.member))
    }

    /// Schumer: two stories (the leadership fight, 20; the polls about it, 2), three others, then
    /// three polls, one with no third share.
    @Test func newsPageSchumer() async throws {
        let (model, member) = try await news("S000148")
        assertScreen(NavigationStack { NewsPage(model: model, member: member) }, height: 1650)
    }

    /// Gillibrand: not AI-read, so a plain list with no chips or bars; her office's release tagged;
    /// no poll has named her.
    @Test func newsPageGillibrand() async throws {
        let (model, member) = try await news("G000555")
        assertScreen(NavigationStack { NewsPage(model: model, member: member) }, height: 1400)
    }

    /// The member page with News between Posts and Money.
    @Test func memberPageNews() async throws {
        let model = RepScreenModel(bioguideId: "S000148", api: NewsLocalServer.api)
        await model.load()
        await model.promises.load()
        await model.posts.load()
        await model.money.load()
        await model.news.load()
        let view = NavigationStack {
            RepScreenView(model: model, follows: Follows(store: InMemoryFollowStore()), reps: ["S000148"])
        }
        .environment(\.pinnedNow, Formats.instant("2026-11-17T17:00:00.000Z"))
        assertScreen(view, height: 2450, [.dark])
    }

    private func local(selected: String) async -> LocalModel {
        let model = LocalModel(district: manhattanOld, api: NewsLocalServer.api, cities: InMemoryLocalCityStore(["nyc"]))
        await model.loadList()
        await model.loadHub("ny")
        await model.loadHub("nyc")
        model.selected = selected
        return model
    }

    /// New York State: signed into law, waiting on the governor, the news, and the dashed card asking
    /// for the address again (this district was stored before state districts were looked up).
    @Test func localNewYorkState() async {
        let model = await local(selected: "ny")
        assertScreen(NavigationStack { LocalView(model: model, onOpenCities: {}, onFindReps: {}, onChangeAddress: {}) }, height: 2750)
    }

    /// New York City: Int. 891-A with its 44–5 tally, then the news.
    @Test func localNewYorkCity() async {
        let model = await local(selected: "nyc")
        assertScreen(NavigationStack { LocalView(model: model, onOpenCities: {}, onFindReps: {}, onChangeAddress: {}) }, height: 1700)
    }

    /// A news-only city with nothing in it: the coverage note and "Nothing from Houston …".
    @Test func localEmptyCity() async {
        let model = LocalModel(district: manhattanOld, api: NewsLocalServer.api, cities: InMemoryLocalCityStore(["houston"]))
        await model.loadList()
        await model.loadHub("houston")
        model.selected = "houston"
        assertScreen(NavigationStack { LocalView(model: model, onOpenCities: {}, onFindReps: {}, onChangeAddress: {}) }, height: 520, [.light, .dark])
    }

    /// No district at all: the one card asking for the address.
    @Test func localNoDistrict() async {
        let model = LocalModel(district: nil, api: NewsLocalServer.api, cities: InMemoryLocalCityStore())
        assertScreen(NavigationStack { LocalView(model: model, onOpenCities: {}, onFindReps: {}, onChangeAddress: {}) }, height: 420, [.dark])
    }

    /// Every registry city with its badge; New York City added.
    @Test func citiesScreen() async {
        let model = LocalModel(district: manhattanOld, api: NewsLocalServer.api, cities: InMemoryLocalCityStore(["nyc"]))
        await model.loadList()
        assertScreen(NavigationStack { CitiesView(model: model) }, height: 900)
    }
}
#endif
