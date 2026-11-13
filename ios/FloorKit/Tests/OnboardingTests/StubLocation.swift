import Foundation
@testable import Onboarding

/// Stands in for Core Location: answers the permission question and the fix with whatever the test
/// says, and counts how often it was asked. With `holdFix`, the fix waits until the test calls
/// ``release(_:)``, so a test can act while it is in flight.
@MainActor
final class StubLocation: LocationProvider {
    var authorization: LocationAuthorization
    var fix: Result<Coordinate, LocationFailure>
    var holdFix = false
    private(set) var authorizationRequests = 0
    private(set) var fixRequests = 0
    private var held: CheckedContinuation<Coordinate, any Error>?

    init(_ authorization: LocationAuthorization = .allowed(precise: true),
         fix: Result<Coordinate, LocationFailure> = .success(Coordinate(latitude: 30.2747, longitude: -97.7404))) {
        self.authorization = authorization
        self.fix = fix
    }

    func requestAuthorization() async -> LocationAuthorization {
        authorizationRequests += 1
        return authorization
    }

    func currentLocation() async throws -> Coordinate {
        fixRequests += 1
        guard holdFix else { return try fix.get() }
        return try await withCheckedThrowingContinuation { held = $0 }
    }

    var isHoldingFix: Bool { held != nil }

    func release(_ result: Result<Coordinate, LocationFailure>) {
        held?.resume(with: result.mapError { $0 as any Error })
        held = nil
    }
}

/// One of the real `/v1/reps` responses captured into `ModelsTests/Fixtures`, read from the source
/// tree as the other test targets do, so there is one copy.
func repsFixture(_ name: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // OnboardingTests
    dir.deleteLastPathComponent() // Tests
    let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
    return try String(contentsOf: url, encoding: .utf8)
}
