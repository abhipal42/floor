import APIClient
import Foundation
import Models
import Onboarding

/// Fetches what the widgets show, through the same `/v1/members/{id}/votes` route the app uses: one
/// request per member (your reps and everyone you follow), six at a time.
public enum WidgetFeed {
    /// How many of each member's votes to ask for. Ten is plenty to find the newest final, and
    /// keeps each request small.
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
    /// Each member on their own: one that fails leaves its row marked unavailable rather than
    /// failing the widget. Only when every one fails does the load fail (and the saved copy shows).
    ///
    /// - Parameter only: the ids to fetch — the medium widget's three; nil for everyone (the small
    ///   widget's latest final looks at all your members).
    public static func load(
        members: WidgetMembers, api: FloorAPI, now: Date = Date(), only: [String]? = nil
    ) async throws -> WidgetSnapshot {
        let asked = only.map(Set.init)
        let wanted = members.all.filter { asked?.contains($0.bioguideId) ?? true }
        let fetched = try await throttledMap(wanted) { member in
            do {
                return (member.bioguideId, Result<[MemberVote], any Error>.success(
                    try await api.memberVotes(id: member.bioguideId, limit: limit).votes
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (member.bioguideId, .failure(error))
            }
        }
        var records: [String: [MemberVote]] = [:]
        for case let (id, .success(votes)) in fetched { records[id] = votes }
        if records.isEmpty, !wanted.isEmpty, case let .failure(error)? = fetched.first?.1 { throw error }
        return WidgetSnapshot.make(members: members, records: records, fetchedAt: now, only: only)
    }

    public static func load(delegation: Delegation, api: FloorAPI, now: Date = Date()) async throws -> WidgetSnapshot {
        try await load(members: WidgetMembers(delegation: delegation), api: api, now: now)
    }

    /// What one timeline refresh produced.
    public enum Refresh: Sendable, Equatable {
        /// No district and nobody followed in the app.
        case noMembers
        /// Just fetched for your current members, and saved.
        case fresh(WidgetSnapshot)
        /// The fetch failed; this is the last snapshot saved for the same members.
        case saved(WidgetSnapshot)
        /// The fetch failed and nothing is saved for these members.
        case failed

        /// When the widget should ask again.
        public var retryAfter: TimeInterval {
            switch self {
            case .fresh, .noMembers: WidgetFeed.refreshInterval
            case .saved, .failed: WidgetFeed.retryInterval
            }
        }
    }

    /// One refresh: read your members, fetch, and save — but only if they are still the members
    /// fetched for.
    ///
    /// "Change address" (or a follow, or a hide) can land while a fetch is in flight. Saving that
    /// fetch afterwards would put the old district's votes back in the group the app just cleared,
    /// so the members are read again once the votes arrive, and a snapshot that no longer belongs
    /// is dropped.
    ///
    /// - Parameter members: reads what the app saved; called before and after the fetch.
    public static func refresh(
        members: @Sendable () -> WidgetMembers,
        only: @Sendable (WidgetMembers) -> [String]? = { _ in nil },
        api: FloorAPI,
        store: WidgetSnapshotStore,
        now: Date = Date()
    ) async -> Refresh {
        let asked = members()
        guard !asked.isEmpty else { return .noMembers }
        do {
            let snapshot = try await load(members: asked, api: api, now: now, only: only(asked))
            let current = members()
            guard !current.isEmpty, snapshot.belongs(to: current) else {
                // Overtaken: the next refresh, which the app asked for, fetches the new members.
                return current.isEmpty ? .noMembers : (store.load(for: current).map(Refresh.saved) ?? .failed)
            }
            store.save(snapshot)
            return .fresh(snapshot)
        } catch {
            let current = members()
            guard !current.isEmpty else { return .noMembers }
            return store.load(for: current).map(Refresh.saved) ?? .failed
        }
    }
}

/// The last snapshot that loaded, kept in the App Group so a failed refresh still shows something.
///
/// `@unchecked Sendable` for the same reason as ``UserDefaultsDelegationStore``.
public struct WidgetSnapshotStore: @unchecked Sendable {
    public static let key = "floor.widget.snapshot.v1"
    /// The medium widget's own copy: it fetches only the rows it draws, so its snapshot is not the
    /// small widget's.
    public static let mediumKey = "floor.widget.snapshot.medium.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = WidgetSnapshotStore.key) {
        self.defaults = defaults
        self.key = key
    }

    /// The store in this build's App Group, or nil if it has none.
    public static func shared() -> WidgetSnapshotStore? {
        UserDefaultsDelegationStore.groupDefaults().map { WidgetSnapshotStore(defaults: $0) }
    }

    /// The saved snapshot, only if it was built for exactly these members (as sets).
    public func load(for members: WidgetMembers) -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.belongs(to: members)
        else { return nil }
        return snapshot
    }

    public func load(for delegation: Delegation) -> WidgetSnapshot? {
        load(for: WidgetMembers(delegation: delegation))
    }

    public func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Forgets every saved snapshot, the small widget's and the medium one's: "Change address".
    public func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.mediumKey)
    }
}
