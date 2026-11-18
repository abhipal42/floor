import DesignSystem
import Models
import SwiftUI

/// The catch-up deck (v0.2.59, the locked "Your picks" of <https://claude.ai/artifact/T7fxxQyFCYdPaJnewnNpT2>):
/// a swipe deck of story cards, two ghost cards peeking out under the top one. Drag the top card
/// sideways, or tap →, to send it off; ↺ brings the last one back. After the last card, all caught up.
///
/// Each card is catch-up A's: the topic band with CRS's lead, the score with its stamp, the threshold
/// bar, the twist, the party split and your members.
///
/// Where this differs from the mock, and why: the band's last sentence for a procedural vote is the
/// step's name from ``Vote/stepName`` ("Cloture to take it up."), the only plain words Floor has for
/// it; the mock's "This vote was to start debate." would be new copy.
struct CatchUpDeckView: View {
    let model: HomeModel
    let onOpenVote: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.playsArrivalAnimations) private var playsArrivalAnimations
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    private var reduceMotion: Bool { systemReduceMotion || !playsArrivalAnimations }
    @State private var front = 0
    @State private var progress: Double = 1
    @State private var drag: CGFloat = 0
    @State private var flying = false

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    var body: some View {
        let deck = model.deck
        ScrollView {
            VStack(spacing: 14) {
                header(deck)
                if deck.isEmpty {
                    Text("No finals to catch up on yet.").font(Typography.body).foregroundStyle(Palette.textMuted)
                        .padding(.top, 40)
                } else if front >= deck.count {
                    caughtUp(deck)
                } else {
                    stack(deck)
                    controls(deck)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .groundGlow()
        .onAppear { arrive(deck) }
    }

    // MARK: Header

    private func header(_ deck: [FeedItem]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Palette.chip, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            VStack(spacing: 2) {
                Text("CATCH UP")
                    .font(Typography.display(26, weight: .blackItalic))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                if let line = Self.subtitle(deck, front: front, calendar: calendar) {
                    Text(line).scaledFont(13).foregroundStyle(Palette.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 34, height: 34).accessibilityHidden(true)
        }
    }

    /// `1 of 5 · since Sep 29`: the card on top, and the oldest final in the deck.
    static func subtitle(_ deck: [FeedItem], front: Int, calendar: Calendar) -> String? {
        guard !deck.isEmpty else { return nil }
        let since = deck.compactMap(\.vote.occurredAtDate).min().map { "since \(Stories.shortDate($0, calendar: calendar))" }
        return ["\(min(front + 1, deck.count)) of \(deck.count)", since].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: Deck

    private func stack(_ deck: [FeedItem]) -> some View {
        let ghosts = min(2, deck.count - front - 1)
        let item = deck[front]
        return CatchUpCard(item: item, progress: progress, reduceMotion: reduceMotion, calendar: calendar)
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if ghosts >= 2 { ghost.scaleEffect(0.9, anchor: .bottom).offset(y: 46).opacity(0.45) }
                    if ghosts >= 1 { ghost.scaleEffect(0.95, anchor: .bottom).offset(y: 24).opacity(0.7) }
                }
                .accessibilityHidden(true)
            }
            .offset(x: drag)
            .rotationEffect(.degrees(Double(drag) / 40), anchor: .bottom)
            .id(item.id)
            .transition(.opacity)
            .padding(.bottom, ghosts >= 2 ? 46 : ghosts == 1 ? 24 : 0)
            .contentShape(.rect)
            .onTapGesture { onOpenVote(item.vote.id) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !flying, !reduceMotion, abs(value.translation.width) > abs(value.translation.height) else { return }
                        drag = value.translation.width
                    }
                    .onEnded { value in
                        guard !flying else { return }
                        if abs(value.translation.width) > 100, abs(value.translation.width) > abs(value.translation.height) {
                            next(deck, toward: value.translation.width < 0 ? -1 : 1)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Next final") { next(deck, toward: -1) }
            .accessibilityAction(named: "Previous final") { back(deck) }
            .accessibilityAction(named: "Open the vote") { onOpenVote(item.vote.id) }
    }

    private var ghost: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Palette.card)
            .heroCard(cornerRadius: 22, fill: Palette.card)
    }

    private func controls(_ deck: [FeedItem]) -> some View {
        let left = deck.count - front - 1
        return HStack(spacing: 8) {
            Button { back(deck) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 56, height: 56)
                    .background(Palette.chip, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(front == 0)
            .opacity(front == 0 ? 0.5 : 1)
            .accessibilityLabel("Previous final")
            VStack(spacing: 2) {
                Text("Swipe for the next one").scaledFont(12).foregroundStyle(Palette.textMuted)
                Text("\(left) left").scaledFont(12, weight: .bold).foregroundStyle(Palette.textSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Button { next(deck, toward: -1) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.ground)
                    .frame(width: 56, height: 56)
                    .background(Palette.text, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next final")
        }
        .padding(.top, 6)
    }

    private func caughtUp(_ deck: [FeedItem]) -> some View {
        VStack(spacing: 10) {
            Text("ALL CAUGHT UP")
                .font(Typography.display(30, weight: .blackItalic))
                .foregroundStyle(Palette.text)
            Text("You've seen all \(deck.count) finals.")
                .scaledFont(13).foregroundStyle(Palette.textMuted)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { front = 0 }
                arrive(deck)
            } label: {
                Text("Start over")
                    .scaledFont(15, weight: .bold)
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .background(Palette.text, in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 22)
    }

    // MARK: Moving

    private func arrive(_ deck: [FeedItem]) {
        guard deck.indices.contains(front) else { return }
        model.seenInDeck.insert(deck[front].id)
        if reduceMotion {
            progress = 1
        } else {
            progress = 0
            withAnimation(.easeOut(duration: 1)) { progress = 1 }
        }
    }

    /// Sends the top card off toward `direction` (-1 left, 1 right) and shows the next; with Reduce
    /// Motion, a crossfade.
    private func next(_ deck: [FeedItem], toward direction: CGFloat) {
        guard !flying, front < deck.count else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { front += 1 }
            arrive(deck)
            return
        }
        flying = true
        withAnimation(.easeIn(duration: 0.22)) { drag = direction * 520 }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            drag = 0
            withAnimation(.easeOut(duration: 0.2)) { front += 1 }
            flying = false
            arrive(deck)
        }
    }

    private func back(_ deck: [FeedItem]) {
        guard !flying, front > 0 else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.35, dampingFraction: 0.85)) {
            drag = 0
            front -= 1
        }
        arrive(deck)
    }
}

/// One catch-up card (catch-up A): the topic band, the score, the threshold bar, the twist, the
/// party split, and your members.
struct CatchUpCard: View {
    let item: FeedItem
    let progress: Double
    let reduceMotion: Bool
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var vote: Vote { item.vote }
    private var group: TopicGroup { TopicGroup.of(item.measure) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            if let line = vote.line { score(line) }
            Text(twist)
                .scaledFont(13)
                .lineSpacing(2)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.threshold.opacity(0.09), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.threshold.opacity(0.22), lineWidth: 1))
                .opacity(settled ? 1 : 0)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            partySplit.padding(.horizontal, 18).padding(.top, 14)
            if !item.positions.isEmpty {
                members.padding(.horizontal, 18).padding(.top, 16)
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard(cornerRadius: 22, fill: Palette.card)
    }

    private var settled: Bool { progress >= 0.9 || reduceMotion }

    private var twist: AttributedString {
        var lead = AttributedString("The twist")
        lead.inlinePresentationIntent = .stronglyEmphasized
        lead.foregroundColor = Palette.threshold
        return lead + AttributedString(" · " + CatchUp.twist(item))
    }

    // MARK: Band

    /// `ENERGY · SENATE · SEP 30`: the policy area (or Nomination), the chamber and the day.
    private var eyebrow: String {
        let topic: String = switch item.measure?.kind {
        case .bill: item.measure?.policyArea ?? "Bill"
        case .nomination: "Nomination"
        case nil: "Vote"
        }
        return [topic, vote.chamber.name, vote.occurredAtDate.map { Stories.shortDate($0, calendar: calendar) }]
            .compactMap(\.self).joined(separator: " · ").uppercased()
    }

    /// CRS's lead for a bill, the post for a nomination.
    private var what: String? {
        switch item.measure?.kind {
        case .bill: item.measure?.summaryLead
        case .nomination: item.measure?.position
        case nil: nil
        }
    }

    private var band: some View {
        VStack(alignment: .leading, spacing: 0) {
            // At the largest sizes the eyebrow goes under the chip rather than squeezing beside it.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                if let citation = item.measure?.citation {
                    SkewChip(citation, foreground: Palette.verdictInk, background: Palette.verdict, size: 13).fixedSize()
                }
                Text(eyebrow)
                    .scaledFont(11, weight: .bold)
                    .tracking(0.8)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Capped so a long word never breaks mid-word across the band.
            Text((item.measure?.title ?? vote.stepName).uppercased())
                .font(Typography.display(30, weight: .blackItalic))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let what {
                Text(what)
                    .scaledFont(13.5)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .opacity(0.88)
                    .padding(.top, 8)
            }
            if vote.isProcedural {
                Text("\(vote.stepName).")
                    .scaledFont(13.5)
                    .opacity(0.88)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, what == nil ? 8 : 2)
            }
        }
        .foregroundStyle(Palette.bandText)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Palette.topic(group)
                RadialGradient(colors: [Palette.bandHighlight, .clear], center: .topTrailing, startRadius: 0, endRadius: 240)
                LinearGradient(colors: [.clear, Palette.bandShade], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    // MARK: Score

    private func score(_ line: ThresholdLine) -> some View {
        let p = reduceMotion ? 1 : progress
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("YEA").scaledFont(11, weight: .bold).tracking(1).foregroundStyle(Palette.yea)
                    CountingNumber(Double(line.yea) * p)
                        .font(Typography.display(64, weight: .blackItalic, scales: false))
                        .monospacedDigit().foregroundStyle(Palette.yea)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    SkewChip(vote.outcomeWord ?? "FINAL", foreground: Palette.ground, background: Palette.outcome(vote.outcome), size: 15)
                        .fixedSize()
                        .opacity(settled ? 1 : 0)
                    Text("FINAL").scaledFont(11, weight: .bold).tracking(1).foregroundStyle(Palette.textMuted)
                        .fixedSize()
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("NAY").scaledFont(11, weight: .bold).tracking(1).foregroundStyle(Palette.nay)
                    CountingNumber(Double(line.nay) * p)
                        .font(Typography.display(64, weight: .blackItalic, scales: false))
                        .monospacedDigit().foregroundStyle(Palette.nay)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 18)
            ThresholdBar(line: line, height: 10, progress: p)
                .padding(.top, 12)
            HStack {
                Text("\(line.cast) voted").foregroundStyle(Palette.textMuted)
                Spacer()
                Text("Needed \(line.needed)").foregroundStyle(Palette.threshold)
            }
            .scaledFont(11.5, weight: .semibold)
            .monospacedDigit()
            .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yea \(line.yea), Nay \(line.nay). \(vote.outcomeWord?.capitalized ?? "Final"). \(line.cast) voted, needed \(line.needed).")
    }

    // MARK: Party split

    private var parties: [PartyTotals] {
        let rank = ["R": 0, "D": 1, "I": 2]
        return item.partyTotals.filter { $0.yea + $0.nay > 0 }
            .sorted { (rank[$0.party] ?? 3, $0.party) < (rank[$1.party] ?? 3, $1.party) }
    }

    @ViewBuilder
    private var partySplit: some View {
        let rows = parties
        if !rows.isEmpty {
            VStack(spacing: 7) {
                ForEach(rows, id: \.party) { row in
                    HStack(spacing: 8) {
                        Text(row.party)
                            .scaledFont(12, weight: .bold)
                            .foregroundStyle(Palette.party(row.party))
                            .frame(width: 22, alignment: .leading)
                        GeometryReader { geo in
                            let total = CGFloat(row.yea + row.nay)
                            HStack(spacing: 0) {
                                Palette.yea.frame(width: geo.size.width * CGFloat(row.yea) / total)
                                Palette.nay.frame(width: geo.size.width * CGFloat(row.nay) / total)
                            }
                        }
                        .frame(height: 8)
                        .background(Palette.track)
                        .clipShape(.capsule)
                        Text("\(row.yea)–\(row.nay)")
                            .scaledFont(12, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                            .frame(minWidth: 54, alignment: .trailing)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.partyName(row.party)), \(row.yea) yea, \(row.nay) nay")
                }
            }
        }
    }

    private static func partyName(_ party: String) -> String {
        switch party {
        case "R": "Republicans"
        case "D": "Democrats"
        case "I": "Independents"
        default: party
        }
    }

    // MARK: Members

    private var members: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(FlowLayout(spacing: 8))
        return layout {
            ForEach(item.positions) { p in
                HStack(spacing: 7) {
                    MemberPortrait(p.member)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Palette.position(p.position), lineWidth: 2))
                    (Text(p.member.lastName + " ")
                        + Text(StoryCard.word(p.position)).fontWeight(.heavy).foregroundColor(StoryCard.color(p.position)))
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
                // A radius under half the chip's height (lesson 68).
                .background(Palette.cardSunken, in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
