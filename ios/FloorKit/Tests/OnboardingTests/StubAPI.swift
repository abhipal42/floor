import APIClient
import Foundation

/// A deliberately minimal stand-in for a server: one canned outcome for every request.
///
/// `APIClientTests` has a richer stub that records requests; this one only needs to put the client
/// into a given state, and the two test targets cannot share a file without a shared target.
final class StubAPIProtocol: URLProtocol {
    enum Outcome {
        case json(String, status: Int = 200)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcome: Outcome = .json("{}")
    nonisolated(unsafe) private static var _lastURL: URL?

    /// The last URL requested, so a test can see what left the phone.
    static var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _lastURL
    }

    /// A `FloorAPI` that answers every request with `outcome`.
    static func api(_ outcome: Outcome) -> FloorAPI {
        lock.lock()
        self.outcome = outcome
        _lastURL = nil
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAPIProtocol.self]
        return FloorAPI(
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let outcome = Self.outcome
        Self._lastURL = request.url
        Self.lock.unlock()

        guard let url = request.url else { return }
        switch outcome {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .json(body, status):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A real `/v1/reps` body: Texas 37, one representative and two senators.
let repsJSON = """
{
  "district": { "congress": 119, "state": "TX", "district": 37, "countyFips": "48453" },
  "members": [
    { "bioguideId": "D000399", "firstName": "Lloyd", "lastName": "Doggett", "party": "D",
      "state": "TX", "district": 37, "chamber": "house" },
    { "bioguideId": "C001098", "firstName": "Ted", "lastName": "Cruz", "party": "R",
      "state": "TX", "district": null, "chamber": "senate" },
    { "bioguideId": "C001056", "firstName": "John", "lastName": "Cornyn", "party": "R",
      "state": "TX", "district": null, "chamber": "senate" }
  ]
}
"""
