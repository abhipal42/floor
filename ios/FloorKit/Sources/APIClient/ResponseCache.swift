import Foundation
import SwiftData

/// One saved response body and when it was fetched.
public struct CachedBody: Sendable, Equatable {
    public var body: Data
    public var fetchedAt: Date

    public init(body: Data, fetchedAt: Date) {
        self.body = body
        self.fetchedAt = fetchedAt
    }
}

/// Where ``FloorAPI`` keeps the last good response to each request, so a screen can open on it
/// while offline or while the network is slow.
///
/// Keyed by the request's path and query (`/v1/members/D000399/votes?limit=25`), and storing the
/// JSON body exactly as the server sent it. Bodies rather than one `@Model` per type: the screens
/// already decode these bodies, the contract tests already pin their shape, and a second
/// hand-written schema for the same seven types would be a second place for the contract to drift.
/// A body the current app can no longer decode is simply a miss.
public protocol ResponseCache: Sendable {
    /// The saved body for `key`, or nil when there is none or it is older than the cache keeps.
    func load(_ key: String, now: Date) async -> CachedBody?
    /// Saves `body` for `key` as fetched at `date`, and evicts whatever the policy no longer keeps.
    func save(_ body: Data, for key: String, at date: Date) async
}

/// How much the cache keeps.
///
/// 30 days because a vote's record does not change once final, and a month covers being away from
/// signal on a trip; past that, a "saved 5 weeks ago" screen is more misleading than an error.
/// 200 entries because the app's screens cost one to three each (Home is six: three members' votes
/// and three loyalty records), so 200 is every screen of a long session several times over, at
/// tens of kilobytes a body — single-digit megabytes at the outside.
public struct CachePolicy: Sendable, Equatable {
    public var maxAge: TimeInterval
    public var maxEntries: Int

    public init(maxAge: TimeInterval = 30 * 24 * 60 * 60, maxEntries: Int = 200) {
        self.maxAge = maxAge
        self.maxEntries = maxEntries
    }
}

/// The row SwiftData stores: one per request key.
@Model
final class CachedResponse {
    @Attribute(.unique) var key: String
    var body: Data
    var fetchedAt: Date

    init(key: String, body: Data, fetchedAt: Date) {
        self.key = key
        self.body = body
        self.fetchedAt = fetchedAt
    }
}

/// A ``ResponseCache`` in SwiftData.
///
/// On disk it lives in Caches, not Application Support: everything in it can be fetched again, so
/// the system may purge it under storage pressure and it is not backed up. Tests and previews use
/// ``inMemory(policy:)``.
public actor SwiftDataResponseCache: ResponseCache, ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    public let policy: CachePolicy

    init(container: ModelContainer, policy: CachePolicy) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.policy = policy
    }

    /// A cache that lasts as long as the process. For tests and previews.
    public static func inMemory(policy: CachePolicy = CachePolicy()) throws -> SwiftDataResponseCache {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return SwiftDataResponseCache(
            container: try ModelContainer(for: CachedResponse.self, configurations: configuration),
            policy: policy
        )
    }

    /// The app's cache, in `Caches/FloorResponses.store`. nil if the store cannot be opened, in
    /// which case the app runs exactly as it did before there was a cache.
    public static func onDisk(policy: CachePolicy = CachePolicy()) -> SwiftDataResponseCache? {
        let url = URL.cachesDirectory.appending(path: "FloorResponses.store")
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        guard let container = try? ModelContainer(for: CachedResponse.self, configurations: configuration) else {
            return nil
        }
        return SwiftDataResponseCache(container: container, policy: policy)
    }

    public func load(_ key: String, now: Date) -> CachedBody? {
        guard let row = row(for: key) else { return nil }
        guard row.fetchedAt >= now.addingTimeInterval(-policy.maxAge) else {
            modelContext.delete(row)
            try? modelContext.save()
            return nil
        }
        return CachedBody(body: row.body, fetchedAt: row.fetchedAt)
    }

    public func save(_ body: Data, for key: String, at date: Date) {
        if let row = row(for: key) {
            row.body = body
            row.fetchedAt = date
        } else {
            modelContext.insert(CachedResponse(key: key, body: body, fetchedAt: date))
        }
        evict(now: date)
        try? modelContext.save()
    }

    /// Every stored key with its body, newest first. For tests: what is actually on disk.
    public func entries() -> [(key: String, body: Data)] {
        let rows = (try? modelContext.fetch(
            FetchDescriptor<CachedResponse>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
        )) ?? []
        return rows.map { ($0.key, $0.body) }
    }

    private func row(for key: String) -> CachedResponse? {
        var descriptor = FetchDescriptor<CachedResponse>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Drops anything past `maxAge`, then the oldest beyond `maxEntries`.
    private func evict(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        let rows = (try? modelContext.fetch(
            FetchDescriptor<CachedResponse>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
        )) ?? []
        for (index, row) in rows.enumerated() where index >= policy.maxEntries || row.fetchedAt < cutoff {
            modelContext.delete(row)
        }
    }
}

// MARK: - Stale-while-revalidate

/// A screen is showing saved data because the refresh after it failed.
public struct SavedCopy: Sendable, Equatable {
    /// When the oldest response on screen was fetched.
    public var savedAt: Date
    /// True when the refresh never reached the server, as opposed to the server answering badly.
    public var offline: Bool

    public init(savedAt: Date, offline: Bool) {
        self.savedAt = savedAt
        self.offline = offline
    }
}

/// The fetch times of the saved responses a cache-only pass read.
public actor SavedReads {
    private var dates: [Date] = []

    func note(_ date: Date) { dates.append(date) }

    /// The oldest, which is what "saved … ago" should admit to.
    public var oldest: Date? { dates.min() }
}

/// Runs `load` twice: first against the saved responses, then against the network.
///
/// `load` puts what it fetched on screen itself, so a screen with several requests shows all of its
/// saved data at once rather than waiting on the network for the second. If the network pass
/// throws after the saved pass succeeded, the saved data stays and this returns a ``SavedCopy``
/// saying how old it is. If there was nothing saved, the network's error is rethrown and the screen
/// fails as it did before there was a cache. nil means what is on screen is fresh.
///
/// `load` must only replace state once it has something to replace it with, so a failure in the
/// network pass cannot blank what the saved pass showed.
@MainActor
public func revalidate(_ api: FloorAPI, _ load: (FloorAPI) async throws -> Void) async throws -> SavedCopy? {
    var showedSaved = false
    let saved = api.savedOnly()
    if let saved {
        do {
            try await load(saved.api)
            showedSaved = true
        } catch {
            // Nothing saved for this screen, or a body this version cannot read: a miss.
        }
    }
    do {
        try await load(api)
        return nil
    } catch {
        guard showedSaved, let savedAt = await saved?.reads.oldest else { throw error }
        let offline = if case .transport = error as? FloorAPIError { true } else { false }
        return SavedCopy(savedAt: savedAt, offline: offline)
    }
}
