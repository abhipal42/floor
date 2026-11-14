import Foundation
import Models
import Observation

/// iCloud's key-value store as ``CloudSync`` uses it: `NSUbiquitousKeyValueStore` in the app, a
/// dictionary in tests.
public protocol CloudKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}

/// What is written to iCloud: the follow state and the district. **The district goes as a
/// district** (its code and members, which are public), never an address or a location — the
/// saved `Delegation` holds neither. Nothing here goes to Floor's servers; iCloud is Apple's,
/// under the person's own account.
public struct CloudPayload: Codable, Sendable, Hashable {
    public var version: Int
    public var follows: FollowState
    /// nil once the district was cleared ("Change address") on whichever phone wrote this.
    public var delegation: Delegation?
    /// When the district was last set or cleared: the merge keeps the newer one.
    public var delegationChangedAt: Date

    public static let currentVersion = 1

    public init(follows: FollowState, delegation: Delegation?, delegationChangedAt: Date) {
        version = Self.currentVersion
        self.follows = follows
        self.delegation = delegation
        self.delegationChangedAt = delegationChangedAt
    }
}

/// "Sync with iCloud" (round 11, section F): follows and alert choices, and the district, kept in
/// step across the person's own devices through `NSUbiquitousKeyValueStore`. There is still no Floor
/// account. Off until switched on.
///
/// Follows merge by ``FollowState/merged(with:)`` (a union, last write wins per item, unfollows kept
/// as tombstones); the district is last-write-wins by when it was set or cleared.
@MainActor
@Observable
public final class CloudSync {
    public enum Status: Equatable, Sendable {
        /// This build has no iCloud key-value store (no entitlement): the switch is a placeholder.
        case unavailable
        case off
        case on(lastSynced: Date?)
        /// The record is over iCloud's per-key limit; nothing was written.
        case tooLarge
    }

    public private(set) var enabled: Bool
    public private(set) var lastSynced: Date?
    public private(set) var tooLarge = false

    @ObservationIgnored private let follows: Follows
    @ObservationIgnored private let delegations: any DelegationStore
    @ObservationIgnored private let cloud: (any CloudKeyValueStore)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// The district iCloud brought in (or cleared); the app swaps its delegation here.
    @ObservationIgnored public var onDelegation: @MainActor (Delegation?) -> Void = { _ in }

    static let cloudKey = "floor.sync.v1"
    static let enabledKey = "floor.icloud.enabled.v1"
    static let lastSyncedKey = "floor.icloud.lastSynced.v1"
    static let delegationChangedKey = "floor.icloud.delegationChangedAt.v1"
    /// iCloud allows 1 MB per key; leave room.
    public static let byteLimit = 900_000

    /// - Parameter cloud: nil in a build without the iCloud entitlement (``isAvailable(info:)``).
    public init(
        follows: Follows, delegations: any DelegationStore, cloud: (any CloudKeyValueStore)?,
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init
    ) {
        self.follows = follows
        self.delegations = delegations
        self.cloud = cloud
        self.defaults = defaults
        self.now = now
        enabled = cloud != nil && defaults.bool(forKey: Self.enabledKey)
        lastSynced = defaults.object(forKey: Self.lastSyncedKey) as? Date
    }

    /// Whether this build carries the key-value store entitlement. `FloorICloudKVS` in Info.plist is
    /// `$(FLOOR_ICLOUD_KVS)`, the entitlement's value, `$(TeamIdentifierPrefix)$(FLOOR_BUNDLE_ID)`:
    /// empty when a build turns it off, and just the bundle id when the build is unsigned (no team
    /// prefix, as on CI), where iCloud cannot work either.
    public nonisolated static func isAvailable(info: [String: Any]?) -> Bool {
        guard let value = info?["FloorICloudKVS"] as? String, !value.isEmpty, !value.contains("$(") else { return false }
        return value != info?["CFBundleIdentifier"] as? String
    }

    public var status: Status {
        if cloud == nil { return .unavailable }
        if !enabled { return .off }
        if tooLarge { return .tooLarge }
        return .on(lastSynced: lastSynced)
    }

    /// `6 members, 3 bills, 2 topics`: what is being synced.
    public var summary: String {
        let state = follows.state
        let members = state.entries(.member).count + (delegations.load()?.members.count ?? 0)
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        return [
            count(members, "member", "members"),
            count(state.entries(.bill).count, "bill", "bills"),
            count(state.entries(.topic).count, "topic", "topics"),
        ].joined(separator: ", ")
    }

    public func setEnabled(_ on: Bool) {
        guard cloud != nil else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { pull() }
    }

    /// The district changed on this phone (found, or cleared by "Change address").
    public func delegationChanged() {
        defaults.set(now(), forKey: Self.delegationChangedKey)
        push()
    }

    /// When the district was last set or cleared here: recorded since this build, else (a district
    /// found before sync existed) when it was looked up.
    private var delegationChangedAt: Date {
        defaults.object(forKey: Self.delegationChangedKey) as? Date ?? delegations.load()?.resolvedAt ?? .distantPast
    }

    /// Reads iCloud's copy, merges it in, and writes the result back. On switching on, at launch,
    /// and when iCloud says another device changed it.
    public func pull() {
        guard enabled, let cloud else { return }
        cloud.synchronize()
        if let data = cloud.data(forKey: Self.cloudKey),
           let remote = try? JSONDecoder().decode(CloudPayload.self, from: data),
           remote.version <= CloudPayload.currentVersion {
            let merged = follows.state.merged(with: remote.follows)
            if merged != follows.state { follows.replace(merged) }
            if remote.delegationChangedAt > delegationChangedAt {
                if let delegation = remote.delegation { delegations.save(delegation) } else { delegations.clear() }
                defaults.set(remote.delegationChangedAt, forKey: Self.delegationChangedKey)
                onDelegation(remote.delegation)
            }
        }
        push()
    }

    /// Writes this phone's state to iCloud. Called after every saved change while on.
    public func push() {
        guard enabled, let cloud else { return }
        let payload = CloudPayload(
            follows: follows.state.pruned(now: now()), delegation: delegations.load(),
            delegationChangedAt: delegationChangedAt
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        guard data.count <= Self.byteLimit else {
            tooLarge = true
            return
        }
        tooLarge = false
        if cloud.data(forKey: Self.cloudKey) != data { cloud.set(data, forKey: Self.cloudKey) }
        cloud.synchronize()
        let stamp = now()
        lastSynced = stamp
        defaults.set(stamp, forKey: Self.lastSyncedKey)
    }
}

/// A dictionary standing in for iCloud, for tests and previews.
public final class InMemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? { values[key] }
    public func set(_ data: Data?, forKey key: String) { values[key] = data }
    public func synchronize() -> Bool { true }
}
