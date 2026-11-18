import DesignSystem
import Foundation
import Models
import SwiftUI

// Posts rebuilt (v0.2.58, Arena, https://claude.ai/artifact/HP3nZFoQ4jUppnjKsC1MfV, `.post`): who
// said it first (portrait, network badge, name, party, handle, time), the text at reading size, then
// a video, photo or link card from what the post itself carries. Floor never fetches a linked page.

// MARK: - Parts

/// What a post card draws, read from the post alone: its text, its media, and a thread line.
public struct PostParts: Equatable, Sendable {
    public enum Media: Equatable, Sendable {
        case none
        /// A YouTube video: drawn with a play button. (A Bluesky video's thumbnail is a photo.)
        case video(URL)
        case photo(URL)
        /// A post with a link and an image: the image, the link's domain and its address as written.
        case link(image: URL, domain: String, address: String)
    }

    /// The text as shown: the post's own, less the link when the link has a card of its own.
    public var text: String
    public var media: Media
    /// `Thread · 2 posts` for a post ending in `(1/2)`, `Thread` for one ending in `1/`.
    public var thread: String?

    public init(_ post: MemberPost) {
        let raw = (post.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let image = post.mediaUrl.flatMap(URL.init(string:))
        thread = Self.thread(raw)
        guard let image else {
            text = raw
            media = .none
            return
        }
        let isVideo = post.network == .youtube
        if !isVideo, let link = Self.link(in: raw) {
            var shown = raw
            shown.removeSubrange(link.range)
            text = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            media = .link(image: image, domain: link.domain, address: link.address)
        } else {
            text = raw
            media = isVideo ? .video(image) : .photo(image)
        }
    }

    /// Only the literal patterns: `(1/N)` at the end, or a bare `1/` at the end.
    static func thread(_ text: String) -> String? {
        if let match = text.firstMatch(of: /\(1\/(\d{1,2})\)\s*$/), let count = Int(match.1), count > 1 {
            return "Thread · \(count) posts"
        }
        if text.firstMatch(of: /(^|\s)1\/\s*$/) != nil { return "Thread" }
        return nil
    }

    /// The first web address in the text: with a scheme, starting `www.`, or a bare `site.tld/path`.
    static func link(in text: String) -> (range: Range<String.Index>, domain: String, address: String)? {
        let pattern = /(?:https?:\/\/|www\.)[^\s]+|\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\/[^\s]*/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        var address = String(match.0)
        while let last = address.last, ".,;:)!?\"'".contains(last), !address.hasSuffix("...") { address.removeLast() }
        let bare = address.replacing(/^https?:\/\//, with: "")
        let host = bare.split(separator: "/").first.map(String.init) ?? bare
        let domain = host.replacing(/^www\./, with: "")
        guard domain.contains(".") else { return nil }
        let shown = bare.replacing(/^www\./, with: "").replacingOccurrences(of: "...", with: "…")
        return (match.range, domain, shown)
    }
}

public extension PostText {
    /// `10:16 AM`, in the environment's zone: a post's time under a day divider.
    static func time(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// The account the post came from: the member's own handle on that network, else the one in the
    /// post's address (Bluesky's `profile/<handle>`, Mastodon's `instance/@user`), else nil.
    static func handle(_ post: MemberPost, member: Member?) -> String? {
        let listed = member?.social?.links.first { $0.network == post.network.social }?.handle
        if let listed, !listed.hasPrefix("http") {
            return listed.hasPrefix("@") ? listed : "@\(listed)"
        }
        guard let url = URL(string: post.url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch post.network {
        case .bluesky:
            if parts.count >= 2, parts[0] == "profile" { return "@\(parts[1])" }
        case .mastodon:
            if let user = parts.first, user.hasPrefix("@"), let host = url.host { return "\(user)@\(host)" }
        case .youtube:
            if let user = parts.first, user.hasPrefix("@") { return user }
        }
        return nil
    }

    /// `D-NY`: the party chip beside the name.
    static func partyChip(_ member: Member) -> String { "\(member.party)-\(member.state)" }

    /// `Today`, `Yesterday`, `Thu, Nov 13`: a day divider on the wall, in the reader's calendar.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The posts under their day dividers, newest first, in the reader's calendar.
    static func days(_ posts: [MemberPost], now: Date, calendar: Calendar) -> [(title: String, posts: [MemberPost])] {
        var out: [(title: String, posts: [MemberPost])] = []
        for post in posts {
            let title = post.postedDate.map { day($0, now: now, calendar: calendar) } ?? "Undated"
            if out.last?.title == title { out[out.count - 1].posts.append(post) } else { out.append((title, [post])) }
        }
        return out
    }

    /// `Opens the post on Bluesky`, what the round arrow says.
    static func opens(_ network: MemberPost.Network) -> String { "Opens the post on \(network.name)" }
}

// MARK: - Card

/// One post as written (`.post`): the portrait badged with its network, the name with a party chip,
/// the handle and time, the round open arrow, then the text and the post's own media. Tapping the
/// card opens the post on its network. No counts.
public struct PostCard: View {
    /// How the header prints the time.
    public enum When: Sendable {
        /// `Nov 16 · 6:06 PM`: on a member's page.
        case dateAndTime
        /// `6:06 PM`: on the wall, under a day divider, with the handle read from the post's address.
        case time
    }

    let post: MemberPost
    let member: Member?
    let lineLimit: Int?
    let when: When

    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    /// - Parameters:
    ///   - member: whose post it is, for the portrait, name and party; nil draws the network alone.
    ///   - lineLimit: the member page clips text at five lines with "More"; nil shows it all.
    public init(post: MemberPost, member: Member?, lineLimit: Int? = nil, when: When = .dateAndTime) {
        self.post = post
        self.member = member
        self.lineLimit = lineLimit
        self.when = when
    }

    static let radius: CGFloat = 20
    /// The tallest a photo or video gets.
    static let mediaCap: CGFloat = 220
    @ScaledMetric(relativeTo: .subheadline) private var avatar: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var arrow: CGFloat = 30

    private var parts: PostParts { PostParts(post) }
    private var url: URL? { URL(string: post.url) }

    private var whenText: String? {
        post.postedDate.map {
            when == .time ? PostText.time($0, timeZone: timeZone, locale: locale) : PostText.when($0, timeZone: timeZone, locale: locale)
        }
    }

    /// On a member's page, their own account on that network; on the wall (which carries no
    /// accounts), the one in the post's address, or the time alone when it has none (YouTube).
    private var handleLine: String {
        let handle = when == .time
            ? PostText.handle(post, member: nil)
            : PostText.handle(post, member: member) ?? post.network.name
        return [handle, whenText].compactMap(\.self).joined(separator: " · ")
    }

    public var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12)
            if !parts.text.isEmpty { text(parts.text).padding(.horizontal, 14).padding(.top, 9) }
            media(parts.media).padding(.horizontal, 14).padding(.top, 12)
            if let thread = parts.thread {
                Text(thread)
                    .scaledFont(Typography.Post.thread, weight: .bold)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
            }
        }
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard(cornerRadius: Self.radius, fill: LinearGradient(colors: [Palette.postTop, Palette.postBottom], startPoint: .top, endPoint: .bottom))
        .contentShape(.rect)
        .onTapGesture { if let url { openURL(url) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(parts))
        .accessibilityHint(PostText.opens(post.network))
        .accessibilityAddTraits(url == nil ? [] : .isLink)
        .accessibilityAction { if let url { openURL(url) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            portrait
            VStack(alignment: .leading, spacing: 2) {
                if let member {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(member.fullName)
                            .scaledFont(Typography.Post.name, weight: .bold)
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PostText.partyChip(member))
                            .scaledFont(Typography.Post.party, weight: .heavy)
                            .foregroundStyle(Palette.partyInk(member.party))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.partyTint(member.party), in: .rect(cornerRadius: 4))
                            .fixedSize()
                    }
                }
                Text(handleLine)
                    .scaledFont(Typography.Post.handle)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.system(size: arrow * 0.43, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: arrow, height: arrow)
                .background(Palette.chip, in: .circle)
                .accessibilityHidden(true)
        }
    }

    private var portrait: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let member {
                    MemberPortrait(member)
                } else {
                    Circle().fill(Palette.chip)
                }
            }
            .frame(width: avatar, height: avatar)
            networkBadge.offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var brand: Color {
        switch post.network {
        case .bluesky: Palette.bluesky
        case .youtube: Palette.youtube
        case .mastodon: Palette.mastodon
        }
    }

    private var networkBadge: some View {
        ZStack {
            // YouTube's play triangle is cut out of its mark: white behind it, as the logo has.
            if post.network == .youtube {
                Rectangle().fill(Palette.bandText).frame(width: badge * 0.34, height: badge * 0.3)
            }
            NetworkMark(post.network.social).fill(brand)
        }
        .frame(width: badge * 0.67, height: badge * 0.67)
        .frame(width: badge, height: badge)
        .background(Palette.postTop, in: .circle)
        .padding(2)
        .background(Palette.postTop, in: .circle)
    }

    // MARK: Text

    @ViewBuilder
    private func text(_ text: String) -> some View {
        let limit = expanded ? nil : lineLimit
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text)
                .scaledFont(Typography.Post.body)
                .foregroundStyle(Palette.text)
                .lineSpacing(4)
                .lineLimit(limit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .top) {
                    if limit != nil {
                        // The whole text, unclipped and hidden, so the card knows whether "More" is due.
                        Text(verbatim: text)
                            .scaledFont(Typography.Post.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                }
            if limit != nil, fullHeight > shownHeight + 1 {
                Button { expanded = true } label: {
                    Text("More")
                        .scaledFont(Typography.Post.body, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Media

    @ViewBuilder
    private func media(_ media: PostParts.Media) -> some View {
        switch media {
        case .none:
            EmptyView()
        case let .photo(url):
            frame(url)
        case let .video(url):
            frame(url).overlay { playButton }
        case let .link(image, domain, address):
            HStack(spacing: 0) {
                remote(image).frame(width: 96).frame(minHeight: 84).clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(domain).scaledFont(Typography.Post.linkSite, weight: .semibold).foregroundStyle(Palette.textMuted)
                    Text(address)
                        .scaledFont(Typography.Post.linkTitle, weight: .bold)
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.cardBorder, lineWidth: 1))
        }
    }

    /// 16:9, full width, capped, the image filling it.
    private func frame(_ url: URL) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Self.mediaCap)
            .overlay { remote(url) }
            .clipShape(.rect(cornerRadius: 14))
    }

    private func remote(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Palette.chip
            }
        }
        .accessibilityHidden(true)
    }

    private var playButton: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 20))
            .foregroundStyle(Palette.bandText)
            .offset(x: 2)
            .frame(width: 54, height: 54)
            .background(Palette.playScrim, in: .circle)
            .overlay(Circle().strokeBorder(Palette.playRing, lineWidth: 1.5))
            .accessibilityHidden(true)
    }

    private func spoken(_ parts: PostParts) -> String {
        let who = member.map { "\($0.fullName) on \(post.network.name)" } ?? post.network.name
        var pieces = [who, whenText, parts.text.isEmpty ? nil : parts.text]
        switch parts.media {
        case .video: pieces.append("Video")
        case .photo: pieces.append("Photo")
        case let .link(_, domain, _): pieces.append("Link to \(domain)")
        case .none: break
        }
        pieces.append(parts.thread)
        return pieces.compactMap(\.self).joined(separator: ". ")
    }
}
