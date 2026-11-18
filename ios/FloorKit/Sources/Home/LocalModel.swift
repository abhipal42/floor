import APIClient
import Foundation
import Models

/// The Local tab (v0.2.60, the locked State & city option A): your state's hub from the stored
/// district, then the cities you saved, each with what passed, what is waiting and the news.
///
/// Your state is automatic. The cities are yours: kept on this phone (``LocalCityStore``), and until
/// you change them, your district's Census place when it is a city Floor covers.
@MainActor
@Observable
public final class LocalModel {
    public enum ListPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public enum HubPhase: Equatable {
        case loading
        case loaded(LocalHub)
        case failed(String)
    }

    /// The stored district; nil when you skipped finding your reps.
    public let district: District?
    public private(set) var listPhase: ListPhase = .loading
    public private(set) var registry = LocalJurisdictions(jurisdictions: [])
    public private(set) var hubs: [String: HubPhase] = [:]
    public private(set) var saved: [String: SavedCopy] = [:]
    /// Your state's legislators; empty until loaded, and when the API has none for you.
    public private(set) var legislators: [StateLegislator] = []
    /// The hub on screen; nil shows the first.
    public var selected: String?
    /// Cities you added or removed, in the order you added them; nil until you change anything.
    public private(set) var chosenCities: [String]?

    private let api: FloorAPI
    private let store: any LocalCityStore
    private var generations: [String: Int] = [:]

    public init(district: District?, api: FloorAPI, cities: any LocalCityStore) {
        self.district = district
        self.api = api
        store = cities
        chosenCities = cities.load()
    }

    // MARK: Hubs

    /// Your state's id: the registry's, or the postal code lowercased while the registry loads.
    public var stateId: String? {
        guard let district, !Member.delegateJurisdictions.contains(district.state) else { return nil }
        return registry.state(district.state)?.id ?? district.state.lowercased()
    }

    /// Your cities: the ones you chose, else your Census place when it is a registry city.
    public var cityIds: [String] {
        if let chosenCities { return chosenCities }
        guard let geoid = district?.place?.geoid, let city = registry.city(placeGeoid: geoid) else { return [] }
        return [city.id]
    }

    /// The hub switch's entries: your state first, then your cities, as the registry names them.
    public var hubIds: [String] {
        let known = Set(registry.cities.map(\.id))
        // A saved city the registry no longer lists is left out rather than shown as an error.
        let cities = registry.jurisdictions.isEmpty ? cityIds : cityIds.filter(known.contains)
        return (stateId.map { [$0] } ?? []) + cities
    }

    /// The hub on screen.
    public var current: String? {
        if let selected, hubIds.contains(selected) { return selected }
        return hubIds.first
    }

    /// The switch's label for a hub: `New York State`, `New York City`.
    public func name(_ id: String) -> String {
        if let found = registry.jurisdictions.first(where: { $0.id == id }) { return found.name }
        if id == stateId, let district { return StateName.full(district.state) }
        return id.uppercased()
    }

    public func jurisdiction(_ id: String) -> Jurisdiction? {
        registry.jurisdictions.first { $0.id == id }
    }

    // MARK: Cities

    public func isSaved(_ city: Jurisdiction) -> Bool { cityIds.contains(city.id) }

    /// Adds a city to the end of your hubs, or removes it.
    public func toggle(_ city: Jurisdiction) {
        var ids = cityIds
        if let index = ids.firstIndex(of: city.id) { ids.remove(at: index) } else { ids.append(city.id) }
        chosenCities = ids
        store.save(ids)
    }

    // MARK: Loading

    /// The registry, saved first then fresh.
    public func loadList() async {
        do {
            try await revalidate(api, report: { _ in }) { pass in
                let found = try await pass.api.localJurisdictions()
                registry = found
                listPhase = .loaded
            }
        } catch is CancellationError {
        } catch {
            if registry.jurisdictions.isEmpty {
                listPhase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load the places Floor covers.")
            }
        }
    }

    public func hub(_ id: String) -> HubPhase { hubs[id] ?? .loading }

    public func needsRefresh(_ id: String) -> Bool {
        if case .loaded = hub(id) { return saved[id] != nil }
        return true
    }

    /// One hub, saved first then fresh. What is on screen stays while it refreshes.
    public func loadHub(_ id: String) async {
        let mine = (generations[id] ?? 0) + 1
        generations[id] = mine
        if case .loaded = hub(id) {} else { hubs[id] = .loading }
        do {
            try await revalidate(api, report: { if generations[id] == mine { saved[id] = $0 } }) { pass in
                let found = try await pass.api.localHub(id: id)
                guard generations[id] == mine else { throw CancellationError() }
                hubs[id] = .loaded(found)
            }
        } catch is CancellationError {
        } catch {
            guard generations[id] == mine else { return }
            saved[id] = nil
            hubs[id] = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load \(name(id)).")
        }
    }

    /// Whether the stored district has the state legislative districts (v0.2.60 lookups do).
    public var hasStateDistricts: Bool { district?.stateUpper != nil || district?.stateLower != nil }

    /// Best effort: with none, the section is left out.
    public func loadLegislators() async {
        guard let district, hasStateDistricts else { return }
        let found = try? await api.stateLegislators(state: district.state, upper: district.stateUpper, lower: district.stateLower)
        legislators = found?.legislators ?? legislators
    }
}

/// Where the Local tab's cities are kept between launches. A choice about the app, not data about
/// you, so it stays on this phone.
public protocol LocalCityStore: Sendable {
    /// nil when you have never changed them.
    func load() -> [String]?
    func save(_ ids: [String])
}

/// The app's own `UserDefaults`, as JSON.
public struct UserDefaultsLocalCityStore: LocalCityStore, @unchecked Sendable {
    static let key = "floor.localCities.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [String]? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public func save(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// For tests and previews.
public final class InMemoryLocalCityStore: LocalCityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]?

    public init(_ ids: [String]? = nil) { self.ids = ids }

    public func load() -> [String]? { lock.withLock { ids } }
    public func save(_ ids: [String]) { lock.withLock { self.ids = ids } }
}

/// The Local tab's words, apart from the views so they can be tested.
public enum LocalText {
    /// The card with no district: look up the address with the existing flow.
    public static let noState = "Look up your address to see your state's new laws and your city's council votes."
    public static let lookUp = "Look up my address"
    public static let lookUpAgain = "Look up my address again"

    /// A district with no state legislature Floor covers (D.C., the territories).
    public static func noStateHub(_ place: String) -> String {
        "Floor covers the 50 state legislatures, and \(place) isn't one. Add a city from Cities ›."
    }

    /// Under the Cities screen's title.
    public static let citiesLine = "Your state is always on Local. Add the cities you want beside it."

    /// The dashed card when the stored district predates state legislative districts.
    public static func needDistricts(state: String) -> String {
        "Look up your address again to see your state senator and \(StateChambers.lowerMember(state: state))."
    }

    /// The muted card over a city hub without records.
    public static func coverage(_ jurisdiction: Jurisdiction) -> String? {
        guard jurisdiction.kind == .city else { return nil }
        switch jurisdiction.coverage {
        case .records: return nil
        case .pending: return "Council records for \(jurisdiction.name) are coming soon. Headlines below."
        case .newsOnly: return "\(jurisdiction.name) doesn't publish council records in a form Floor can read yet. Headlines below."
        }
    }

    /// `Nothing from Houston in the last 30 days.`
    public static func nothing(_ name: String) -> String { "Nothing from \(name) in the last 30 days." }

    /// The Cities screen's badge for a city: `Ready`, `Coming soon`, `News only`.
    public static func badge(_ coverage: Jurisdiction.Coverage) -> String {
        switch coverage {
        case .records: "Ready"
        case .pending: "Coming soon"
        case .newsOnly: "News only"
        }
    }

    /// A law or a passed matter read aloud.
    public static func spoken(_ item: LocalItem) -> String {
        var parts = [item.identifier.isEmpty ? nil : item.identifier, item.title, item.shortDate]
        if let tally = item.tally { parts.append("passed, \(tally.yes) yes, \(tally.no) no") }
        parts.append(item.summary)
        return parts.compactMap(\.self).joined(separator: ". ")
    }
}
