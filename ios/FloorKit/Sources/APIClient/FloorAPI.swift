import Foundation
import Models

/// A URLSession client for the Floor API.
///
/// One method per route in `apps/api/openapi.json`, each returning a model from `Models`. The
/// models carry no networking and this carries no view logic, so a screen talks to this and nothing
/// else knows about HTTP.
///
/// With a `cache`, every successful response a screen reads is saved, and ``savedOnly()`` gives a
/// copy of this client that answers from those saved responses without touching the network — what
/// ``revalidate(_:report:_:)`` uses to open a screen on its last-seen data.
public struct FloorAPI: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let cache: (any ResponseCache)?
    private let now: @Sendable () -> Date
    /// Non-nil on a ``savedOnly()`` copy: requests are answered from the cache and recorded here.
    private let record: PassRecord?

    /// The session used unless a test injects one. No `URLCache`: the shared session's would write
    /// every response to `Caches/Cache.db` — including `/v1/reps?address=`, whose URL is the street
    /// address — and ``ResponseCache`` is the only cache this app keeps.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// - Parameters:
    ///   - baseURL: the API's origin, e.g. `https://api.floor.app` or ``localDevelopment``. Set it
    ///     from the build configuration so staging and production builds differ only here.
    ///   - session: injectable so tests can stub transport.
    ///   - cache: where responses are saved for offline. nil keeps nothing, as previews do.
    ///   - now: the clock the cache dates entries by; injectable for tests.
    public init(
        baseURL: URL,
        session: URLSession = FloorAPI.defaultSession,
        cache: (any ResponseCache)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(baseURL: baseURL, session: session, cache: cache, now: now, record: nil)
    }

    private init(
        baseURL: URL, session: URLSession, cache: (any ResponseCache)?, now: @escaping @Sendable () -> Date,
        record: PassRecord?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cache = cache
        self.now = now
        self.record = record
    }

    /// This client answering only from saved responses, and a record of how old the ones it served
    /// were. nil without a cache. A request with nothing saved throws rather than going to the network.
    public func savedOnly() -> (api: FloorAPI, record: PassRecord)? {
        guard cache != nil else { return nil }
        let record = PassRecord()
        return (FloorAPI(baseURL: baseURL, session: session, cache: cache, now: now, record: record), record)
    }

    /// Forgets every saved response, as changing district must: they name the old members.
    public func clearSavedResponses() async {
        await cache?.removeAll()
    }

    /// `npm run dev -w @floor/api` serves here.
    public static let localDevelopment = URL(string: "http://localhost:8787")!

    // MARK: - Routes

    /// The district an address falls in, with its representative and senators.
    ///
    /// The address goes to this endpoint and nowhere else. The server passes it to the U.S. Census
    /// geocoder and neither stores nor logs it, and neither does this client — do not add logging
    /// here that would put it in a device console or a crash report.
    ///
    /// Never cached: the cache key would be the address itself. The district it resolves to is
    /// already kept, by onboarding's `DelegationStore`.
    public func reps(address: String) async throws -> Reps {
        try await get("/v1/reps", query: [URLQueryItem(name: "address", value: address)], cacheable: false)
    }

    /// The district a point falls in, with its members. Each coordinate is rounded to 4 decimals
    /// (about 11 m) before it leaves the phone; the server rounds again. Like the address, the
    /// point goes to this endpoint and nowhere else — never log it. A 404 means the point is not in
    /// a U.S. congressional district.
    ///
    /// Never cached: the key would be the location. The district it resolves to is already kept,
    /// by onboarding's `DelegationStore`.
    public func reps(latitude: Double, longitude: Double) async throws -> Reps {
        try await get("/v1/reps", query: [
            URLQueryItem(name: "lat", value: Self.coordinate(latitude)),
            URLQueryItem(name: "lng", value: Self.coordinate(longitude)),
        ], cacheable: false)
    }

    /// `30.2747`: rounded to the nearest 4th decimal, so no more precision is sent than
    /// the API keeps.
    static func coordinate(_ value: Double) -> String {
        String(format: "%.4f", (value * 10_000).rounded() / 10_000)
    }

    /// One vote with its party breakdown.
    ///
    /// - Parameter members: Bioguide IDs whose own positions to include, at most ten — your
    ///   delegation, so the vote screen loads in a single request.
    public func vote(id: String, members: [String] = []) async throws -> VoteDetail {
        var query: [URLQueryItem] = []
        if !members.isEmpty {
            query.append(URLQueryItem(name: "members", value: members.joined(separator: ",")))
        }
        return try await get("/v1/votes/\(escaped(id))", query: query)
    }

    /// A member with how often they side with their own party.
    public func member(id: String) async throws -> MemberDetail {
        try await get("/v1/members/\(escaped(id))")
    }

    /// A member's recent votes, newest first.
    public func memberVotes(id: String, limit: Int = 20) async throws -> MemberVotes {
        try await get(
            "/v1/members/\(escaped(id))/votes",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    public func bill(id: String) async throws -> Bill {
        try await get("/v1/bills/\(escaped(id))")
    }

    public func nomination(id: String) async throws -> Nomination {
        try await get("/v1/nominations/\(escaped(id))")
    }

    /// How fresh each ingest source is. `ok` is false when any is stale.
    ///
    /// Never cached: a saved answer to "how fresh is the data" would be wrong by exactly its age.
    public func status() async throws -> DataStatus {
        try await get("/v1/status", cacheable: false)
    }

    // MARK: - Plumbing

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw FloorAPIError.http(status: -1, message: "Bad base URL")
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw FloorAPIError.http(status: -1, message: "Bad request URL")
        }
        return url
    }

    /// The cache key: host (and port, if any), path and percent-encoded query, without the scheme.
    /// The host keeps a Debug build's localhost responses apart from the deployment's; the encoded
    /// query keeps a value holding `&` or `=` from reading as a second parameter.
    static func cacheKey(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        var key = components.host ?? ""
        if let port = components.port { key += ":\(port)" }
        key += components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        return key
    }

    /// Thrown by a ``savedOnly()`` copy for a request with nothing saved.
    private struct NotSaved: Error {}

    private func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], cacheable: Bool = true
    ) async throws -> T {
        let requestURL = try url(path, query: query)
        let key = Self.cacheKey(requestURL)

        if let record {
            guard cacheable, let cache, let saved = await cache.load(key, now: now()) else { throw NotSaved() }
            let value: T = try decode(saved.body)
            await record.note(saved.fetchedAt)
            return value
        }

        var request = URLRequest(url: requestURL)
        // Belt and braces for an injected session that does have a URLCache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled task (a screen that went away) is not being offline; callers must be able
            // to tell the two apart, or a cancelled refresh gets reported as a failed one.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            throw FloorAPIError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Every route answers a 4xx with `{ "error": ... }`, phrased for a person. Fall back to
            // the bare status if the body is something else, e.g. a proxy's error page.
            let message = try? JSONDecoder().decode(APIError.self, from: data).error
            throw FloorAPIError.http(status: status, message: message)
        }

        let value: T = try decode(data)
        if cacheable, let cache { await cache.save(data, for: key, at: now()) }
        return value
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FloorAPIError.decoding(error)
        }
    }
}
