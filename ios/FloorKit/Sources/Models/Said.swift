import Foundation

// Round 13 (https://claude.ai/artifact/M81jJLKd2HUNDjZJW3angV): what a member's campaign site said,
// their official accounts, and their posts on the networks anyone can read for free.
//
// Decoded leniently, field by field, as `Disclosures` is: the routes were built in parallel with
// these screens, so a field this build does not know is ignored, a missing one reads as nil, and one
// bad element is dropped rather than failing the whole segment.

// MARK: - Official accounts

/// A member's official accounts, as handles (congress-legislators' social-media list, plus Bluesky
/// where Bluesky itself verified the account). The app builds the links (``SocialLink``).
public struct MemberSocial: Codable, Sendable, Hashable {
    public var twitter: String?
    public var facebook: String?
    public var instagram: String?
    /// The legacy YouTube user name; `youtubeId` is the channel, and the one Floor reads posts from.
    public var youtube: String?
    public var youtubeId: String?
    /// `@user@instance`, as congress-legislators writes it.
    public var mastodon: String?
    public var bluesky: String?

    public init(
        twitter: String? = nil, facebook: String? = nil, instagram: String? = nil, youtube: String? = nil,
        youtubeId: String? = nil, mastodon: String? = nil, bluesky: String? = nil
    ) {
        self.twitter = twitter
        self.facebook = facebook
        self.instagram = instagram
        self.youtube = youtube
        self.youtubeId = youtubeId
        self.mastodon = mastodon
        self.bluesky = bluesky
    }

    private enum CodingKeys: String, CodingKey {
        case twitter, facebook, instagram, youtube, youtubeId, mastodon, bluesky
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func handle(_ key: CodingKeys) -> String? {
            guard let text = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        twitter = handle(.twitter)
        facebook = handle(.facebook)
        instagram = handle(.instagram)
        youtube = handle(.youtube)
        youtubeId = handle(.youtubeId)
        mastodon = handle(.mastodon)
        bluesky = handle(.bluesky)
    }

    /// Every account listed, in the mock's order: X, Facebook, Instagram, YouTube, Bluesky, Mastodon.
    public var links: [SocialLink] {
        var out: [SocialLink] = []
        if let twitter { out.append(SocialLink(network: .x, handle: twitter)) }
        if let facebook { out.append(SocialLink(network: .facebook, handle: facebook)) }
        if let instagram { out.append(SocialLink(network: .instagram, handle: instagram)) }
        if youtube != nil || youtubeId != nil {
            out.append(SocialLink(network: .youtube, handle: youtube ?? youtubeId!, channelId: youtubeId))
        }
        if let bluesky { out.append(SocialLink(network: .bluesky, handle: bluesky)) }
        if let mastodon { out.append(SocialLink(network: .mastodon, handle: mastodon)) }
        return out.filter { $0.url != nil }
    }

    public var isEmpty: Bool { links.isEmpty }
}

/// The networks an official account can be on.
public enum SocialNetwork: String, Sendable, Hashable, CaseIterable {
    case x, facebook, instagram, youtube, bluesky, mastodon

    /// `X`, `Facebook`, …, as a person says it.
    public var name: String {
        switch self {
        case .x: "X"
        case .facebook: "Facebook"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .bluesky: "Bluesky"
        case .mastodon: "Mastodon"
        }
    }

    /// X, Facebook and Instagram charge for reading posts or need app review, so Floor links them
    /// and never shows their posts. The other three are read by the worker.
    public var readable: Bool {
        switch self {
        case .youtube, .bluesky, .mastodon: true
        case .x, .facebook, .instagram: false
        }
    }
}

/// One account and the link that opens it — the network's app when it is installed (universal links),
/// else its site.
public struct SocialLink: Sendable, Hashable, Identifiable {
    public var network: SocialNetwork
    /// As listed: a handle on `Member.social`, a full URL on the posts route's `links`.
    public var handle: String
    public var channelId: String?

    public init(network: SocialNetwork, handle: String, channelId: String? = nil) {
        self.network = network
        self.handle = handle
        self.channelId = channelId
    }

    public var id: String { network.rawValue }

    /// `@SenSchumer` on X; the handle as listed everywhere else.
    public var displayHandle: String {
        if handle.hasPrefix("http"), let url = URL(string: handle) {
            let name = url.path.split(separator: "/").last.map(String.init) ?? handle
            return network == .x ? "@\(name)" : name
        }
        return network == .x && !handle.hasPrefix("@") ? "@\(handle)" : handle
    }

    public var url: URL? {
        if handle.hasPrefix("https://") { return URL(string: handle) }
        let bare = handle.hasPrefix("@") && network != .mastodon ? String(handle.dropFirst()) : handle
        guard let path = bare.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])),
              !path.isEmpty else { return nil }
        switch network {
        case .x: return URL(string: "https://x.com/\(path)")
        case .facebook: return URL(string: "https://www.facebook.com/\(path)")
        case .instagram: return URL(string: "https://www.instagram.com/\(path)")
        case .youtube:
            if let channelId { return URL(string: "https://www.youtube.com/channel/\(channelId)") }
            return URL(string: "https://www.youtube.com/\(path)")
        case .bluesky: return URL(string: "https://bsky.app/profile/\(path)")
        case .mastodon:
            // `@user@instance` → https://instance/@user
            let parts = handle.split(separator: "@").map(String.init)
            guard parts.count == 2 else { return nil }
            return URL(string: "https://\(parts[1])/@\(parts[0])")
        }
    }
}

// MARK: - Campaign promises

/// `GET /v1/members/{id}/promises`: what the member's own campaign site said in the race that won
/// this term, from the Internet Archive's last copy before election day.
///
/// Quotes only: the AI picks lines and never rewrites them, and the worker drops any quote (or
/// headline) that is not word for word on the archived page. Never lined up against votes.
public struct MemberPromises: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        case promises
        /// The site was found and archived, but listed no issues.
        case noPlatform = "no_platform"
        /// No campaign website in the member's FEC filings.
        case noSite = "no_site"
        /// A site, but no archived copy from before election day.
        case noSnapshot = "no_snapshot"
        /// The worker has not looked yet (or a status this build does not know).
        case unchecked
    }

    public var status: Status
    public var electionYear: Int?
    public var siteUrl: String?
    public var snapshotUrl: String?
    /// ISO 8601 instant of the archived copy.
    public var snapshotAt: String?
    /// The issues page within the site, when there was one.
    public var pageUrl: String?
    public var promises: [CampaignPromise]

    public init(
        status: Status, electionYear: Int? = nil, siteUrl: String? = nil, snapshotUrl: String? = nil,
        snapshotAt: String? = nil, pageUrl: String? = nil, promises: [CampaignPromise] = []
    ) {
        self.status = status
        self.electionYear = electionYear
        self.siteUrl = siteUrl
        self.snapshotUrl = snapshotUrl
        self.snapshotAt = snapshotAt
        self.pageUrl = pageUrl
        self.promises = promises
    }

    private enum CodingKeys: String, CodingKey {
        case status, electionYear, siteUrl, snapshotUrl, snapshotAt, pageUrl, promises
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        electionYear = try? c.decodeIfPresent(Int.self, forKey: .electionYear)
        siteUrl = try? c.decodeIfPresent(String.self, forKey: .siteUrl)
        snapshotUrl = try? c.decodeIfPresent(String.self, forKey: .snapshotUrl)
        snapshotAt = try? c.decodeIfPresent(String.self, forKey: .snapshotAt)
        pageUrl = try? c.decodeIfPresent(String.self, forKey: .pageUrl)
        promises = ((try? c.decodeIfPresent([LossyElement<CampaignPromise>].self, forKey: .promises)) ?? [])
            .compactMap(\.value)
        status = raw.flatMap(Status.init(rawValue:)) ?? .unchecked
        // "promises" with none to show, or with no archived copy to cite, is not a deck: a quote
        // Floor can't link to its source is not shown (product rule "AI is labelled and cited").
        if status == .promises, promises.isEmpty || snapshotUrl == nil {
            status = snapshotUrl == nil ? .noSnapshot : .noPlatform
            promises = []
        }
    }

    /// What a phone reads from an API without the route yet (its 404): not checked.
    public static let unchecked = MemberPromises(status: .unchecked)

    public var snapshotDate: Date? { snapshotAt.flatMap(Formats.instant) }
}

/// One promise: a quote from the campaign site, word for word, with a clause of it as the headline.
public struct CampaignPromise: Codable, Sendable, Hashable {
    /// The site's own section heading, as written.
    public var heading: String?
    public var quote: String
    /// A fragment of `quote`, verbatim.
    public var headline: String
    /// One of Floor's 32 topics, or nil.
    public var topic: String?

    public init(heading: String?, quote: String, headline: String, topic: String?) {
        self.heading = heading
        self.quote = quote
        self.headline = headline
        self.topic = topic
    }

    private enum CodingKeys: String, CodingKey { case heading, quote, headline, topic }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quote = try c.decode(String.self, forKey: .quote)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .quote, in: c, debugDescription: "empty quote")
        }
        heading = (try? c.decodeIfPresent(String.self, forKey: .heading)) ?? nil
        let headline = ((try? c.decodeIfPresent(String.self, forKey: .headline)) ?? nil) ?? ""
        // The headline must be the quote's own words; one that is not is dropped, never shown.
        self.headline = Self.isFragment(headline, of: quote) ? headline : ""
        topic = ((try? c.decodeIfPresent(String.self, forKey: .topic)) ?? nil).flatMap(Topic.canonical)
    }

    /// True when `fragment` appears in `quote`, case, whitespace and curly quotes aside.
    static func isFragment(_ fragment: String, of quote: String) -> Bool {
        func fold(_ text: String) -> String {
            text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let part = fold(fragment)
        return !part.isEmpty && fold(quote).contains(part)
    }
}

// MARK: - Posts

/// One post as written, from a network anyone can read for free. No counts: Floor never shows
/// likes or reposts, and never ranks one member's posts over another's.
public struct MemberPost: Codable, Sendable, Hashable, Identifiable {
    public enum Network: String, Codable, Sendable, Hashable, CaseIterable {
        case youtube, bluesky, mastodon

        public var name: String {
            switch self {
            case .youtube: "YouTube"
            case .bluesky: "Bluesky"
            case .mastodon: "Mastodon"
            }
        }
    }

    /// `<network>:<native id>`.
    public var id: String
    public var network: Network
    /// ISO 8601 instant.
    public var postedAt: String
    /// As posted; a YouTube video's title.
    public var text: String?
    /// The original.
    public var url: String
    /// A YouTube thumbnail, or a Bluesky post's first image.
    public var mediaUrl: String?
    /// Whose it is: only on the combined wall (`/v1/posts`).
    public var memberId: String?

    public init(
        id: String, network: Network, postedAt: String, text: String?, url: String, mediaUrl: String? = nil,
        memberId: String? = nil
    ) {
        self.id = id
        self.network = network
        self.postedAt = postedAt
        self.text = text
        self.url = url
        self.mediaUrl = mediaUrl
        self.memberId = memberId
    }

    private enum CodingKeys: String, CodingKey { case id, network, postedAt, text, url, mediaUrl, memberId }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        network = try c.decode(Network.self, forKey: .network)
        postedAt = try c.decode(String.self, forKey: .postedAt)
        url = try c.decode(String.self, forKey: .url)
        guard URL(string: url) != nil, Formats.instant(postedAt) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "unreadable post")
        }
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        mediaUrl = (try? c.decodeIfPresent(String.self, forKey: .mediaUrl)) ?? nil
        memberId = (try? c.decodeIfPresent(String.self, forKey: .memberId)) ?? nil
    }

    public var postedDate: Date? { Formats.instant(postedAt) }

    /// Newest first, as every list of posts reads; ties keep the order they came in.
    static func newestFirst(_ posts: [MemberPost]) -> [MemberPost] {
        posts.enumerated().sorted { a, b in
            let (x, y) = (a.element.postedDate ?? .distantPast, b.element.postedDate ?? .distantPast)
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }
}

/// The links-only networks on the posts route: full profile URLs for X, Facebook and Instagram.
public struct PostLinks: Codable, Sendable, Hashable {
    public var x: String?
    public var facebook: String?
    public var instagram: String?

    public init(x: String? = nil, facebook: String? = nil, instagram: String? = nil) {
        self.x = x
        self.facebook = facebook
        self.instagram = instagram
    }

    private enum CodingKeys: String, CodingKey { case x, facebook, instagram }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decodeIfPresent(String.self, forKey: .x)) ?? nil
        facebook = (try? c.decodeIfPresent(String.self, forKey: .facebook)) ?? nil
        instagram = (try? c.decodeIfPresent(String.self, forKey: .instagram)) ?? nil
    }

    public var links: [SocialLink] {
        [(SocialNetwork.x, x), (.facebook, facebook), (.instagram, instagram)].compactMap { network, handle in
            guard let handle, !handle.isEmpty else { return nil }
            let link = SocialLink(network: network, handle: handle)
            return link.url == nil ? nil : link
        }
    }
}

/// `GET /v1/members/{id}/posts`: newest first, at most 30.
public struct MemberPosts: Codable, Sendable, Hashable {
    public var posts: [MemberPost]
    public var links: PostLinks?

    public init(posts: [MemberPost], links: PostLinks? = nil) {
        self.posts = posts
        self.links = links
    }

    private enum CodingKeys: String, CodingKey { case posts, links }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = MemberPost.newestFirst(
            ((try? c.decodeIfPresent([LossyElement<MemberPost>].self, forKey: .posts)) ?? []).compactMap(\.value)
        )
        links = (try? c.decodeIfPresent(PostLinks.self, forKey: .links)) ?? nil
    }

    /// An API without the route yet (its 404): no posts, no links.
    public static let none = MemberPosts(posts: [])
}

/// `GET /v1/posts?members=…`: the combined wall for up to 12 members.
public struct PostsWall: Codable, Sendable, Hashable {
    /// Each carries `memberId`.
    public var posts: [MemberPost]
    /// Members with no account on a network Floor can read: the wall's "posts on X and Facebook" note.
    public var unreadable: [String]

    public init(posts: [MemberPost], unreadable: [String] = []) {
        self.posts = posts
        self.unreadable = unreadable
    }

    private enum CodingKeys: String, CodingKey { case posts, unreadable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = MemberPost.newestFirst(
            ((try? c.decodeIfPresent([LossyElement<MemberPost>].self, forKey: .posts)) ?? [])
                .compactMap(\.value).filter { $0.memberId != nil }
        )
        unreadable = ((try? c.decodeIfPresent([LossyElement<String>].self, forKey: .unreadable)) ?? []).compactMap(\.value)
    }

    /// The most members one request may ask for.
    public static let memberLimit = 12

    public static let none = PostsWall(posts: [])
}
