import Foundation
import Models

/// A URLSession client for the Floor API.
///
/// One method per route in `apps/api/openapi.json`, each returning a model from `Models`. The
/// models carry no networking and this carries no view logic, so a screen talks to this and nothing
/// else knows about HTTP.
public struct FloorAPI: Sendable {
    private let baseURL: URL
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: the API's origin, e.g. `https://api.floor.app` or ``localDevelopment``. Set it
    ///     from the build configuration so staging and production builds differ only here.
    ///   - session: injectable so tests can stub transport.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `npm run dev -w @floor/api` serves here.
    public static let localDevelopment = URL(string: "http://localhost:8787")!

    // MARK: - Routes

    /// The district an address falls in, with its representative and senators.
    ///
    /// The address goes to this endpoint and nowhere else. The server passes it to the U.S. Census
    /// geocoder and neither stores nor logs it, and neither does this client — do not add logging
    /// here that would put it in a device console or a crash report.
    public func reps(address: String) async throws -> Reps {
        try await get("/v1/reps", query: [URLQueryItem(name: "address", value: address)])
    }

    /// The district a point falls in, with its members. Each coordinate is rounded to 4 decimals
    /// (about 11 m) before it leaves the phone; the server rounds again. Like the address, the
    /// point goes to this endpoint and nowhere else — never log it. A 404 means the point is not in
    /// a U.S. congressional district.
    public func reps(latitude: Double, longitude: Double) async throws -> Reps {
        try await get("/v1/reps", query: [
            URLQueryItem(name: "lat", value: Self.coordinate(latitude)),
            URLQueryItem(name: "lng", value: Self.coordinate(longitude)),
        ])
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
    public func status() async throws -> DataStatus {
        try await get("/v1/status")
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

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: try url(path, query: query))
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

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FloorAPIError.decoding(error)
        }
    }
}
