import Foundation
import Models

/// Who represents you, as onboarding resolves it and the rest of the app reads it.
///
/// This is what gets stored on the device. **The address is not part of it** — it is used to make
/// one request and then dropped, so it is never written to disk, never logged, and cannot leak
/// through a backup or a crash report.
public struct Delegation: Codable, Sendable, Hashable {
    public var district: District
    public var members: [Member]
    /// When the lookup was made, so a later version can offer to refresh after redistricting.
    public var resolvedAt: Date

    public init(district: District, members: [Member], resolvedAt: Date = Date()) {
        self.district = district
        self.members = members
        self.resolvedAt = resolvedAt
    }

    public init(reps: Reps, resolvedAt: Date = Date()) {
        self.init(district: reps.district, members: reps.members, resolvedAt: resolvedAt)
    }

    public var representative: Member? { members.first { $0.chamber == .house } }
    public var senators: [Member] { members.filter { $0.chamber == .senate } }

    /// The Bioguide IDs to pass as `?members=` when loading a vote.
    public var memberIds: [String] { members.map(\.bioguideId) }
}

/// Where the resolved delegation is kept between launches.
public protocol DelegationStore: Sendable {
    func load() -> Delegation?
    func save(_ delegation: Delegation)
    func clear()
}

/// Stores it in `UserDefaults` as JSON.
///
/// `UserDefaults` rather than SwiftData because this is one small record read at launch, before any
/// screen exists. `suite` is injectable so tests get their own, and so it can move to an App Group
/// when widgets and the Live Activity need to read it.
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe but is not marked
/// `Sendable`; nothing here adds state of its own.
public struct UserDefaultsDelegationStore: DelegationStore, @unchecked Sendable {
    static let key = "floor.delegation.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Delegation? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        // A stored record written by an older version may no longer decode. Treat that as "not
        // onboarded" and let the person redo it, rather than failing to launch.
        return try? JSONDecoder().decode(Delegation.self, from: data)
    }

    public func save(_ delegation: Delegation) {
        guard let data = try? JSONEncoder().encode(delegation) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// An in-memory store for previews and tests.
public final class InMemoryDelegationStore: DelegationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Delegation?

    public init(_ initial: Delegation? = nil) {
        stored = initial
    }

    public func load() -> Delegation? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func save(_ delegation: Delegation) {
        lock.lock()
        defer { lock.unlock() }
        stored = delegation
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

public extension Delegation {
    static let sample = Delegation(
        district: .sample,
        members: [.sample, .sampleSenator],
        resolvedAt: Date(timeIntervalSince1970: 1_763_000_000)
    )
}
