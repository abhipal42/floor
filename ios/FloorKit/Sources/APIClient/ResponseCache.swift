import Foundation
import Models
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
/// Keyed by the API's host and the request's path and query (`floor-api.vercel.app/v1/members/
/// D000399/votes?limit=25`), and storing the JSON body exactly as the server sent it. Bodies rather
/// than one `@Model` per type: the screens already decode these bodies, the contract tests already
/// pin their shape, and a second hand-written schema for the same types would be a second place for
/// the contract to drift. A body the current app can no longer decode is simply a miss.
public protocol ResponseCache: Sendable {
    /// The saved body for `key`, or nil when there is none or it is older than the cache keeps.
    func load(_ key: String, now: Date) async -> CachedBody?
    /// Saves `body` for `key` as fetched at `date`, and evicts whatever the policy no longer keeps.
    func save(_ body: Data, for key: String, at date: Date) async
    /// Forgets everything: the saved responses name the members, and so the district.
    func removeAll() async
}

/// How much the cache keeps.
///
/// 30 days because a vote's record does not change once final, and a month covers being away from
/// signal on a trip; past that, a "saved 5 weeks ago" screen is more misleading than an error.
/// 200 entries because the app's screens cost one to four each (Home is six: three members' votes
/// and three loyalty records; a bill is the bill, its AI analysis — or the saved `null` that says it
/// has none — and one vote per chamber), so 200 is every screen of a long session several times
/// over, at tens of kilobytes a body — single-digit megabytes at the outside. An analysis carries
/// its whole CRS summary as `source.paragraphs`, so it is the largest body here: tens of kilobytes,
/// up to a few hundred for the longest summaries. A session spent only on the longest bills could
/// reach tens of megabytes; it is still Caches, which the system may purge.
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
/// the system may purge it and it is not backed up. Tests and previews use ``inMemory(policy:)``.
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

    /// The app's cache, in `Caches/FloorResponses.store`.
    public static func onDisk(policy: CachePolicy = CachePolicy()) -> SwiftDataResponseCache? {
        onDisk(at: URL.cachesDirectory.appending(path: "FloorResponses.store"), policy: policy)
    }

    /// Opens the store at `url`. A store that will not open — a failed migration, a corrupt file —
    /// is deleted with its `-wal` and `-shm` and opened once more: it holds nothing that cannot be
    /// fetched again, and keeping it would leave the app without a cache for good. nil only if the
    /// fresh store will not open either, and then the app runs as it did before there was a cache.
    static func onDisk(at url: URL, policy: CachePolicy) -> SwiftDataResponseCache? {
        func open() -> SwiftDataResponseCache? {
            let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
            guard let container = try? ModelContainer(for: CachedResponse.self, configurations: configuration) else {
                return nil
            }
            return SwiftDataResponseCache(container: container, policy: policy)
        }
        if let cache = open() { return cache }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return open()
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
        try? modelContext.save()
        evict(now: date)
    }

    public func removeAll() {
        var all = FetchDescriptor<CachedResponse>()
        all.propertiesToFetch = [\.key]
        for row in (try? modelContext.fetch(all)) ?? [] { modelContext.delete(row) }
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

    /// Drops anything past `maxAge`, then the oldest beyond `maxEntries`. Fetches only the rows to
    /// delete, and only their keys, not every body in the store.
    private func evict(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        var expired = FetchDescriptor<CachedResponse>(predicate: #Predicate { $0.fetchedAt < cutoff })
        expired.propertiesToFetch = [\.key]
        var excess = FetchDescriptor<CachedResponse>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
        excess.fetchOffset = policy.maxEntries
        excess.propertiesToFetch = [\.key]

        var doomed = (try? modelContext.fetch(expired)) ?? []
        doomed += (try? modelContext.fetch(excess)) ?? []
        guard !doomed.isEmpty else { return }
        for row in doomed where !row.isDeleted { modelContext.delete(row) }
        try? modelContext.save()
    }
}

// MARK: - Stale-while-revalidate

/// What one pass of a load read from the cache, and why it had to.
public actor PassRecord {
    private var dates: [Date] = []
    private var reachedServer = false

    func note(_ date: Date) { dates.append(date) }

    /// A best-effort request failed and its saved copy was used instead.
    func fellBack(after error: any Error) {
        if case .transport = error as? FloorAPIError { return }
        reachedServer = true
    }

    /// The oldest saved response read, which is what "saved … ago" should admit to.
    public var oldest: Date? { dates.min() }

    /// Offline unless every failure that forced a fallback was the server answering badly.
    var status: SavedCopy.Status { reachedServer ? .refreshFailed : .offline }
}

/// One pass of a screen's load: the client to use, and how best-effort requests fall back.
public struct Pass: Sendable {
    /// The cache-only client on the saved pass; the network client on the network pass.
    public let api: FloorAPI
    /// On the network pass, the cache-only client a failed best-effort request falls back to.
    let fallback: (api: FloorAPI, record: PassRecord)?
    /// True on the saved pass. A best-effort request that finds nothing saved is a miss there, not
    /// a failure: the network pass that follows decides, so a screen must not draw an error for it.
    public internal(set) var isSaved = false

    /// For a request the screen can live without (the bill under a vote, a loyalty ring): its value,
    /// or on the network pass its saved copy when the request fails — recorded, so the screen still
    /// says that part of it is saved. nil when neither is available, or the load was cancelled.
    public func bestEffort<T: Sendable>(_ fetch: @Sendable (FloorAPI) async throws -> T) async -> T? {
        do {
            return try await fetch(api)
        } catch {
            guard let fallback, !(error is CancellationError), !Task.isCancelled,
                  let saved = try? await fetch(fallback.api)
            else { return nil }
            await fallback.record.fellBack(after: error)
            return saved
        }
    }
}

/// Runs `load` twice: first against the saved responses, then against the network.
///
/// `load` puts what it fetched on screen itself, so a screen with several requests shows all of its
/// saved data at once rather than waiting on the network for the second. `report` hears the state
/// of what is on screen as it changes:
///
/// - after the saved pass draws: `.refreshing`, dated by the oldest response it read;
/// - after the network pass: nil when everything is fresh, or `.offline` / `.refreshFailed` dated
///   by the oldest saved copy still on screen — the saved pass's, if the network pass failed, or a
///   best-effort request's that fell back while the rest refreshed.
///
/// With nothing saved, a network failure is rethrown and the screen fails as it did before there
/// was a cache. Cancellation reports nothing and throws `CancellationError`: a cancelled refresh
/// is not a failed one, and the screen must be free to run it again.
///
/// `load` must only replace state once it has something to replace it with, so a failure in the
/// network pass cannot blank what the saved pass showed.
@MainActor
public func revalidate(
    _ api: FloorAPI,
    report: (SavedCopy?) -> Void,
    _ load: (Pass) async throws -> Void
) async throws {
    var savedAt: Date?
    if let saved = api.savedOnly() {
        do {
            try await load(Pass(api: saved.api, fallback: nil, isSaved: true))
            savedAt = await saved.record.oldest
        } catch {
            // Nothing saved for this screen, or a body this version cannot read: a miss.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
        }
        if let savedAt { report(SavedCopy(savedAt: savedAt, status: .refreshing)) }
    }

    let fallback = api.savedOnly()
    do {
        try await load(Pass(api: api, fallback: fallback))
    } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        guard let savedAt else { throw error }
        let offline = if case .transport = error as? FloorAPIError { true } else { false }
        report(SavedCopy(savedAt: savedAt, status: offline ? .offline : .refreshFailed))
        return
    }
    if Task.isCancelled { throw CancellationError() }
    if let record = fallback?.record, let oldest = await record.oldest {
        report(SavedCopy(savedAt: oldest, status: await record.status))
    } else {
        report(nil)
    }
}
