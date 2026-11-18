import APIClient
import DesignSystem
import Models
import Onboarding
import SwiftUI

/// One member's page: from the Following tab, from a vote's "Your members", or from search.
///
/// One scroll since v0.2.58 (the locked option B, drawn in Arena): the party-colour hero with
/// Follow, the record's three numbers and the last-40 streak, sticky jump chips, then Votes, Said,
/// Posts, Money and Contact. Each block's link opens that segment whole on its own screen
/// (``MemberSectionPage``). Your own reps read "Your senator" or "Your rep" in the eyebrow instead
/// of a Follow button: they come from your district and can be hidden on Following, not unfollowed.
public struct RepScreenView: View {
    @State private var model: RepScreenModel
    @State private var page: MemberSection?
    private let follows: Follows?
    private let reps: Set<String>
    private let onOpenTopic: ((String) -> Void)?
    private let onOpenVote: (Vote) -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - follows: the follow list; nil shows no Follow button (previews of the record alone).
    ///   - reps: Bioguide IDs of your own district's members.
    ///   - onOpenTopic: opens a topic's page from a promise; nil leaves the link out.
    public init(
        model: RepScreenModel, follows: Follows? = nil, reps: [String] = [],
        onOpenTopic: ((String) -> Void)? = nil,
        onOpenVote: @escaping (Vote) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.follows = follows
        self.reps = Set(reps)
        self.onOpenTopic = onOpenTopic
        self.onOpenVote = onOpenVote
    }

    private var readerCalendar: Calendar {
        var c = calendar
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    public var body: some View {
        content
            .background(Palette.ground)
            .navigationDestination(item: $page) { section in
                MemberSectionPage(model: model, section: section, onOpenTopic: onOpenTopic, onOpenVote: onOpenVote)
            }
            // The hero's colour under the clear navigation bar, so the back button sits on the hero.
            .background(alignment: .top) {
                if let member = model.member {
                    Palette.heroTop(member.party).frame(height: 0).ignoresSafeArea(edges: .top)
                }
            }
            .task { await loadAll() }
    }

    /// The record and every block's data together: the page shows them all at once.
    private func loadAll() async {
        async let record: Void = model.needsRefresh ? model.load() : ()
        async let promises: Void = model.promises.needsRefresh ? model.promises.load() : ()
        async let posts: Void = model.posts.needsRefresh ? model.posts.load() : ()
        async let money: Void = model.money.needsRefresh ? model.money.load() : ()
        _ = await (record, promises, posts, money)
    }

    @ViewBuilder
    private var content: some View {
        if let member = model.member {
            OneScrollPage(blocks: blocks(member)) { hero(member) }
        } else if case let .failed(message) = model.phase {
            ScrollView {
                VStack(spacing: 12) {
                    Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        } else {
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Hero

    private var record: RepScreenModel.Record? {
        if case let .loaded(record) = model.phase { return record }
        return nil
    }

    private func hero(_ member: Member) -> some View {
        let isRep = reps.contains(member.bioguideId)
        let following = follows?.isFollowing(member) ?? false
        let eyebrow = MemberPageText.eyebrow(member, isRep: isRep, following: following)
        let line = MemberPageText.line(member)
        let stats = record.map { (record: $0, stats: RecordStats(votes: $0.votes)) }
        let tiles = stats.map { MemberPageText.stats($0.record.detail.partyLoyalty, $0.stats) } ?? []
        let spoken = ([member.fullName, eyebrow.capitalized, line] + tiles.map(\.spoken)).joined(separator: ". ") + "."
        let follow = follows.flatMap { follows in
            isRep ? nil : AnyView(HeroFollowButton(member: member, follows: follows))
        }
        return MemberHero(party: member.party, eyebrow: eyebrow, name: member.fullName, line: line, spoken: spoken,
                          follow: follow) {
            MemberPortrait(member, cornerRadius: 20)
        } footer: {
            if let stats {
                VStack(alignment: .leading, spacing: 0) {
                    if let saved = model.saved { SavedDataNote(saved).padding(.top, 12) }
                    HeroStats(tiles: tiles)
                    if !stats.stats.calls.isEmpty {
                        StreakStrip(calls: stats.stats.calls, calendar: readerCalendar, onOpenVote: onOpenVote)
                    }
                }
            }
        }
    }

    // MARK: Blocks

    private func blocks(_ member: Member) -> [MemberBlock] {
        var out: [MemberBlock] = []
        if let record, !record.votes.isEmpty {
            let stats = RecordStats(votes: record.votes)
            out.append(MemberBlock(section: .record, link: ("All \(stats.calls.count)", { page = .record }),
                                   content: AnyView(votes(record))))
        }
        if let said = saidBlock(member) { out.append(said) }
        if let posts = postsBlock(member) { out.append(posts) }
        if let money = moneyBlock(member) { out.append(money) }
        if let record {
            out.append(MemberBlock(section: .contact, link: nil,
                                   content: AnyView(ContactRows(member: member, contact: record.detail.contact))))
        }
        return out
    }

    private func votes(_ record: RepScreenModel.Record) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(record.votes.prefix(3)) { call in
                Button { onOpenVote(call.vote) } label: { MemberVoteRow(call: call, calendar: readerCalendar) }
                    .buttonStyle(.plain)
            }
            if let text = RecordFacts.didYouKnow(member: record.detail.member, votes: record.votes) {
                DidYouKnow(text: text).padding(.top, 2)
            }
        }
    }

    private func saidBlock(_ member: Member) -> MemberBlock? {
        switch model.promises.phase {
        case .loading:
            return nil
        case let .failed(message):
            return MemberBlock(section: .said, link: nil, content: AnyView(
                BlockLine(text: message) { Task { await model.promises.load() } }
            ))
        case let .loaded(said):
            // Not checked yet: the block and its chip are left out.
            if said.status == .unchecked { return nil }
            if said.status == .promises, !said.promises.isEmpty {
                let count = said.promises.count
                return MemberBlock(section: .said, link: ("\(count) \(count == 1 ? "promise" : "promises")", { page = .said }),
                                   content: AnyView(PromiseRail(said: said)))
            }
            return MemberBlock(section: .said, link: nil, content: AnyView(
                BlockLine(text: SaidText.gap(said, name: member.lastName).body)
            ))
        }
    }

    private func postsBlock(_ member: Member) -> MemberBlock? {
        switch model.posts.phase {
        case .loading:
            return nil
        case let .failed(message):
            return MemberBlock(section: .posts, link: nil, content: AnyView(
                BlockLine(text: message) { Task { await model.posts.load() } }
            ))
        case let .loaded(posts):
            let accounts = AccountMarks.links(member: member, posts: posts)
            // No accounts and no posts: nothing to show, so no block and no chip.
            if accounts.isEmpty, posts.posts.isEmpty { return nil }
            let content = VStack(alignment: .leading, spacing: 12) {
                if !accounts.isEmpty { AccountMarks(links: accounts) }
                if posts.posts.isEmpty {
                    BlockLine(text: PostsList.empty(member: member).body)
                }
                ForEach(posts.posts.prefix(2)) { post in
                    PostCard(post: post, member: member, lineLimit: 5)
                }
            }
            return MemberBlock(section: .posts, link: posts.posts.isEmpty ? nil : ("All", { page = .posts }),
                               content: AnyView(content))
        }
    }

    private func moneyBlock(_ member: Member) -> MemberBlock? {
        switch model.money.phase {
        case .loading:
            return nil
        case let .failed(message):
            return MemberBlock(section: .money, link: ("Details", { page = .money }), content: AnyView(
                BlockLine(text: message) { Task { await model.money.load() } }
            ))
        case let .loaded(body):
            let content: AnyView = body.funding.map { AnyView(MoneySummary(funding: $0)) }
                ?? AnyView(BlockLine(text: body.noFilings.body))
            return MemberBlock(section: .money, link: ("Details", { page = .money }), content: content)
        }
    }
}

/// Follow / Following on the hero (`.hero .nav span`): a white pill with the hero's own ink.
struct HeroFollowButton: View {
    let member: Member
    let follows: Follows

    var body: some View {
        let on = follows.isFollowing(member)
        Button { follows.toggle(member) } label: {
            Text(on ? "Following ✓" : "Follow")
                .scaledFont(12.5, weight: .bold)
                .foregroundStyle(Palette.heroBottom(member.party))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Palette.bandText, in: .rect(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Following \(member.fullName)" : "Follow \(member.fullName)")
        .accessibilityHint(on ? "Unfollows" : "Adds their votes to Finals and your widgets")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The "DID YOU KNOW" line under the Votes rows and on the full record.
struct DidYouKnow: View {
    let text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side; at the largest sizes the label sits above, so the line keeps the width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            Text("DID YOU KNOW")
                .font(Typography.display(15, weight: .blackItalic))
                .foregroundStyle(Palette.threshold)
                .fixedSize()
            Text(text)
                .scaledFont(13)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accessibilityElement(children: .combine)
    }
}

/// One segment of the member page, whole, on its own screen: the full record ("All 40"), the
/// promise deck, every post, or Money's Funding and Disclosures.
public struct MemberSectionPage: View {
    @State private var model: RepScreenModel
    let section: MemberSection
    let onOpenTopic: ((String) -> Void)?
    let onOpenVote: (Vote) -> Void

    public init(model: RepScreenModel, section: MemberSection, onOpenTopic: ((String) -> Void)? = nil,
                onOpenVote: @escaping (Vote) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.section = section
        self.onOpenTopic = onOpenTopic
        self.onOpenVote = onOpenVote
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .background(Palette.ground)
        .navigationTitle(model.member.map { "\($0.lastName) · \(section.rawValue)" } ?? section.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.ground, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        switch section {
        case .record:
            RepRecordContent(model: model, fact: nil, onOpenVote: onOpenVote)
        case .said:
            SaidContent(model: model.promises, member: model.member, card: $model.promiseCard, onOpenTopic: onOpenTopic)
        case .posts:
            PostsContent(model: model.posts, member: model.member)
        case .money:
            SectionSwitch(selection: $model.moneySegment, label: "Money")
            if model.moneySegment == .funding {
                MoneyContent(model: model.money, member: model.member)
            } else {
                DisclosuresContent(model: model.disclosures, member: model.member)
            }
        case .contact:
            ContactContent(record: model, member: model.member)
        }
    }
}

/// Follow / Following on a member, as the mock's member screen and search rows draw it: filled when
/// you can follow, outlined once you do. Your own rep shows a label, not a button.
public struct FollowButton: View {
    let member: Member
    let follows: Follows
    let isRep: Bool
    var compact = false

    public init(member: Member, follows: Follows, isRep: Bool, compact: Bool = false) {
        self.member = member
        self.follows = follows
        self.isRep = isRep
        self.compact = compact
    }

    public var body: some View {
        if isRep {
            Text(member.chamber == .senate ? "YOUR SENATOR" : "YOUR REP")
                .font(Typography.label(compact ? 12 : 14))
                .tracking(0.6)
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 7 : 10)
                .frame(maxWidth: compact ? nil : .infinity)
                .accessibilityLabel("\(member.fullName) is your \(member.chamber == .senate ? "senator" : "representative")")
        } else {
            let on = follows.isFollowing(member)
            Button { follows.toggle(member) } label: {
                Text(on ? (compact ? "FOLLOWING" : "✓ FOLLOWING") : "FOLLOW")
                    .font(Typography.label(compact ? 12 : 14))
                    .tracking(0.6)
                    .foregroundStyle(on ? Palette.text : Palette.ground)
                    .padding(.horizontal, compact ? 10 : 12)
                    .padding(.vertical, compact ? 7 : 10)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .background(on ? Color.clear : Palette.threshold, in: .rect(cornerRadius: compact ? 8 : 9))
                    .overlay {
                        if on { RoundedRectangle(cornerRadius: compact ? 8 : 9).strokeBorder(Palette.raised, lineWidth: 1) }
                    }
                    .fixedSize(horizontal: compact, vertical: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? "Following \(member.fullName)" : "Follow \(member.fullName)")
            .accessibilityHint(on ? "Unfollows" : "Adds their votes to Finals and your widgets")
            .accessibilityAddTraits(on ? [.isSelected] : [])
        }
    }
}

/// The full record ("All 40"): the player card, the three rings, the last-40 grid and the fact.
struct RepRecordContent: View {
    let model: RepScreenModel
    /// A fact computed with the rest of the delegation in view; nil computes one from this record.
    let fact: String?
    let onOpenVote: (Vote) -> Void

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 44)
        case let .failed(message):
            // One view, not two siblings, so the caller's modifiers apply to it once.
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        case let .loaded(record):
            let stats = RecordStats(votes: record.votes)
            let member = record.detail.member
            VStack(alignment: .leading, spacing: 16) {
                if let saved = model.saved { SavedDataNote(saved) }
                playerCard(record.detail)
                rings(record.detail.partyLoyalty, stats, member: member)
                grid(stats)
                if let text = fact ?? RecordFacts.didYouKnow(member: member, votes: record.votes) {
                    DidYouKnow(text: text)
                }
            }
        }
    }

    private func playerCard(_ detail: MemberDetail) -> some View {
        let member = detail.member
        let loyalty = detail.partyLoyalty
        let unity = loyalty.withPartyShare.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        return HStack(spacing: 0) {
            MemberPortrait(member, cornerRadius: 0).frame(width: 130, height: 170)
            VStack(alignment: .leading, spacing: 6) {
                SkewChip("\(Tier(crossovers: loyalty.againstParty).rawValue) · \(member.badge)",
                         foreground: Palette.silverInk, background: Palette.silver[2], size: 11)
                Text(member.fullName.uppercased())
                    .font(Typography.label(26))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(-4)
                    .minimumScaleFactor(0.6)
                Text(member.seatLine).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 4)
                Rectangle().fill(Palette.panelBorder).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(unity).font(Typography.label(22)).foregroundStyle(Palette.text)
                        Text("W/ PARTY").font(.system(size: 9)).foregroundStyle(Palette.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(loyalty.againstParty)").font(Typography.label(22)).foregroundStyle(Palette.threshold)
                        Text("CROSSOVERS").font(.system(size: 9)).foregroundStyle(Palette.textMuted)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
        .background(Palette.panel)
        .clipShape(.rect(cornerRadius: 14))
        .padding(5)
        .background(LinearGradient(colors: Palette.silver, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.fullName), \(member.seatLine). \(Tier(crossovers: loyalty.againstParty).rawValue.capitalized). "
                + (loyalty.withPartyShare == nil ? "No party-loyalty figure. " : "\(unity) with party. ")
                + "\(loyalty.againstParty) crossovers."
        )
    }

    private func rings(_ loyalty: PartyLoyalty, _ stats: RecordStats, member: Member) -> some View {
        let withParty = loyalty.withPartyShare
        let showedSub = stats.present > 0 ? "\(stats.present) present"
            : stats.missed > 0 ? "\(stats.missed) missed" : "last \(stats.calls.count)"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ring(share: withParty, color: Palette.yea,
                     big: withParty.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                     label: "With party",
                     sub: withParty == nil ? "party of one" : "\(loyalty.withParty.formatted()) of \(loyalty.votes.formatted())")
                ring(share: stats.showedUpShare, color: Palette.text,
                     big: "\(stats.showedUp)/\(stats.calls.count)", label: "Showed up", sub: showedSub)
                ring(share: stats.winningShare, color: Palette.nay,
                     big: "\(stats.sidedWithOutcome)/\(stats.decided)", label: "Winning side",
                     sub: "last \(stats.calls.count)")
            }
            // The denominator, spelled out, because a bare percentage invites the wrong reading
            // (lesson 15): votes where their party had a clear majority, not every vote cast.
            Text(withParty == nil
                 ? "\(member.fullName) sits outside the two parties, so there is no party majority to measure against."
                 : "With party counts votes where \(member.party) had a clear majority, not every vote cast.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 16)
    }

    private func ring(share: Double?, color: Color, big: String, label: String, sub: String) -> some View {
        VStack(spacing: 4) {
            Ring(share: share, color: color, lineWidth: 6.5) {
                Text(big).font(Typography.label(20)).foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 8)
            }
            .frame(width: 78, height: 78)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
            Text(sub).font(.system(size: 10)).foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(big == "—" ? "no figure" : big), \(sub)")
    }

    private func grid(_ stats: RecordStats) -> some View {
        let calls = stats.calls
        let selected = calls.isEmpty ? nil : min(model.selectedCall ?? calls.count - 1, calls.count - 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("LAST \(calls.count) CALLS").font(Typography.label(20)).foregroundStyle(Palette.text)
            if calls.isEmpty {
                Text("No votes on record yet.").font(.system(size: 13)).foregroundStyle(Palette.textMuted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 10), spacing: 5) {
                ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                    Button { model.selectedCall = index } label: { square(call, on: index == selected) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(call.spokenSummary)
                        .accessibilityAddTraits(index == selected ? [.isSelected] : [])
                }
            }
            if let selected {
                readout(calls[selected])
            }
        }
        .panel()
    }

    private func square(_ call: MemberVote, on: Bool) -> some View {
        let fill: Color = switch call.position {
        case .yea: Palette.yea
        case .nay: Palette.nay
        case .present: Palette.textMuted
        case .candidate: Palette.textSecondary
        case .notVoting: .clear
        }
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .overlay {
                if call.position == .notVoting {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Palette.textMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(1)
            .overlay {
                if on { RoundedRectangle(cornerRadius: 5).stroke(Palette.text, lineWidth: 2) }
            }
    }

    private func readout(_ call: MemberVote) -> some View {
        let tone = Palette.position(call.position)
        let label = call.position == .candidate ? (call.choice ?? "BALLOT").uppercased() : call.position.shortLabel
        return Button { onOpenVote(call.vote) } label: {
            HStack(spacing: 10) {
                Text(label)
                    .font(Typography.label(15))
                    .foregroundStyle(call.position == .notVoting ? Palette.textMuted : tone)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(call.position == .yea || call.position == .nay ? tone.opacity(0.16) : Palette.panelBorder,
                                in: .rect(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(call.cite) · \(call.vote.questionKind)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    Text([call.vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day()), call.vote.result]
                        .compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if call.vote.kind == .question {
                    (Text("\(call.vote.totals.yea)").foregroundStyle(Palette.yea)
                        + Text("–").foregroundStyle(Palette.text)
                        + Text("\(call.vote.totals.nay)").foregroundStyle(Palette.nay))
                        .font(Typography.label(20))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.ground, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the vote")
    }
}

#Preview("Member") {
    // Needs `npm run dev -w @floor/api`.
    NavigationStack {
        RepScreenView(
            model: RepScreenModel(bioguideId: Member.sample.bioguideId, api: FloorAPI(baseURL: FloorAPI.localDevelopment)),
            follows: Follows(store: InMemoryFollowStore())
        )
    }
}
