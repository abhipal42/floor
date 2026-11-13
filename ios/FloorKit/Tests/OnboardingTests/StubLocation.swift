import Foundation
@testable import Onboarding

/// Stands in for Core Location: answers the permission question and the fix with whatever the test
/// says, and counts how often it was asked.
@MainActor
final class StubLocation: LocationProvider {
    var authorization: LocationAuthorization
    var fix: Result<Coordinate, LocationFailure>
    private(set) var authorizationRequests = 0
    private(set) var fixRequests = 0

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
        return try fix.get()
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
