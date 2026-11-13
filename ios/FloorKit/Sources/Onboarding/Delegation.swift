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
/// screen exists. The app and the widget read it from the App Group suite (``shared(legacy:group:)``)
/// so the widget can show your members without its own onboarding; tests inject their own suites.
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe but is not marked
/// `Sendable`; nothing here adds state of its own.
public struct UserDefaultsDelegationStore: DelegationStore, @unchecked Sendable {
    static let key = "floor.delegation.v1"
    private let defaults: UserDefaults
    /// The app's own defaults, where builds before the widget kept the record. Cleared with the
    /// group, so "Change address" can never leave an old district behind there.
    private let legacy: UserDefaults?
    /// True when opening this store copied a delegation in from `legacy`: the widget was showing
    /// "pick your members" until now and should be told to reload.
    public let movedFromLegacy: Bool

    public init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, legacy: nil, movedFromLegacy: false)
    }

    private init(defaults: UserDefaults, legacy: UserDefaults?, movedFromLegacy: Bool) {
        self.defaults = defaults
        self.legacy = legacy.flatMap { $0 === defaults ? nil : $0 }
        self.movedFromLegacy = movedFromLegacy
    }

    public func load() -> Delegation? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        // A stored record written by an older version may no longer decode. Treat that as "not
        // onboarded" and let the person redo it, rather than failing to launch.
        return try? JSONDecoder().decode(Delegation.self, from: data)
    }

    /// Saves to the group. A new delegation makes the legacy copy stale, so it goes.
    public func save(_ delegation: Delegation) {
        guard let data = try? JSONEncoder().encode(delegation) else { return }
        defaults.set(data, forKey: Self.key)
        legacy?.removeObject(forKey: Self.key)
    }

    /// Forgets the district everywhere it was kept: the group and the app's own defaults.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
        legacy?.removeObject(forKey: Self.key)
    }

    /// The group used when the Info.plist doesn't name one (tests, previews, `swift test`).
    public static let defaultAppGroup = "group.app.floor.ios"

    /// The App Group the app and its widget share: the `FloorAppGroup` Info.plist key, which is
    /// `$(FLOOR_APP_GROUP)` from `ios/project.yml` — `group.<bundle id>`, so a personal build with
    /// its own bundle id gets its own group too.
    public static var appGroup: String { appGroup(in: .main) }

    static func appGroup(in bundle: Bundle) -> String {
        guard let named = bundle.object(forInfoDictionaryKey: "FloorAppGroup") as? String,
              named.hasPrefix("group."), !named.contains("$(")
        else { return defaultAppGroup }
        return named
    }

    /// The group's defaults, or nil when this build has no such group.
    ///
    /// `UserDefaults(suiteName:)` returns a suite whatever the entitlements say, private to the
    /// process when the group isn't granted — so the container is what proves the group exists.
    public static func groupDefaults(_ id: String = appGroup) -> UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil else { return nil }
        return UserDefaults(suiteName: id)
    }

    /// The store the app and the widget both use: the App Group suite, after copying in a
    /// delegation saved by a build from before the widget.
    ///
    /// Without the group (an unsigned or unentitled build) the app keeps using its own defaults,
    /// so it still remembers your district; the widget just cannot see it.
    public static func shared(
        legacy: UserDefaults = .standard,
        group: UserDefaults? = groupDefaults()
    ) -> UserDefaultsDelegationStore {
        guard let group else { return UserDefaultsDelegationStore(defaults: legacy) }
        let moved = migrate(from: legacy, to: group)
        return UserDefaultsDelegationStore(defaults: group, legacy: legacy, movedFromLegacy: moved)
    }

    /// Copies the saved delegation from `legacy` into `group` when the group has none, and says
    /// whether it did. A record already in the group wins: it was written later.
    ///
    /// The legacy copy is kept, so a group that turns out not to work loses nothing. It goes when
    /// the store saves a new delegation or clears, which is what keeps an old district from
    /// coming back after "Change address".
    @discardableResult
    public static func migrate(from legacy: UserDefaults, to group: UserDefaults) -> Bool {
        guard legacy !== group, let old = legacy.data(forKey: key), group.data(forKey: key) == nil else {
            return false
        }
        group.set(old, forKey: key)
        return group.data(forKey: key) != nil
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
