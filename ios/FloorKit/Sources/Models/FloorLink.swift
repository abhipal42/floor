import Foundation

/// The `floor://` links the widgets and alerts open the app with, and the share link
/// `https://floor-web-seven.vercel.app/bill/119/hr/5267` when iOS hands it to the app (a universal link).
///
/// One type builds them (the widget) and parses them (the app's `onOpenURL`), so the two can't
/// disagree about the shape. The scheme is registered under `CFBundleURLTypes` in `ios/project.yml`,
/// the domain under `com.apple.developer.associated-domains`.
///
/// Any app on the phone can open a `floor://` URL, so a link is input, not trust: a vote id must
/// be exactly the shape the API issues, `house-119-2-321` or `senate-119-2-258`, and a bill id
/// `119-hr-1013`, in ASCII. Anything else is refused before it reaches a screen or a request.
public enum FloorLink: Sendable, Hashable {
    /// The vote screen for one roll call: `floor://vote/house-119-2-321`.
    case vote(id: String)
    /// The bill screen: `floor://bill/119-hr-1013`, which a bill alert opens, or the share link.
    case bill(id: String)
    /// Just the app, wherever it was: `floor://open`. The widget's empty and error states.
    case open

    public static let scheme = "floor"
    /// The hosts whose `/bill/{congress}/{type}/{number}` pages are share links (the API serves them).
    /// Not floor.app, the design's domain: someone else owns it (HANDOFF lesson 71). Change this,
    /// `FLOOR_APPLINKS_DOMAIN` and the API's `DEFAULT_SHARE_BASE` together.
    public static let shareHost = "floor-web-seven.vercel.app"
    public static let shareHosts: Set<String> = [shareHost]
    /// The origin share links are built on.
    public static let shareBase = "https://\(shareHost)"

    public var url: URL {
        switch self {
        case let .vote(id):
            // A valid id needs no escaping; an invalid one is escaped so it can't change the
            // link's shape, and `init(url:)` refuses it anyway.
            let escaped = id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? ""
            return URL(string: "\(Self.scheme)://vote/\(escaped)") ?? URL(string: "\(Self.scheme)://open")!
        case let .bill(id):
            let escaped = id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? ""
            return URL(string: "\(Self.scheme)://bill/\(escaped)") ?? URL(string: "\(Self.scheme)://open")!
        case .open:
            return URL(string: "\(Self.scheme)://open")!
        }
    }

    /// Reads a link back, or nil for anything that isn't one of ours: another scheme, an unknown
    /// host, a vote link whose id isn't a roll call id.
    public init?(url: URL) {
        // The encoded path, so an escaped `/` inside an id is not read as a separator; then the id
        // must still match its shape once decoded.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            String($0).removingPercentEncoding
        }
        if url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), Self.shareHosts.contains(host) {
            // https://floor-web-seven.vercel.app/bill/119/hr/1013
            guard parts.count == 4, parts[0] == "bill", let congress = parts[1], let type = parts[2], let number = parts[3]
            else { return nil }
            let id = "\(congress)-\(type)-\(number)"
            guard Self.isBillId(id) else { return nil }
            self = .bill(id: id)
            return
        }
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "vote":
            guard parts.count == 1, let id = parts[0], Self.isVoteId(id) else { return nil }
            self = .vote(id: id)
        case "bill":
            guard parts.count == 1, let id = parts[0], Self.isBillId(id) else { return nil }
            self = .bill(id: id)
        case "open":
            self = .open
        default:
            return nil
        }
    }

    /// `^(house|senate)-\d+-\d+-\d+$`, ASCII digits only: chamber, congress, session, roll.
    public static func isVoteId(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "house" || parts[0] == "senate" else { return false }
        return parts.dropFirst().allSatisfy { part in
            !part.isEmpty && part.count <= 6 && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// `^\d{2,3}-(hr|s|hres|sres|hjres|sjres|hconres|sconres)-\d{1,5}$`, ASCII digits only.
    public static func isBillId(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        let digits = { (part: Substring, range: ClosedRange<Int>) in
            range.contains(part.count) && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
        return parts.count == 3 && digits(parts[0], 2...3) && billTypes.contains(String(parts[1])) && digits(parts[2], 1...5)
            && parts[2].first != "0"
    }

    private static let billTypes: Set<String> = ["hr", "s", "hres", "sres", "hjres", "sjres", "hconres", "sconres"]

    private static let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
}
