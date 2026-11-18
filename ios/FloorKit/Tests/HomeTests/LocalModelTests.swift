import APIClient
import Foundation
import Models
import Testing
@testable import Home

/// Answers the Local routes from the v0.2.60 fixtures; anything else is the API's 404. The table is
/// constant, so parallel tests cannot disturb each other.
private final class LocalServer: URLProtocol {
    static let routes: [String: String] = [
        "/v1/local": "local-jurisdictions",
        "/v1/local/ny": "local-ny-2026-11-17",
        "/v1/local/nyc": "local-nyc-2026-11-17",
        "/v1/local/houston": "local-houston-empty",
        "/v1/local/ny/legislators": "local-ny-legislators-sd59",
    ]

    static var api: FloorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalServer.self]
        return FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: URLSession(configuration: configuration))
    }

    static func data(_ name: String) -> Data? {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        return try? Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.routes[url.path].flatMap(Self.data)
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A Manhattan district as a v0.2.60 lookup stores it: NY-10, State Senate 59, New York city.
private let manhattan = District(congress: 119, state: "NY", district: 10, countyFips: "36061", stateUpper: "59",
                                 stateLower: nil, place: .init(geoid: "3651000", name: "New York city"))
/// The same district stored before v0.2.60.
private let manhattanOld = District(congress: 119, state: "NY", district: 10, countyFips: "36061")

@MainActor
@Suite("Local tab")
struct LocalModelTests {
    /// Your state first; your Census place is your city until you change it.
    @Test func yourStateThenYourPlace() async {
        let model = LocalModel(district: manhattan, api: LocalServer.api, cities: InMemoryLocalCityStore())
        #expect(model.hubIds == ["ny"]) // the place is matched once the registry is in
        await model.loadList()
        #expect(model.hubIds == ["ny", "nyc"])
        #expect(model.hubIds.map(model.name) == ["New York State", "New York City"])
        #expect(model.current == "ny")
    }

    /// Adding and removing cities is kept, and an empty choice stays empty (no default comes back).
    @Test func citiesAreSaved() async throws {
        let store = InMemoryLocalCityStore()
        let model = LocalModel(district: manhattan, api: LocalServer.api, cities: store)
        await model.loadList()
        let houston = try #require(model.registry.cities.first { $0.id == "houston" })
        let nyc = try #require(model.jurisdiction("nyc"))
        model.toggle(houston)
        #expect(store.load() == ["nyc", "houston"])
        model.toggle(nyc)
        model.toggle(houston)
        #expect(store.load() == [])
        let again = LocalModel(district: manhattan, api: LocalServer.api, cities: store)
        await again.loadList()
        #expect(again.hubIds == ["ny"])
    }

    @Test func noPlaceNoCityAndOldDistrictsAskAgain() async {
        let model = LocalModel(district: manhattanOld, api: LocalServer.api, cities: InMemoryLocalCityStore())
        await model.loadList()
        #expect(model.hubIds == ["ny"])
        #expect(!model.hasStateDistricts)
        await model.loadLegislators()
        #expect(model.legislators.isEmpty)
        #expect(LocalText.needDistricts(state: "NY")
            == "Look up your address again to see your state senator and Assembly member.")
    }

    @Test func loadsHubsAndLegislators() async {
        let model = LocalModel(district: manhattan, api: LocalServer.api, cities: InMemoryLocalCityStore())
        await model.loadHub("nyc")
        guard case let .loaded(hub) = model.hub("nyc") else { Issue.record("nyc did not load"); return }
        #expect(hub.enacted.first?.tally?.yes == 44)
        await model.loadHub("atlantis")
        if case .failed = model.hub("atlantis") {} else { Issue.record("an unknown hub should fail") }
        await model.loadLegislators()
        #expect(model.legislators.map(\.name) == ["Kristen Gonzalez"])
    }

    /// D.C. has no state legislature: no state hub, and no city until one is added.
    @Test func noStateHubForDC() async {
        let dc = District(congress: 119, state: "DC", district: 0, countyFips: "11001")
        let model = LocalModel(district: dc, api: LocalServer.api, cities: InMemoryLocalCityStore())
        await model.loadList()
        #expect(model.stateId == nil)
        #expect(model.hubIds.isEmpty)
        #expect(LocalModel(district: nil, api: LocalServer.api, cities: InMemoryLocalCityStore()).hubIds.isEmpty)
    }

    @Test func coverageWords() throws {
        let houston = Jurisdiction(id: "houston", kind: .city, name: "Houston", state: "TX", coverage: .newsOnly)
        #expect(LocalText.coverage(houston) == "Houston doesn't publish council records in a form Floor can read yet. Headlines below.")
        let sf = Jurisdiction(id: "sf", kind: .city, name: "San Francisco", state: "CA", coverage: .pending)
        #expect(LocalText.coverage(sf) == "Council records for San Francisco are coming soon. Headlines below.")
        #expect(LocalText.coverage(.sample) == nil)
        #expect(LocalText.nothing("Houston") == "Nothing from Houston in the last 30 days.")
        #expect([Jurisdiction.Coverage.records, .pending, .newsOnly].map(LocalText.badge) == ["Ready", "Coming soon", "News only"])
    }

    /// The UserDefaults store reads back what it saved, and nothing before anything is saved.
    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "floor.tests.local.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLocalCityStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(["seattle", "nyc"])
        #expect(UserDefaultsLocalCityStore(defaults: defaults).load() == ["seattle", "nyc"])
    }
}
