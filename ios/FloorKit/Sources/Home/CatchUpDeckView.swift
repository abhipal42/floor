import DesignSystem
import Models
import SwiftUI

/// The catch-up deck, as the locked landing "Five finals deck" draws it: a stack of cards, each
/// with the rule, the score counting up to the final, the threshold line, the twist and your three.
///
/// The landing card carries a one-line plain-English blurb of the bill. That needs the bill's own
/// summary rewritten, which is M4 work, so the card shows the chamber's recorded result in that
/// place instead.
struct CatchUpDeckView: View {
    let model: HomeModel
    let onOpenVote: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.playsArrivalAnimations) private var playsArrivalAnimations
    private var reduceMotion: Bool { systemReduceMotion || !playsArrivalAnimations }
    @State private var front = 0
    @State private var progress: Double = 1
    @State private var leaving: Int?

    var body: some View {
        let deck = model.deck
        VStack(spacing: 16) {
            if deck.isEmpty {
                Text("No finals to catch up on yet.").font(Typography.body).foregroundStyle(Palette.textMuted)
            } else {
                ZStack(alignment: .top) {
                    ForEach(Array(deck.enumerated()).reversed(), id: \.element.id) { index, item in
                        let depth = (index - front + deck.count) % deck.count
                        if depth <= 2 || index == leaving {
                            card(item, number: index + 1, of: deck.count, isFront: depth == 0)
                                .scaleEffect(index == leaving ? 1 : 1 - Double(depth) * 0.04, anchor: .top)
                                .offset(x: index == leaving ? -440 : 0, y: index == leaving ? 0 : Double(depth) * 14)
                                .rotationEffect(.degrees(index == leaving ? -10 : 0))
                                .opacity(index == leaving ? 0 : 1)
                                .zIndex(index == leaving ? 30 : Double(20 - depth))
                                .allowsHitTesting(depth == 0)
                                .accessibilityHidden(depth != 0)
                        }
                    }
                }
                .padding(.bottom, 28)
                controls(deck)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground.ignoresSafeArea())
        .onAppear { arrive(deck) }
    }

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

    private func move(_ step: Int, _ deck: [FeedItem]) {
        guard leaving == nil, !deck.isEmpty else { return }
        let next = (front + step + deck.count) % deck.count
        if step > 0, !reduceMotion {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { leaving = front }
            Task {
                try? await Task.sleep(for: .milliseconds(360))
                leaving = nil
                front = next
                arrive(deck)
            }
        } else {
            front = next
            arrive(deck)
        }
    }

    private func controls(_ deck: [FeedItem]) -> some View {
        let seen = deck.filter { model.seenInDeck.contains($0.id) }.count
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { move(-1, deck) } label: {
                    Text("← Back")
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.panelBorder, lineWidth: 1))
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(Array(deck.enumerated()), id: \.element.id) { index, item in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == front ? Palette.text : model.seenInDeck.contains(item.id) ? Palette.yea : Palette.panelBorder)
                            .frame(width: 18, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(seen) of \(deck.count) caught up")
                Spacer(minLength: 0)
                Button { move(1, deck) } label: {
                    Text("Next final →")
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize()
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .background(Palette.text, in: .rect(cornerRadius: 10))
                }
            }
            .buttonStyle(.plain)
            Text("\(seen) of \(deck.count) caught up")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
                .accessibilityHidden(true)
        }
    }

    private func card(_ item: FeedItem, number: Int, of count: Int, isFront: Bool) -> some View {
        let vote = item.vote
        let p = isFront ? progress : 1
        let settled = !isFront || progress >= 0.9 || reduceMotion
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                SkewChip(vote.chamber.name.uppercased(), size: 15)
                Text([item.measure?.citation, vote.questionKind, vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Palette.textMuted).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(number) / \(count)").font(Typography.label(16)).foregroundStyle(Palette.textMuted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.measure?.title ?? vote.question)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                if let result = vote.result {
                    Text(result).font(.system(size: 15)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
            }
            if let line = vote.line {
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        Text("YEA").font(Typography.label(16)).foregroundStyle(Palette.yea).frame(width: 48, alignment: .leading)
                        CountingNumber(Double(line.yea) * p)
                            .font(Typography.score(72)).monospacedDigit().foregroundStyle(Palette.yea)
                            .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
                        VStack(spacing: 4) {
                            SkewChip(vote.outcomeWord ?? "FINAL", background: Palette.outcome(vote.outcome), size: 17)
                                .frame(maxWidth: 96)
                                .opacity(settled ? 1 : 0)
                            Text("FINAL").font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                        }
                        .frame(width: 100)
                        CountingNumber(Double(line.nay) * p)
                            .font(Typography.score(72)).monospacedDigit().foregroundStyle(Palette.nay)
                            .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity)
                        Text("NAY").font(Typography.label(16)).foregroundStyle(Palette.nay).frame(width: 48, alignment: .trailing)
                    }
                    ThresholdBar(line: line, height: 10, progress: p)
                    HStack {
                        Text("\(line.cast) voted\(vote.totals.notVoting > 0 ? " · \(vote.totals.notVoting) did not" : "")")
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(needed(line)).fontWeight(.semibold).foregroundStyle(Palette.threshold)
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                }
                .padding(14)
                .background(Palette.ground, in: .rect(cornerRadius: 14))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Yea \(line.yea), Nay \(line.nay). \(vote.outcomeWord?.capitalized ?? "Final"). \(needed(line))."
                )
            }
            HStack(alignment: .top, spacing: 12) {
                Text("THE TWIST").font(Typography.display(17, weight: .blackItalic)).foregroundStyle(Palette.threshold)
                    .fixedSize()
                Text(CatchUp.twist(item)).font(.system(size: 14)).foregroundStyle(Palette.text)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 12))
            .opacity(settled ? 1 : 0)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if !item.positions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR THREE").font(.system(size: 11)).tracking(0.7).foregroundStyle(Palette.textMuted)
                    HStack(spacing: 8) {
                    ForEach(item.positions) { position in
                        HStack(spacing: 8) {
                            MemberPortrait(position.member).frame(width: 26, height: 26)
                            Text(position.member.lastName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(position.position.shortLabel).font(Typography.label(15))
                                .foregroundStyle(Palette.position(position.position))
                        }
                        .padding(EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 12))
                        .background(Palette.ground, in: .capsule)
                        .overlay(Capsule().stroke(Palette.panelBorder, lineWidth: 1))
                        .fixedSize()
                    }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 500)
        .background(Palette.panel, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.panelBorder, lineWidth: 1))
        .shadow(color: Palette.shadow, radius: 24, y: 24)
        .contentShape(.rect)
        .onTapGesture { onOpenVote(vote.id) }
        .accessibilityAction(named: "Open the vote") { onOpenVote(vote.id) }
    }

    private func needed(_ line: ThresholdLine) -> String {
        switch line.threshold {
        case .majority: "Needed a majority"
        case .twoThirds: "Needed two-thirds"
        case .threeFifthsSworn: "Needed 60 of 100"
        }
    }
}
