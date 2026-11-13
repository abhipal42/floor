import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// What the person let Floor do with their location.
public enum LocationAuthorization: Sendable, Equatable {
    /// `precise` is false when they turned Precise Location off: the point is then only good to a
    /// few kilometres and can land in the neighbouring district.
    case allowed(precise: Bool)
    /// They said no, now or earlier. The system will not ask again; only Settings › Floor can
    /// change it.
    case denied
    /// Not theirs to give: Screen Time or a management profile.
    case restricted
    /// Location Services are off for the whole phone, so no app can ask — Settings › Privacy &
    /// Security › Location Services, not Floor's own page.
    case servicesOff
}

/// One fix. Held only for the length of one request — never stored, never logged.
public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Why no fix came back.
public enum LocationFailure: Error, Sendable, Equatable {
    /// The system had nothing within the time allowed (indoors, airplane mode).
    case timedOut
    /// Permission was withdrawn while the fix was being taken (`CLError.denied`).
    case denied
    /// Core Location reported some other error.
    case unavailable
}

/// Where onboarding gets a location from. A protocol so ``OnboardingModel`` can be tested without
/// Core Location, the system alert or a simulator.
///
/// The contract, which ``CoreLocationProvider`` keeps through ``PendingAnswer``:
/// - each method **returns** — never hangs — however the person or the system behaves, so a caller
///   can disable a button while it waits;
/// - a second call while one is pending **joins** it: both callers get the same answer, and only
///   one system request is made.
@MainActor
public protocol LocationProvider: AnyObject {
    /// Ask for when-in-use permission, showing the system alert if the person has not answered
    /// yet, and return their answer. Returns at once when they already have.
    func requestAuthorization() async -> LocationAuthorization
    /// One fix, after permission is granted. Throws a ``LocationFailure``.
    func currentLocation() async throws -> Coordinate
}

/// One answer that any number of callers can wait for, which arrives once — from the system, or
/// from a timeout — and is then forgotten. A late second answer (a `didFailWithError` after the
/// timeout already answered) is ignored.
@MainActor
final class PendingAnswer<Value: Sendable> {
    private var waiters: [CheckedContinuation<Value, any Error>] = []
    private var timeoutTask: Task<Void, Never>?

    var isWaiting: Bool { !waiters.isEmpty }

    /// Waits for ``finish(_:)``. The first caller runs `start` and arms the timeout, which answers
    /// `fallback`; later callers join the same wait.
    func wait(timeout: Duration, fallback: Result<Value, any Error>, start: () -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let first = waiters.isEmpty
            waiters.append(continuation)
            guard first else { return }
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(fallback)
            }
            start()
        }
    }

    /// Answers everyone waiting. Does nothing when nobody is.
    func finish(_ result: Result<Value, any Error>) {
        guard !waiters.isEmpty else { return }
        let waiting = waiters
        waiters = []
        timeoutTask?.cancel()
        timeoutTask = nil
        for waiter in waiting { waiter.resume(with: result) }
    }
}

#if canImport(CoreLocation)
/// The real thing: one `CLLocationManager`, when-in-use permission, one `requestLocation()`.
///
/// No background updates and no continuous tracking: one fix per tap. The manager is created on
/// the main actor, so Core Location calls its delegate on the main thread, which is what makes
/// `MainActor.assumeIsolated` in the callbacks sound.
@MainActor
public final class CoreLocationProvider: NSObject, LocationProvider {
    private let manager = CLLocationManager()
    private let fixTimeout: Duration
    private let authorizationTimeout: Duration
    private let authorization = PendingAnswer<LocationAuthorization>()
    private let fix = PendingAnswer<Coordinate>()
    private var becameActive: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - fixTimeout: how long to wait for a fix before falling back to the address field.
    ///   - authorizationTimeout: the backstop if the system alert never answers. Normally the
    ///     answer comes from the delegate, or from the app becoming active again with nothing
    ///     decided.
    public init(fixTimeout: Duration = .seconds(15), authorizationTimeout: Duration = .seconds(120)) {
        self.fixTimeout = fixTimeout
        self.authorizationTimeout = authorizationTimeout
        super.init()
        manager.delegate = self
        // A district is kilometres across; tens of metres is plenty, and the API keeps ~11 m.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        #if canImport(UIKit)
        becameActive = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        #endif
    }

    public func requestAuthorization() async -> LocationAuthorization {
        // Apple warns against asking this on the main thread: it can block while the daemon answers.
        let servicesOn = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesOn else { return .servicesOff }
        if let answer = Self.answer(manager) { return answer }
        let answer = try? await authorization.wait(timeout: authorizationTimeout, fallback: .success(.denied)) {
            manager.requestWhenInUseAuthorization()
        }
        return answer ?? .denied
    }

    public func currentLocation() async throws -> Coordinate {
        try await fix.wait(timeout: fixTimeout, fallback: .failure(LocationFailure.timedOut)) {
            manager.requestLocation()
        }
    }

    /// The system alert makes the app inactive; answering it makes it active again. If it comes
    /// back with nothing decided — the alert was dismissed some other way — stop waiting, so the
    /// button cannot stay disabled. The delegate's own callback can land just after this, hence
    /// the short grace period.
    private func appBecameActive() {
        guard authorization.isWaiting else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.authorization.isWaiting else { return }
            self.authorization.finish(.success(Self.answer(self.manager) ?? .denied))
        }
    }

    /// nil while the person has not answered.
    private static func answer(_ manager: CLLocationManager) -> LocationAuthorization? {
        switch manager.authorizationStatus {
        case .notDetermined: return nil
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .allowed(precise: manager.accuracyAuthorization == .fullAccuracy)
        }
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // Called once as soon as the delegate is set, with nothing decided yet; wait for the
            // real answer. `self.manager` is the one calling, already main-actor state.
            guard let answer = Self.answer(self.manager) else { return }
            authorization.finish(.success(answer))
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        MainActor.assumeIsolated { fix.finish(.success(coordinate)) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let failure: LocationFailure = (error as? CLError)?.code == .denied ? .denied : .unavailable
        MainActor.assumeIsolated { fix.finish(.failure(failure)) }
    }
}
#endif
