import Foundation

/// The `floor://` links the widgets open the app with.
///
/// One type builds them (the widget) and parses them (the app's `onOpenURL`), so the two can't
/// disagree about the shape. The scheme is registered under `CFBundleURLTypes` in `ios/project.yml`.
///
/// Any app on the phone can open a `floor://` URL, so a link is input, not trust: a vote id must
/// be exactly the shape the API issues, `house-119-2-321` or `senate-119-2-258`, in ASCII.
/// Anything else is refused before it reaches a screen or a request.
public enum FloorLink: Sendable, Hashable {
    /// The vote screen for one roll call: `floor://vote/house-119-2-321`.
    case vote(id: String)
    /// Just the app, wherever it was: `floor://open`. The widget's empty and error states.
    case open

    public static let scheme = "floor"

    public var url: URL {
        switch self {
        case let .vote(id):
            // A valid id needs no escaping; an invalid one is escaped so it can't change the
            // link's shape, and `init(url:)` refuses it anyway.
            let escaped = id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? ""
            return URL(string: "\(Self.scheme)://vote/\(escaped)") ?? URL(string: "\(Self.scheme)://open")!
        case .open:
            return URL(string: "\(Self.scheme)://open")!
        }
    }

    /// Reads a link back, or nil for anything that isn't one of ours: another scheme, an unknown
    /// host, a vote link whose id isn't a roll call id.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "vote":
            // The encoded path, so an escaped `/` inside an id is not read as a separator; then the
            // id must still match the roll call shape once decoded.
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard parts.count == 1, let id = parts.first.flatMap({ String($0).removingPercentEncoding }),
                  Self.isVoteId(id)
            else { return nil }
            self = .vote(id: id)
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

    private static let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
}
