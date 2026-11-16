import APIClient
import Foundation
import Models
import Testing
@testable import RepScreen

/// Answers `/v1/members-elect/{id}` with El-Sayed's profile for his id and the API's 404 otherwise.
final class ElectStub: URLProtocol {
    static func api() -> FloorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElectStub.self]
        return FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent() // RepScreenTests
        dir.deleteLastPathComponent() // Tests
        let known = url.path == "/v1/members-elect/elect-2026-mi-sen"
        let body = known
            ? ((try? Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/member-elect-mi-sen.json"))) ?? Data())
            : Data(#"{"error":"Not found"}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: known ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite("Member-elect screen")
struct ElectScreenModelTests {
    @Test func loadsTheProfile() async {
        let model = ElectScreenModel(id: "elect-2026-mi-sen", api: ElectStub.api())
        #expect(model.needsRefresh)
        await model.load()
        guard case let .loaded(profile) = model.phase else { Issue.record("loaded"); return }
        #expect(profile.elect.fullName == "Abdul El-Sayed")
        #expect(profile.disclosure == nil)
        #expect(!model.needsRefresh)
    }

    /// The API's 404 — unknown, or they have taken office — is its own state, not an error.
    @Test func a404IsNoLongerListed() async {
        let model = ElectScreenModel(id: "elect-2026-xx-sen", api: ElectStub.api())
        await model.load()
        #expect(model.phase == .noLongerListed)
    }
}
