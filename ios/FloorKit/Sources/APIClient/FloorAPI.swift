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
/// ``revalidate(_:_:)`` uses to open a screen on its last-seen data.
public struct FloorAPI: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let cache: (any ResponseCache)?
    private let now: @Sendable () -> Date
    /// Non-nil on a ``savedOnly()`` copy: requests are answered from the cache and recorded here.
    private let reads: SavedReads?

    /// - Parameters:
    ///   - baseURL: the API's origin, e.g. `https://api.floor.app` or ``localDevelopment``. Set it
    ///     from the build configuration so staging and production builds differ only here.
    ///   - session: injectable so tests can stub transport.
    ///   - cache: where responses are saved for offline. nil keeps nothing, as previews do.
    ///   - now: the clock the cache dates entries by; injectable for tests.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        cache: (any ResponseCache)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(baseURL: baseURL, session: session, cache: cache, now: now, reads: nil)
    }

    private init(
        baseURL: URL, session: URLSession, cache: (any ResponseCache)?, now: @escaping @Sendable () -> Date,
        reads: SavedReads?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cache = cache
        self.now = now
        self.reads = reads
    }

    /// This client answering only from saved responses, and a record of how old the ones it served
    /// were. nil without a cache. A request with nothing saved throws rather than going to the network.
    public func savedOnly() -> (api: FloorAPI, reads: SavedReads)? {
        guard cache != nil else { return nil }
        let reads = SavedReads()
        return (FloorAPI(baseURL: baseURL, session: session, cache: cache, now: now, reads: reads), reads)
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

    /// The cache key: path and query as sent, without the origin.
    private func cacheKey(_ path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty else { return path }
        return path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    /// Thrown by a ``savedOnly()`` copy for a request with nothing saved.
    private struct NotSaved: Error {}

    private func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], cacheable: Bool = true
    ) async throws -> T {
        let requestURL = try url(path, query: query)
        let key = cacheKey(path, query: query)

        if let reads {
            guard cacheable, let cache, let saved = await cache.load(key, now: now()) else { throw NotSaved() }
            let value: T = try decode(saved.body)
            await reads.note(saved.fetchedAt)
            return value
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
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
