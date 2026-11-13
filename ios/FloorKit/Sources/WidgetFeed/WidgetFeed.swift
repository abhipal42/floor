import APIClient
import Foundation
import Models
import Onboarding

/// Fetches what the widgets show, through the same `/v1/members/{id}/votes` route the app uses.
public enum WidgetFeed {
    /// How many of each member's votes to ask for. Ten is plenty to find the newest final, and
    /// keeps a refresh to three small requests.
    public static let limit = 10

    /// How often the widget asks for a new timeline. WidgetKit treats this as a floor, not a
    /// promise, and spaces refreshes further apart on its own budget.
    public static let refreshInterval: TimeInterval = 30 * 60

    /// How soon to try again after a refresh that failed or was overtaken.
    public static let retryInterval: TimeInterval = 15 * 60

    /// A widget gets a few seconds of background time per refresh. A request that hasn't answered
    /// in 12 is given up on, so the saved snapshot is shown rather than the refresh being killed.
    public static let requestTimeout: TimeInterval = 12

    /// The widget's session: no `URLCache` (as the app's), and the short timeout above.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        return URLSession(configuration: configuration)
    }

    /// Every member's recent votes, fetched together. Any member failing fails the whole load:
    /// a row reading "no recorded votes" for a member who simply didn't load would be wrong.
    public static func load(delegation: Delegation, api: FloorAPI, now: Date = Date()) async throws -> WidgetSnapshot {
        let records = try await withThrowingTaskGroup(of: (String, [MemberVote]).self) { group in
            for member in delegation.members {
                group.addTask {
                    (member.bioguideId, try await api.memberVotes(id: member.bioguideId, limit: limit).votes)
                }
            }
            var collected: [String: [MemberVote]] = [:]
            for try await (id, votes) in group { collected[id] = votes }
            return collected
        }
        return WidgetSnapshot.make(delegation: delegation, records: records, fetchedAt: now)
    }

    /// What one timeline refresh produced.
    public enum Refresh: Sendable, Equatable {
        /// No district has been picked in the app.
        case noDistrict
        /// Just fetched for the current delegation, and saved.
        case fresh(WidgetSnapshot)
        /// The fetch failed; this is the last snapshot saved for the same delegation.
        case saved(WidgetSnapshot)
        /// The fetch failed and nothing is saved for this delegation.
        case failed

        /// When the widget should ask again.
        public var retryAfter: TimeInterval {
            switch self {
            case .fresh, .noDistrict: WidgetFeed.refreshInterval
            case .saved, .failed: WidgetFeed.retryInterval
            }
        }
    }

    /// One refresh: read the delegation, fetch, and save — but only if the delegation is still the
    /// one fetched for.
    ///
    /// "Change address" can land while a fetch is in flight. Saving that fetch afterwards would
    /// put the old district's votes back in the group the app just cleared, so the delegation is
    /// read again once the votes arrive, and a snapshot that no longer belongs is dropped.
    ///
    /// - Parameter delegation: reads the saved delegation; called before and after the fetch.
    public static func refresh(
        delegation: @Sendable () -> Delegation?,
        api: FloorAPI,
        store: WidgetSnapshotStore,
        now: Date = Date()
    ) async -> Refresh {
        guard let asked = delegation() else { return .noDistrict }
        do {
            let snapshot = try await load(delegation: asked, api: api, now: now)
            guard let current = delegation(), snapshot.belongs(to: current) else { return .noDistrict }
            store.save(snapshot)
            return .fresh(snapshot)
        } catch {
            guard let current = delegation() else { return .noDistrict }
            return store.load(for: current).map(Refresh.saved) ?? .failed
        }
    }
}

/// The last snapshot that loaded, kept in the App Group so a failed refresh still shows something.
///
/// `@unchecked Sendable` for the same reason as ``UserDefaultsDelegationStore``.
public struct WidgetSnapshotStore: @unchecked Sendable {
    static let key = "floor.widget.snapshot.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The store in this build's App Group, or nil if it has none.
    public static func shared() -> WidgetSnapshotStore? {
        UserDefaultsDelegationStore.groupDefaults().map(WidgetSnapshotStore.init)
    }

    /// The saved snapshot, only if it was built for this delegation.
    public func load(for delegation: Delegation) -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.belongs(to: delegation)
        else { return nil }
        return snapshot
    }

    public func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
