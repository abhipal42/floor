import DesignSystem
import Models
import SwiftUI

// The member page as one scroll (v0.2.58, locked option B, https://claude.ai/artifact/Jaqz5c8EGoCQd8Wb8ELBns,
// drawn in Arena as `profile()` in https://claude.ai/artifact/HP3nZFoQ4jUppnjKsC1MfV): a party-colour
// hero with the record's three numbers and the last-40 streak, sticky jump chips, then Votes, Said,
// Posts, Money and Contact as blocks. Each block's link opens the full segment on its own screen.

// MARK: - Words

/// Everything the hero and the blocks print, apart from the views so it can be tested.
public enum MemberPageText {
    /// `YOUR SENATOR · NEW YORK`, `YOUR REP · NY-12`, `FOLLOWING`, `SENATE · TEXAS`, `HOUSE · TX-37`.
    public static func eyebrow(_ member: Member, isRep: Bool, following: Bool) -> String {
        if isRep {
            return member.chamber == .senate ? "YOUR SENATOR · \(StateName.full(member.state).uppercased())" : "YOUR REP · \(member.seatBadge)"
        }
        if following { return "FOLLOWING" }
        if member.isDelegate { return "DELEGATE · \(StateName.full(member.state).uppercased())" }
        return member.chamber == .senate ? "SENATE · \(StateName.full(member.state).uppercased())" : "HOUSE · \(member.seatBadge)"
    }

    /// `Democrat · Senate`, `Republican · House`, `Democrat · Delegate`.
    public static func line(_ member: Member) -> String {
        let seat = member.isDelegate ? member.title : (member.chamber == .senate ? "Senate" : "House")
        return "\(PartyName.singular(member.party)) · \(seat)"
    }

    /// The three hero tiles: With party, Showed up, Winning side, as the Votes segment counts them.
    public static func stats(_ loyalty: PartyLoyalty, _ stats: RecordStats) -> [(value: String, label: String, spoken: String)] {
        let unity = loyalty.withPartyShare.map { String(format: "%.1f%%", $0 * 100) }
        return [
            (unity ?? "—", "With party", unity.map { "\($0) with party" } ?? "no party-loyalty figure"),
            ("\(stats.showedUp)/\(stats.calls.count)", "Showed up", "showed up for \(stats.showedUp) of \(stats.calls.count)"),
            ("\(stats.sidedWithOutcome)/\(stats.decided)", "Winning side",
             "on the winning side \(stats.sidedWithOutcome) of \(stats.decided)"),
        ]
    }

    /// The streak strip read aloud: `Last 40 calls: 14 yea, 26 nay.`
    public static func streak(_ calls: [MemberVote]) -> String {
        let count = { (p: Position) in calls.filter { $0.position == p }.count }
        var parts = ["\(count(.yea)) yea", "\(count(.nay)) nay"]
        if count(.present) > 0 { parts.append("\(count(.present)) present") }
        if count(.notVoting) > 0 { parts.append("\(count(.notVoting)) didn't vote") }
        let ballots = count(.candidate)
        if ballots > 0 { parts.append("\(ballots) Speaker \(ballots == 1 ? "ballot" : "ballots")") }
        return "Last \(calls.count) calls: " + parts.joined(separator: ", ") + "."
    }

    /// `Confirmed 51–46 · Nov 16`, a Votes row's second line, in the reader's calendar.
    public static func voteLine(_ call: MemberVote, calendar: Calendar) -> String {
        let vote = call.vote
        let score = vote.kind == .question ? "\(vote.totals.yea)–\(vote.totals.nay)" : nil
        let what = [vote.outcomeWord?.capitalized ?? vote.questionKind, score].compactMap(\.self).joined(separator: " ")
        return [what, vote.occurredAtDate.map { shortDate($0, calendar: calendar) }].compactMap(\.self).joined(separator: " · ")
    }

    /// `YEA` over `won`: where the member stood and whether their side carried.
    public static func position(_ call: MemberVote) -> (word: String, side: String?) {
        let word = switch call.position {
        case .yea: "YEA"
        case .nay: "NAY"
        case .present: "PRESENT"
        case .notVoting: "DIDN'T VOTE"
        case .candidate: (call.choice ?? "BALLOT").uppercased()
        }
        return (word, call.sidedWithOutcome.map { $0 ? "won" : "lost" })
    }

    /// `EDUCATION · 2022 SITE`: a promise card's eyebrow, Floor's topic where the AI gave one.
    public static func promiseTopic(_ promise: CampaignPromise, said: MemberPromises) -> String {
        let topic = promise.topic ?? promise.heading ?? "Promise"
        let site = said.electionYear.map { "\($0) site" } ?? "campaign site"
        return "\(topic) · \(site)".uppercased()
    }

    /// `Nov 16`.
    public static func shortDate(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(locale: calendar.locale ?? Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

// MARK: - Hero

/// The full-width hero in the party's colour (`.hero`): a deep gradient with a radial light at the
/// top right; independents in grey. White text in both appearances.
struct MemberHero<Portrait: View, Footer: View>: View {
    let party: String
    let eyebrow: String
    let name: String
    let line: String
    /// The whole hero read as one sentence.
    let spoken: String
    let portrait: Portrait
    let footer: Footer
    /// The Follow pill at the hero's top right (`.hero .nav span`); nil for your own rep and a member-elect.
    let follow: AnyView?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(party: String, eyebrow: String, name: String, line: String, spoken: String, follow: AnyView? = nil,
         @ViewBuilder portrait: () -> Portrait, @ViewBuilder footer: () -> Footer) {
        self.follow = follow
        self.party = party
        self.eyebrow = eyebrow
        self.name = name
        self.line = line
        self.spoken = spoken
        self.portrait = portrait()
        self.footer = footer()
    }

    static var portraitSize: CGSize { CGSize(width: 92, height: 112) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let follow {
                HStack {
                    Spacer()
                    follow
                }
                .padding(.bottom, 10)
            }
            who
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isHeader)
            footer
        }
        .foregroundStyle(Palette.bandText)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background.ignoresSafeArea(edges: .top) }
    }

    private var who: some View {
        let text = VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .scaledFont(Typography.Member.eyebrow, weight: .heavy)
                .tracking(1.4)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Text(name.uppercased())
                .font(Typography.heroName)
                // Already 40pt: past the first accessibility size a surname no longer fits a line and
                // breaks mid-word ("SCHUME / R").
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.bottom, 4)
            Text(line)
                .scaledFont(Typography.Member.heroLine)
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        let photo = portrait
            .frame(width: Self.portraitSize.width, height: Self.portraitSize.height)
            .clipShape(.rect(cornerRadius: 20))
            .padding(3)
            .background(Palette.heroRing, in: .rect(cornerRadius: 23))
            .shadow(color: Palette.heroShadow, radius: 15, y: 12)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { photo; text }
            } else {
                HStack(alignment: .bottom, spacing: 14) { photo; text }
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Palette.heroTop(party), Palette.heroBottom(party)],
                           startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
            RadialGradient(colors: [Palette.heroLight(party), .clear], center: UnitPoint(x: 0.9, y: 0), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Palette.heroGreen, .clear], center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: 220)
        }
    }
}

/// The three glass stat tiles on the hero; stacked at the largest text sizes.
struct HeroStats: View {
    let tiles: [(value: String, label: String, spoken: String)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            ForEach(tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.value)
                        .font(Typography.mainScore)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(tile.label)
                        .scaledFont(Typography.Member.statLabel, weight: .semibold)
                        .opacity(0.85)
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.heroTile, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.heroTileBorder, lineWidth: 1))
            }
        }
        .padding(.top, 16)
        .accessibilityHidden(true)
    }
}

/// The last-40 streak strip: one bar per call, oldest to newest, each opening its vote.
struct StreakStrip: View {
    /// Oldest first.
    let calls: [MemberVote]
    let calendar: Calendar
    let onOpenVote: (Vote) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(calls) { call in
                    Button { onOpenVote(call.vote) } label: {
                        RoundedRectangle(cornerRadius: 2).fill(color(call.position))
                            .frame(height: 15)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(call.spokenSummary)
                    .accessibilityHint("Opens the vote")
                }
            }
            .padding(.vertical, -6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(MemberPageText.streak(calls))
            HStack {
                Text("Last \(calls.count) calls")
                Spacer()
                if let last = calls.last?.vote.occurredAtDate { Text(MemberPageText.shortDate(last, calendar: calendar)) }
            }
            .scaledFont(Typography.Member.streakLabel, weight: .semibold)
            .opacity(0.75)
            .accessibilityHidden(true)
        }
        .padding(.top, 12)
    }

    private func color(_ position: Position) -> Color {
        switch position {
        case .yea: Palette.streakYea
        case .nay: Palette.streakNay
        default: Palette.streakOther
        }
    }
}

// MARK: - The scroll

/// The page scroll's coordinate space, where each block reports its top.
private let memberPageSpace = "memberPage"

/// One block of the one-scroll page: its chip, its title, the link to its full screen, its content.
struct MemberBlock: Identifiable {
    let section: MemberSection
    var title: String { section.rawValue }
    let link: (title: String, action: () -> Void)?
    let content: AnyView

    var id: MemberSection { section }
}

/// The hero, the sticky jump chips and the blocks. The active chip follows the scroll; tapping one
/// scrolls to its block.
struct OneScrollPage<Hero: View>: View {
    let hero: Hero
    let blocks: [MemberBlock]
    /// A member-elect's two sections need no chips.
    let chips: Bool

    @State private var active: MemberSection?
    @State private var tops: [MemberSection: CGFloat] = [:]
    @State private var chipsHeight: CGFloat = 52
    @Environment(\.accessibilityReduceMotion) private var reduceMotion



    init(blocks: [MemberBlock], chips: Bool = true, @ViewBuilder hero: () -> Hero) {
        self.hero = hero()
        self.blocks = blocks
        self.chips = chips
    }

    /// The last block whose top has reached the chips; the first until one has.
    private var current: MemberSection? {
        let reached = blocks.filter { (tops[$0.section] ?? .infinity) <= chipsHeight + 24 }
        return reached.last?.section ?? blocks.first?.section
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    hero
                    Section {
                        ForEach(blocks) { block in
                            blockView(block)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(memberPageSpace)).minY } action: { tops[block.section] = $0 }
                        }
                    } header: {
                        if chips, blocks.count > 1 {
                            chips(proxy)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipsHeight = $0 }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .coordinateSpace(.named(memberPageSpace))
        }
        .background(Palette.ground)
    }

    private func chips(_ proxy: ScrollViewProxy) -> some View {
        let on = current
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(blocks) { block in
                    let selected = block.section == on
                    Button {
                        if reduceMotion { proxy.scrollTo(block.section, anchor: .top) } else {
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(block.section, anchor: .top) }
                        }
                    } label: {
                        Text(block.title)
                            .scaledFont(Typography.Member.chip, weight: .bold)
                            .foregroundStyle(selected ? Palette.ground : Palette.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            // Under half the chip's height (lesson 68).
                            .background(selected ? Palette.text : Palette.chip, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(block.title)
                    .accessibilityHint("Scrolls to \(block.title)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .background(Palette.ground.opacity(0.9))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.cardBorder).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func blockView(_ block: MemberBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.title.uppercased())
                    .font(Typography.blockTitle)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let link = block.link {
                    Button(action: link.action) {
                        Text(link.title + " ›")
                            .scaledFont(Typography.Member.link, weight: .bold)
                            .foregroundStyle(Palette.accent)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            block.content
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 4)
        // Where a chip scrolls to: just above the block, by the chips' height, so its title clears them.
        .background(alignment: .top) {
            Color.clear.frame(height: chipsHeight)
                .alignmentGuide(.top) { $0[.bottom] }
                .id(block.section)
        }
    }
}

// MARK: - Blocks

/// A Votes row (`.vr`): the topic colour, the title, how it went, and where the member stood.
struct MemberVoteRow: View {
    let call: MemberVote
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let (word, side) = MemberPageText.position(call)
        // At the largest sizes the position goes under the title, so the title keeps the width.
        let large = typeSize.isAccessibilitySize
        let stand = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(word).font(Typography.miniScore).foregroundStyle(Palette.position(call.position)).lineLimit(1)
            if large, let side { Text(side).scaledFont(Typography.Member.rowSide).foregroundStyle(Palette.textMuted) }
        }
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.topic(TopicGroup.of(call.measure))).frame(width: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.rowTitle)
                    .scaledFont(Typography.Member.rowTitle, weight: .bold)
                    .foregroundStyle(Palette.text)
                    .lineLimit(large ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MemberPageText.voteLine(call, calendar: calendar))
                    .scaledFont(Typography.Member.rowLine)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if large { stand.padding(.top, 2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !large {
                VStack(alignment: .trailing, spacing: 0) {
                    stand
                    if let side { Text(side).scaledFont(Typography.Member.rowSide).foregroundStyle(Palette.textMuted) }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 16)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([call.rowTitle, MemberPageText.voteLine(call, calendar: calendar), word.lowercased(), side]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Opens the vote")
    }
}

/// A promise on the Said rail (`.pc`): topic and site, the headline, the exact quote, AI PICKED.
struct PromiseCard: View {
    let promise: CampaignPromise
    let said: MemberPromises
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(MemberPageText.promiseTopic(promise, said: said))
                .scaledFont(Typography.Member.promiseTopic, weight: .heavy)
                .tracking(1.2)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !promise.headline.isEmpty {
                Text(promise.headline.uppercased())
                    .font(Typography.promiseTitle)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("“\(promise.quote)”")
                .scaledFont(Typography.Member.promiseQuote)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("AI PICKED")
                .font(Typography.label(9))
                .tracking(1)
                .foregroundStyle(Palette.aiInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.ai, in: .rect(cornerRadius: 5))
        }
        .padding(14)
        .frame(width: typeSize.isAccessibilitySize ? 300 : 236, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .glassCard(cornerRadius: 16, fill: LinearGradient(colors: [Palette.promiseTop, Palette.promiseBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Picked by AI, quoted from the \(said.electionYear.map { "\($0) " } ?? "")campaign site. "
            + [promise.topic ?? promise.heading, promise.quote].compactMap(\.self).joined(separator: ". "))
    }
}

/// The horizontal snap rail of promise cards.
struct PromiseRail: View {
    let said: MemberPromises

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Array(said.promises.enumerated()), id: \.offset) { _, promise in
                        PromiseCard(promise: promise, said: said)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
            Text(SaidText.aiLine)
                .scaledFont(Typography.Member.note, weight: .medium)
                .foregroundStyle(Palette.ai)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Raised and cash on hand, the cycle and coverage, and where the money came from.
struct MoneySummary: View {
    let funding: Funding
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                tile("Raised · \(funding.cycle)", MoneyFormat.total(funding.receipts), spoken: "Raised for \(funding.cycle), \(MoneyFormat.spoken(funding.receipts))")
                tile("Cash on hand", funding.cashOnHand.map(MoneyFormat.total) ?? "—",
                     spoken: funding.cashOnHand.map { "Cash on hand, \(MoneyFormat.spoken($0))" } ?? "No cash-on-hand figure")
            }
            Text(funding.period)
                .scaledFont(Typography.Member.note, weight: .medium)
                .foregroundStyle(Palette.textMuted)
            bar
            legend
        }
    }

    private func tile(_ label: String, _ value: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .scaledFont(Typography.Member.tileLabel, weight: .heavy)
                .tracking(1.1)
                .foregroundStyle(Palette.textMuted)
            Text(value).font(Typography.tileNumber).foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var bar: some View {
        let parts = FundingFigures.parts
        let sum = funding.shareBase
        return GeometryReader { geo in
            let gaps = CGFloat(parts.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    part.color.frame(width: sum > 0 ? max(0, geo.size.width - gaps) * funding.shown(part.part) / sum : 0)
                }
            }
        }
        .frame(height: 12)
        .background(Palette.panelBorder)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var legend: some View {
        FlowLayout(spacing: 6) {
            ForEach(FundingFigures.parts, id: \.part) { part, color in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    Text("\(part.label) · \(funding.percent(part))")
                        .scaledFont(Typography.Member.legend)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.trailing, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(part.label): \(funding.percent(part))")
            }
        }
    }
}

/// A block that has nothing to show yet: one line, and Try again when the load failed.
struct BlockLine: View {
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .scaledFont(Typography.Member.rowLine)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
