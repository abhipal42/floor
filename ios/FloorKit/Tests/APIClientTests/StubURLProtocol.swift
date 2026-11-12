import Foundation

/// Serves canned responses to `URLSession`, so the client can be exercised without a server.
///
/// State is shared across instances because `URLSession` constructs the protocol object itself, so
/// the suite using this must be `.serialized`.
final class StubURLProtocol: URLProtocol {
    enum Outcome {
        case response(status: Int, body: Data)
        case failure(URLError)

        static func json(_ body: String, status: Int = 200) -> Outcome {
            .response(status: status, body: Data(body.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Outcome)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    /// Installs a responder and clears anything recorded. Returns a session wired to it.
    static func session(_ handler: @escaping @Sendable (URLRequest) -> Outcome) -> URLSession {
        lock.lock()
        self.handler = handler
        seen = []
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Always answers with this, whatever is asked.
    static func session(always outcome: Outcome) -> URLSession {
        session { _ in outcome }
    }

    /// Every request made since the session was built, in order.
    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static var lastURL: URL? { requests.last?.url }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch handler(request) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .response(status, body):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
