import DesignSystem
import Models
import SwiftUI

// The member screen's Said and Posts segments and Contact's official accounts, built to the locked
// round 13 mock (https://claude.ai/artifact/M81jJLKd2HUNDjZJW3angV): section A direction 2, the
// swipe deck, with the no-platform browser frame; section B, the accounts grid; section C, posts.
// Where this differs from the mock, and why:
//
// - The deck's eyebrow is the site's own heading, whole ("DEFENDING AND EXPANDING MICHIGAN’S MIDDLE
//   CLASS · 2 OF 3"), not the mock's "Middle class": a shorter label would be Floor rewriting the
//   campaign's words, and the data carries no short one.
// - The no-platform frame can't draw the archived page itself (Floor keeps no screenshot), so its page
//   says "No issues listed" and links the archived copy; the verdict under it names the member rather
//   than "her", since Floor has no pronouns on file, and leaves out what else the page had.
// - Every post shows its date and time; the mock dropped the time on an older one, with no rule
//   behind it, and a clock-relative rule would make the screen depend on when it is drawn.
// - A YouTube post shows its thumbnail when the API gives one and nothing in its place otherwise;
//   the mock's grey "▶ VIDEO" box was a stand-in for the thumbnail.

// MARK: - Words

/// Every sentence the Said and Posts segments print, apart from the views so they can be tested.
public enum SaidText {
    /// `2024 CAMPAIGN · 3 PROMISES`.
    public static func deckLabel(_ said: MemberPromises) -> String {
        let count = said.promises.count
        let race = said.electionYear.map { "\($0) CAMPAIGN" } ?? "CAMPAIGN"
        return "\(race) · \(count) \(count == 1 ? "PROMISE" : "PROMISES")"
    }

    /// `DEFENDING AND EXPANDING MICHIGAN’S MIDDLE CLASS · 2 OF 3`.
    public static func eyebrow(_ promise: CampaignPromise, number: Int, of count: Int) -> String {
        let heading = promise.heading?.trimmingCharacters(in: .whitespaces).uppercased()
        return [heading?.isEmpty == false ? heading : "PROMISE", "\(number) OF \(count)"].compactMap(\.self)
            .joined(separator: " · ")
    }

    public static let aiLine = "Picked by AI, quoted exactly. It may miss some."
    public static let swipeHint = "Swipe for the next. The big line is the quote's own words, cut at a clause, never rewritten."
    public static let noFill = "Floor shows what the campaign published and doesn't fill the gap from news or speeches."

    /// `Archived Oct 12, 2024`, in the reader's zone.
    public static func archived(_ said: MemberPromises, timeZone: TimeZone, locale: Locale) -> String {
        guard let date = said.snapshotDate else { return "Archived copy" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        style.timeZone = timeZone
        return "Archived \(date.formatted(style))"
    }

    /// `WAYBACK` over `OCT 16 2024`, the stamp on an archived page.
    public static func stamp(_ said: MemberPromises, timeZone: TimeZone, locale: Locale) -> String {
        guard let date = said.snapshotDate else { return "WAYBACK" }
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().year()
        style.timeZone = timeZone
        return "WAYBACK\n" + date.formatted(style).replacingOccurrences(of: ",", with: "").uppercased()
    }

    /// `kirstengillibrand.com`, `elissaslotkin.org/priorities`: the address the frame shows.
    public static func address(_ said: MemberPromises) -> String? {
        guard let site = said.pageUrl ?? said.siteUrl, let url = URL(string: site), let host = url.host else { return nil }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return host.replacingOccurrences(of: "www.", with: "") + path
    }

    /// What Said says when there is no deck: a title and a line, saying exactly which gap it is.
    public static func gap(_ said: MemberPromises, name: String) -> (title: String, body: String) {
        let race = said.electionYear.map { "\($0) race" } ?? "race that won this term"
        switch said.status {
        case .promises, .noPlatform:
            return ("No issues listed", "\(name)'s \(said.electionYear.map { "\($0) " } ?? "")campaign site listed no issues.")
        case .noSite:
            return ("No campaign site on file",
                    "The FEC filings for \(name)'s \(race) list no campaign website, so there is nothing to quote. " + noFill)
        case .noSnapshot:
            let site = address(said) ?? "the campaign site"
            let day = said.electionYear.map { "election day \($0)" } ?? "election day"
            return ("No archived copy",
                    "The Internet Archive has no copy of \(site) from before \(day), so Floor can't show what it said during the race.")
        case .unchecked:
            return ("Not read yet",
                    "Floor hasn't read \(name)'s campaign site yet. It reads a few members' sites a day, from the "
                        + "Internet Archive's copy before election day.")
        }
    }
}

/// The words on a post.
public enum PostText {
    /// `Nov 16 · 5:01 PM`, in the environment's zone (HANDOFF lesson 69).
    public static func when(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var day = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
        day.timeZone = timeZone
        var time = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        time.timeZone = timeZone
        return "\(date.formatted(day)) · \(date.formatted(time))"
    }

    public static let footnote = "Posts as written, newest first, from YouTube, Bluesky and Mastodon. "
        + "X, Facebook and Instagram don't let apps read posts for free, so they're links."
}

// MARK: - AI tag

/// The violet AI tag (the bill screen's `.lab` look), with or without its line.
struct AITag: View {
    var body: some View {
        Text("AI")
            .font(Typography.label(11))
            .tracking(1.1)
            .foregroundStyle(Palette.aiInk)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Palette.ai, in: .rect(cornerRadius: 5))
            .fixedSize()
            .accessibilityLabel("AI")
    }
}

// MARK: - Said

struct SaidContent: View {
    let model: PromisesModel
    let member: Member?
    @Binding var card: Int
    let onOpenTopic: ((String) -> Void)?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load \(member?.lastName ?? "this member")'s campaign promises")
                        .scaledFont(15, weight: .semibold).foregroundStyle(Palette.text)
                    Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }
                .panel()
            case let .loaded(said):
                VStack(alignment: .leading, spacing: 10) {
                    if let saved = model.saved { SavedDataNote(saved) }
                    SaidFigures(said: said, name: member?.lastName ?? "This member", card: $card, onOpenTopic: onOpenTopic)
                }
            }
        }
        .task { if model.needsRefresh { await model.load() } }
    }
}

/// The deck, the no-platform frame, or the placeholder saying which gap it is.
struct SaidFigures: View {
    let said: MemberPromises
    let name: String
    @Binding var card: Int
    let onOpenTopic: ((String) -> Void)?

    var body: some View {
        switch said.status {
        case .promises where !said.promises.isEmpty:
            PromiseDeck(said: said, card: $card, onOpenTopic: onOpenTopic)
        case .promises, .noPlatform:
            ArchivedPageFrame(said: said, name: name)
        case .noSite, .noSnapshot, .unchecked:
            let gap = SaidText.gap(said, name: name)
            DashedPlaceholder(title: gap.title, body: gap.body)
        }
    }
}

/// One promise per card, stacked like the catch-up deck. Swipe or tap the dots; VoiceOver reads the
/// front card and swipes up or down through them; Reduce Motion swaps cards without the fly-off.
struct PromiseDeck: View {
    let said: MemberPromises
    @Binding var card: Int
    let onOpenTopic: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var drag: CGFloat = 0
    @State private var leaving: Int?
    @State private var leavingDirection: CGFloat = -1

    private var promises: [CampaignPromise] { said.promises }
    private var front: Int { min(max(card, 0), promises.count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(SaidText.deckLabel(said))
                    .font(Typography.label(11.5)).tracking(1.0).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 8)
                AITag()
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)

            deck
                .padding(.bottom, promises.count > 2 ? 14 : promises.count > 1 ? 7 : 0)

            if let topic = promises[front].topic, let onOpenTopic {
                Button { onOpenTopic(topic) } label: {
                    Text("Floor topic · \(topic) ›")
                        .font(Typography.label(12)).tracking(0.8).foregroundStyle(Palette.yea)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 2)
                .accessibilityLabel("Floor topic, \(topic)")
                .accessibilityHint("Opens the topic's bills")
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                AITag()
                Text(SaidText.aiLine)
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Palette.ai)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
            Text(SaidText.swipeHint)
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
        }
    }

    private var deck: some View {
        ZStack(alignment: .top) {
            // Every card is laid out, so the deck is as tall as its tallest and never jumps; only
            // the front one (and one flying off) is drawn.
            ForEach(Array(promises.enumerated()), id: \.offset) { index, promise in
                let isFront = index == front
                let isLeaving = index == leaving
                cardView(promise, number: index + 1)
                    .offset(x: isLeaving ? leavingDirection * 440 : isFront ? drag : 0)
                    .rotationEffect(.degrees(isLeaving ? Double(leavingDirection) * 8 : isFront ? Double(drag / 40) : 0))
                    .opacity(isFront ? 1 : 0)
                    .zIndex(isLeaving ? 2 : isFront ? 1 : 0)
                    .allowsHitTesting(isFront)
            }
        }
        .background(alignment: .top) { backCards }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    drag = value.translation.width
                }
                .onEnded { value in
                    let width = value.translation.width
                    if width < -60 { move(1) } else if width > 60 { move(-1) } else { settle() }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(promises[front], number: front + 1))
        .accessibilityValue("\(front + 1) of \(promises.count)")
        .accessibilityHint("Swipe up or down for the next or previous promise")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .accessibilityActions {
            if let url = said.snapshotUrl.flatMap(URL.init(string:)) {
                Button("Open the archived page") { openURL(url) }
            }
        }
    }

    /// The two cards peeking out under the front one, as on the Finals deck.
    private var backCards: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach([2, 1], id: \.self) { depth in
                    if promises.count > depth {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Palette.card.opacity(depth == 1 ? 0.8 : 0.5))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.panelBorder, lineWidth: 1))
                            .frame(height: geo.size.height)
                            .scaleEffect(1 - 0.04 * Double(depth), anchor: .bottom)
                            .offset(y: 7 * Double(depth))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func cardView(_ promise: CampaignPromise, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SaidText.eyebrow(promise, number: number, of: promises.count))
                .font(Typography.label(11.5))
                .tracking(1.4)
                .foregroundStyle(Palette.threshold)
                .fixedSize(horizontal: false, vertical: true)
            if !promise.headline.isEmpty {
                Text("“\(promise.headline)”".uppercased())
                    .font(Typography.headline(25))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(promise.quote)
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.threshold).frame(width: 2) }
            Spacer(minLength: 6)
            HStack(alignment: .center, spacing: 8) {
                dots
                Spacer(minLength: 6)
                if let url = said.snapshotUrl.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Text(SaidText.archived(said, timeZone: timeZone, locale: locale) + " ›")
                            .scaledFont(10.5, weight: .bold)
                            .foregroundStyle(Palette.textMuted)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Palette.deckGlow, Palette.panel], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.65)),
            in: .rect(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.panelBorder, lineWidth: 1))
        .shadow(color: Palette.shadow, radius: 18, y: 14)
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(promises.indices, id: \.self) { index in
                Button { jump(to: index) } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == front ? Palette.text : Palette.raised)
                        .frame(width: index == front ? 16 : 6, height: 6)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func spoken(_ promise: CampaignPromise, number: Int) -> String {
        let heading = promise.heading.map { "\($0). " } ?? ""
        return "Promise \(number) of \(promises.count), quoted from the campaign site. \(heading)\(promise.quote)"
    }

    private func settle() {
        if reduceMotion { drag = 0 } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 } }
    }

    private func jump(to index: Int) {
        guard index != front else { return }
        move(index - front)
    }

    private func move(_ step: Int) {
        let next = front + step
        guard promises.indices.contains(next), leaving == nil else { return settle() }
        if reduceMotion {
            drag = 0
            card = next
            return
        }
        leavingDirection = step > 0 ? -1 : 1
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            leaving = front
            card = next
            drag = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            leaving = nil
        }
    }
}

/// The campaign site as archived, in a browser frame, when it listed no issues: the page itself
/// shows the gap (mock, "When there's no platform").
struct ArchivedPageFrame: View {
    let said: MemberPromises
    let name: String
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.raised).frame(width: 7, height: 7)
                    Circle().fill(Palette.raised).frame(width: 7, height: 7)
                    Text(SaidText.address(said) ?? "campaign site")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(Palette.browserText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.browserField, in: .rect(cornerRadius: 5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.browserBar)
                page
            }
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The campaign site, \(SaidText.address(said) ?? "") as the Internet Archive kept it")

            Text(SaidText.gap(said, name: name).body)
                .scaledFont(11.5, weight: .bold)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(SaidText.noFill)
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var page: some View {
        VStack(spacing: 10) {
            Text("NO ISSUES LISTED")
                .font(Typography.headline(20))
                .foregroundStyle(Palette.paperInk)
            if let url = said.snapshotUrl.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Text(SaidText.archived(said, timeZone: timeZone, locale: locale) + " · open the copy ›")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Palette.paperText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(Palette.paper)
        .overlay(alignment: .topTrailing) {
            Text(SaidText.stamp(said, timeZone: timeZone, locale: locale))
                .font(.caption2.monospaced().weight(.heavy))
                .multilineTextAlignment(.leading)
                .foregroundStyle(Palette.wayback)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.wayback, lineWidth: 1.5))
                .rotationEffect(.degrees(6))
                .padding(8)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Posts

struct PostsContent: View {
    let model: PostsModel
    let member: Member?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load \(member?.lastName ?? "this member")'s posts")
                        .scaledFont(15, weight: .semibold).foregroundStyle(Palette.text)
                    Text(message).scaledFont(13).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                }
                .panel()
            case let .loaded(posts):
                VStack(alignment: .leading, spacing: 7) {
                    if let saved = model.saved { SavedDataNote(saved) }
                    PostsList(posts: posts, member: member)
                }
            }
        }
        .task { if model.needsRefresh { await model.load() } }
    }
}

/// One member's accounts as a row of marks, then their posts.
struct PostsList: View {
    let posts: MemberPosts
    let member: Member?

    private var name: String { member?.lastName ?? "This member" }

    /// What Posts says with nothing to show: not on a network Floor reads, or nothing lately.
    static func empty(member: Member?) -> (title: String, body: String) {
        let name = member?.lastName ?? "This member"
        if let social = member?.social, !social.links.contains(where: \.network.readable) {
            return ("\(name) isn't on YouTube, Bluesky or Mastodon",
                    "X, Facebook and Instagram don't let apps read posts for free, so \(name)'s accounts there are links above.")
        }
        return ("No recent posts", "Floor shows the last 30 days of \(name)'s posts on YouTube, Bluesky and Mastodon, and found none.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let accounts = AccountMarks.links(member: member, posts: posts)
            if !accounts.isEmpty { AccountMarks(links: accounts) }
            if posts.posts.isEmpty {
                let empty = Self.empty(member: member)
                DashedPlaceholder(title: empty.title, body: empty.body)
            }
            VStack(spacing: 12) {
                ForEach(posts.posts) { post in PostCard(post: post, member: member) }
            }
            .padding(.top, 4)
            Text(PostText.footnote)
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .padding(.top, 4)
        }
    }
}

/// The row of network marks at the top of Posts (round 13 polish, option 3): one per account, the
/// networks Floor reads first, each opening the member's profile there (the app when installed,
/// else the web). If they don't fit, the row scrolls.
struct AccountMarks: View {
    let links: [SocialLink]

    /// The networks Floor reads, then the ones it only links.
    nonisolated static let order: [SocialNetwork] = [.bluesky, .youtube, .mastodon, .x, .instagram, .facebook]

    /// The member's accounts, with the posts route's links-only profiles filling any the record lacks.
    nonisolated static func links(member: Member?, posts: MemberPosts?) -> [SocialLink] {
        var byNetwork: [SocialNetwork: SocialLink] = [:]
        for link in posts?.links?.links ?? [] { byNetwork[link.network] = link }
        for link in member?.social?.links ?? [] { byNetwork[link.network] = link }
        return order.compactMap { byNetwork[$0] }.filter { $0.url != nil }
    }

    /// `Bluesky, chuckschumer.bsky.social, posts shown in Floor`; `X, @SenSchumer, opens X`.
    nonisolated static func label(_ link: SocialLink) -> String {
        "\(link.network.name), \(link.displayHandle), "
            + (link.network.readable ? "posts shown in Floor" : "opens \(link.network.name)")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(links) { link in badge(link).frame(maxWidth: .infinity) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(links) { link in badge(link) }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func badge(_ link: SocialLink) -> some View {
        if let url = link.url {
            Link(destination: url) { NetworkBadge(link.network) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.label(link))
                .accessibilityAddTraits(.isLink)
        }
    }
}
