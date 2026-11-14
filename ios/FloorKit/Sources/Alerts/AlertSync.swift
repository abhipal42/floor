import APIClient
import Foundation
import Models
import Observation
import Onboarding

/// Whether Floor may notify you, as `UNUserNotificationCenter` reports it.
public enum NotificationStatus: Sendable, Hashable {
    case notDetermined, denied, allowed
}

/// The system's notification permission: `UNUserNotificationCenter` in the app, a stub in tests.
public protocol NotificationPermissions: Sendable {
    func status() async -> NotificationStatus
    /// Asks, once; answers whether alerts are now allowed.
    func request() async -> Bool
}

/// Where registrations go: the API in the app, a recorder in tests.
public protocol DeviceRegistrar: Sendable {
    func register(_ registration: DeviceRegistration, key: DeviceKey) async throws
    func unregister(key: DeviceKey) async throws
}

extension FloorAPI: DeviceRegistrar {
    public func register(_ registration: DeviceRegistration, key: DeviceKey) async throws {
        try await registerDevice(registration, key: key)
    }

    public func unregister(key: DeviceKey) async throws {
        try await unregisterDevice(key: key)
    }
}

/// Keeps the API's copy of this phone's alert choices current (`PUT /v1/devices`).
///
/// It registers only once notifications are allowed and there is a token, and only something it
/// has not already sent: the last registration that succeeded is remembered, so launching the app
/// or opening the Alerts screen costs nothing when nothing changed. With nothing left on — no
/// "How they voted" switch and no "A vote opened" — or with permission taken away, it unregisters,
/// so the API keeps no list of what an alert-less phone follows.
@MainActor
@Observable
public final class AlertSync {
    /// The APNs token, as hex, once the system hands it over.
    public var apnsToken: String? { didSet { if apnsToken != oldValue { schedule() } } }
    /// ActivityKit's push-to-start token, as hex.
    public var pushToStartToken: String? { didSet { if pushToStartToken != oldValue { schedule() } } }
    public private(set) var permission: NotificationStatus = .notDetermined

    @ObservationIgnored private let registrar: any DeviceRegistrar
    @ObservationIgnored private let permissions: any NotificationPermissions
    @ObservationIgnored private let key: DeviceKey
    @ObservationIgnored private let environment: DeviceRegistration.Environment
    @ObservationIgnored private let defaults: UserDefaults
    /// Who and what you follow, read when a sync runs.
    @ObservationIgnored private let source: @MainActor () -> (state: FollowState, reps: [Member])
    /// Called when permission is granted, so the app can ask APNs for a token.
    @ObservationIgnored private let onAllowed: @MainActor () -> Void
    /// Called after a registration succeeds: the app resends Live Activity tokens the API refused
    /// (404) while the phone was not registered yet.
    @ObservationIgnored public var onRegistered: @MainActor () -> Void = {}
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let debounce: Duration

    static let sentKey = "floor.alerts.registered.v1"

    public init(
        registrar: any DeviceRegistrar,
        permissions: any NotificationPermissions,
        key: DeviceKey,
        environment: DeviceRegistration.Environment,
        defaults: UserDefaults = .standard,
        debounce: Duration = .seconds(2),
        onAllowed: @escaping @MainActor () -> Void = {},
        source: @escaping @MainActor () -> (state: FollowState, reps: [Member])
    ) {
        self.registrar = registrar
        self.permissions = permissions
        self.key = key
        self.environment = environment
        self.defaults = defaults
        self.debounce = debounce
        self.onAllowed = onAllowed
        self.source = source
    }

    /// The registration for these choices: every one of your members (reps not hidden, then
    /// followed) and every followed bill, each with its "How they voted" switch.
    public static func registration(
        state: FollowState, reps: [Member], apnsToken: String?, pushToStartToken: String?,
        environment: DeviceRegistration.Environment
    ) -> DeviceRegistration {
        let repIds = Set(reps.map(\.bioguideId))
        let members = state.yourMembers(reps: reps).map {
            DeviceSubscription(kind: .member, id: $0.bioguideId, howVoted: state.alertsOn(member: $0.bioguideId, isRep: repIds.contains($0.bioguideId)))
        }
        let bills = state.followedBillIds.map { DeviceSubscription(kind: .bill, id: $0, howVoted: state.alertsOn(bill: $0)) }
        return DeviceRegistration(
            apnsToken: apnsToken, apnsEnvironment: environment, pushToStartToken: pushToStartToken,
            voteOpened: state.voteOpened, subscriptions: members + bills
        )
    }

    /// Reads the permission again (the app returning from Settings, say).
    public func refreshPermission() async {
        permission = await permissions.status()
        if permission == .allowed { onAllowed() }
    }

    /// Asks for permission if it has never been asked. Called when the user turns a switch on —
    /// never before (round 9: "ask only when the user turns something on").
    public func askIfNeeded() async {
        if await permissions.status() == .notDetermined {
            _ = await permissions.request()
        }
        await refreshPermission()
        schedule()
    }

    /// Syncs a moment after the last change, so a run of switch flips is one request.
    public func schedule() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.sync()
        }
    }

    /// Registers, re-registers or unregisters as the choices and tokens now say.
    public func sync() async {
        permission = await permissions.status()
        let (state, reps) = source()
        let anyOn = state.anyAlertOn(members: state.yourMembers(reps: reps), reps: reps)
        // Tokens live in memory and arrive a moment after launch. A missing token means "not here
        // yet", never "unregister": that would delete the API's copy — and every Live Activity
        // token with it — on any cold launch where APNs answered slower than the debounce.
        if permission == .allowed, anyOn, apnsToken == nil, pushToStartToken == nil { return }
        let wanted = permission == .allowed && anyOn
        let last = defaults.data(forKey: Self.sentKey)
        if !wanted {
            guard last != nil else { return }
            do {
                try await registrar.unregister(key: key)
                defaults.removeObject(forKey: Self.sentKey)
            } catch {
                // Offline: the next sync tries again.
            }
            return
        }
        let registration = Self.registration(
            state: state, reps: reps, apnsToken: apnsToken, pushToStartToken: pushToStartToken, environment: environment
        )
        guard let encoded = try? JSONEncoder.sorted.encode(registration), encoded != last else { return }
        do {
            try await registrar.register(registration, key: key)
            defaults.set(encoded, forKey: Self.sentKey)
            onRegistered()
        } catch {
            // Offline or refused: nothing is remembered, so the next sync sends it again.
        }
    }
}

extension JSONEncoder {
    /// Byte-stable output, so "already sent" compares registrations, not key order.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
