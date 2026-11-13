import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// What the person let Floor do with their location.
public enum LocationAuthorization: Sendable, Equatable {
    /// `precise` is false when they turned Precise Location off: the point is then only good to a
    /// few kilometres and can land in the neighbouring district.
    case allowed(precise: Bool)
    /// They said no, now or earlier. The system will not ask again; only Settings can change it.
    case denied
    /// Not theirs to give: Screen Time, a management profile, or Location Services off entirely.
    case restricted
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
    /// Core Location reported an error.
    case unavailable
}

/// Where onboarding gets a location from. A protocol so ``OnboardingModel`` can be tested without
/// Core Location, the system alert or a simulator.
@MainActor
public protocol LocationProvider: AnyObject {
    /// Ask for when-in-use permission, showing the system alert if the person has not answered
    /// yet, and return their answer. Returns at once when they already have.
    func requestAuthorization() async -> LocationAuthorization
    /// One fix, after permission is granted.
    func currentLocation() async throws -> Coordinate
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
    private let timeout: Duration
    private var authorizationWaiter: CheckedContinuation<LocationAuthorization, Never>?
    private var fixWaiter: CheckedContinuation<Coordinate, any Error>?
    private var timeoutTask: Task<Void, Never>?

    /// - Parameter timeout: how long to wait for a fix before falling back to the address field.
    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
        super.init()
        manager.delegate = self
        // A district is kilometres across; tens of metres is plenty, and the API keeps ~11 m.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    public func requestAuthorization() async -> LocationAuthorization {
        if let answer = Self.answer(manager) { return answer }
        return await withCheckedContinuation { continuation in
            authorizationWaiter = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public func currentLocation() async throws -> Coordinate {
        try await withCheckedThrowingContinuation { continuation in
            fixWaiter = continuation
            manager.requestLocation()
            let timeout = timeout
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishFix(.failure(LocationFailure.timedOut))
            }
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

    private func finishFix(_ result: Result<Coordinate, any Error>) {
        guard let waiter = fixWaiter else { return }
        fixWaiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        waiter.resume(with: result)
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // Called once as soon as the delegate is set, with nothing decided yet; wait for the
            // real answer. `self.manager` is the one calling, already main-actor state.
            guard let answer = Self.answer(self.manager), let waiter = authorizationWaiter else { return }
            authorizationWaiter = nil
            waiter.resume(returning: answer)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        MainActor.assumeIsolated { finishFix(.success(coordinate)) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // `locationUnknown` is "still trying"; requestLocation() reports it only when it gives up.
        MainActor.assumeIsolated { finishFix(.failure(LocationFailure.unavailable)) }
    }
}
#endif
