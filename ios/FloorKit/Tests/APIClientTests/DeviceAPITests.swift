import Foundation
import Testing
@testable import APIClient
import Models

/// In `FloorAPITests` (an extension), so they share its `.serialized` trait: `StubURLProtocol`
/// keeps its responder in shared state.
extension FloorAPITests {
    private static let base = URL(string: "https://api.example.test")!

    private static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    @Test func registersWithTheKeyInTheHeaderNeverTheURL() async throws {
        let session = StubURLProtocol.session(always: .json(#"{"subscriptions":2,"voteOpened":false}"#))
        let key = DeviceKey.generate()
        let answer = try await FloorAPI(baseURL: Self.base, session: session).registerDevice(.sample, key: key)
        #expect(answer == DeviceRegistered(subscriptions: 2, voteOpened: false))
        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://api.example.test/v1/devices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Device \(key.value)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(DeviceRegistration.self, from: try #require(Self.body(request)))
        #expect(sent == .sample)
        #expect(!(request.url?.absoluteString.contains(key.value) ?? true))
    }

    @Test func unregistersAndKeepsActivityTokensPerVote() async throws {
        let session = StubURLProtocol.session(always: .response(status: 204, body: Data()))
        let api = FloorAPI(baseURL: Self.base, session: session)
        let key = DeviceKey.generate()
        try await api.unregisterDevice(key: key)
        try await api.setActivityToken(String(repeating: "cd", count: 32), voteId: "house-119-2-321", key: key)
        try await api.removeActivityToken(voteId: "house-119-2-321", key: key)
        #expect(StubURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "DELETE /v1/devices",
            "PUT /v1/devices/activities/house-119-2-321",
            "DELETE /v1/devices/activities/house-119-2-321",
        ])
    }

    @Test func aRefusedRegistrationSaysWhyInTheAPIsWords() async throws {
        let session = StubURLProtocol.session(always: .json(#"{"error":"This phone is not registered; PUT /v1/devices first."}"#, status: 404))
        await #expect(throws: FloorAPIError.self) {
            try await FloorAPI(baseURL: Self.base, session: session)
                .setActivityToken(String(repeating: "cd", count: 32), voteId: "house-119-2-321", key: .generate())
        }
    }

    @Test func pollsTheLiveViewUncached() async throws {
        let session = StubURLProtocol.session(always: .response(status: 200, body: try fixtureData("live")))
        let cache = try SwiftDataResponseCache.inMemory()
        let api = FloorAPI(baseURL: Self.base, session: session, cache: cache)
        let live = try await api.live(since: 30)
        #expect(live.votes.count == 3)
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://api.example.test/v1/live?since=30")
        #expect(api.savedOnly().map { _ in true } == true)
        await #expect(throws: (any Error).self) { try await api.savedOnly()!.api.live(since: 30) }
    }
}
