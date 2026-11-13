import APIClient
import DesignSystem
import Models
import SwiftUI

/// The Finals tab, as the locked Home mock draws it: your delegation with a loyalty ring each, the
/// latest final on a split-flap board, the catch-up deck, then your finals by chamber.
///
/// The mock's board reads "LATEST FINAL · 1 / 5"; this one shows only the latest, so it says so
/// and dates it rather than numbering a sequence it does not page through.
public struct HomeView: View {
    let model: HomeModel
    let onChangeAddress: () -> Void
    let onOpenMember: (Member) -> Void
    let onOpen: (HomeModel.Route) -> Void

    public init(
        model: HomeModel,
        onChangeAddress: @escaping () -> Void,
        onOpenMember: @escaping (Member) -> Void,
        onOpen: @escaping (HomeModel.Route) -> Void
    ) {
        self.model = model
        self.onChangeAddress = onChangeAddress
        self.onOpenMember = onOpenMember
        self.onOpen = onOpen
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                delegationStrip
                switch model.phase {
                case .loading:
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
                case let .failed(message):
                    failure(message)
                case .loaded:
                    if let saved = model.saved { SavedDataNote(saved) }
                    if let latest = model.latestFinal {
                        Button { onOpen(.vote(id: latest.vote.id)) } label: { SplitFlapBoard(item: latest) }
                            .buttonStyle(.plain)
                    }
                    if !model.deck.isEmpty {
                        Button { onOpen(.catchUp) } label: { catchUpEntry }
                            .buttonStyle(.plain)
                    }
                    finalsHeader
                    feed
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await model.load() }
        .background(alignment: .top) {
            LinearGradient(colors: [Palette.groundGlow, Palette.ground], startPoint: .top, endPoint: .bottom)
                .frame(height: 420)
                .ignoresSafeArea()
        }
        .background(Palette.ground)
        .task { if model.needsRefresh { await model.load() } }
    }

    private var header: some View {
        HStack {
            Text("FLOOR").font(Typography.headline(34)).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onChangeAddress) {
                Text(model.delegation.district.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.text.opacity(0.08), in: .capsule)
            }
            .accessibilityLabel("District \(model.delegation.district.name). Change your address")
            AppearanceMenu()
        }
    }

    private var delegationStrip: some View {
        HStack(spacing: 10) {
            ForEach(model.delegation.members) { member in
                Button { onOpenMember(member) } label: { delegationCard(member) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func delegationCard(_ member: Member) -> some View {
        let share = model.loyalty[member.bioguideId]?.withPartyShare
        return VStack(spacing: 6) {
            Ring(share: share, color: Palette.yea, lineWidth: 3) {
                MemberPortrait(member).frame(width: 40, height: 40)
            }
            .frame(width: 50, height: 50)
            Text(member.lastName.uppercased())
                .font(Typography.label(16))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(member.chamber == .house ? "House · \(member.badge)" : "Senate · \(member.state)")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.fullName), \(member.chamber == .house ? "Representative" : "Senator"). "
                + (share.map { "Voted with their party \(String(format: "%.1f", $0 * 100)) percent of the time" }
                    ?? "No party-loyalty figure")
        )
        .accessibilityHint("Opens their record")
    }

    private var catchUpEntry: some View {
        let deck = model.deck
        return HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Palette.panelBorder).frame(width: 44, height: 56)
                    .rotationEffect(.degrees(8)).offset(x: 8)
                RoundedRectangle(cornerRadius: 8).fill(Palette.raised).frame(width: 44, height: 56)
                    .rotationEffect(.degrees(3)).offset(x: 4, y: 2)
                Text("\(deck.count)")
                    .font(Typography.display(22, weight: .blackItalic, scales: false))
                    .foregroundStyle(Palette.ground)
                    .frame(width: 44, height: 56)
                    .background(Palette.text, in: .rect(cornerRadius: 8))
                    .offset(y: 4)
            }
            .frame(width: 54, height: 62, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 3) {
                Text("CATCH UP · \(deck.count) FINALS").font(Typography.headline(22)).foregroundStyle(Palette.text)
                Text("The rule, the score, the twist, your three.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textMuted)
                HStack(spacing: 4) {
                    ForEach(deck) { item in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(model.seenInDeck.contains(item.id) ? Palette.yea : Palette.panelBorder)
                            .frame(width: 22, height: 4)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Text("›").font(.system(size: 20)).foregroundStyle(Palette.textMuted)
        }
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Catch up, \(deck.count) finals. \(deck.filter { model.seenInDeck.contains($0.id) }.count) of \(deck.count) caught up")
    }

    private var finalsHeader: some View {
        HStack {
            Text("YOUR FINALS").font(Typography.headline(26)).foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 4) {
                ForEach(HomeModel.Filter.allCases, id: \.self) { option in
                    let on = model.filter == option
                    Button { model.filter = option } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Palette.ground : Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(on ? Palette.text : .clear, in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Palette.panel, in: .rect(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private var feed: some View {
        if model.visibleItems.isEmpty {
            Text("No recent votes in this chamber.")
                .font(Typography.body)
                .foregroundStyle(Palette.textMuted)
        } else {
            ForEach(model.visibleItems) { item in
                Button { onOpen(.vote(id: item.vote.id)) } label: {
                    ScoreboardCard(
                        vote: item.vote,
                        title: item.measure?.title ?? item.vote.question,
                        citation: item.measure?.citation,
                        positions: item.memberPositions
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
            Button("Try again") { Task { await model.load() } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
        .panel()
    }
}

/// The latest final on a split-flap board: three rows of sixteen cells that settle into place.
///
/// The settle is a short scramble, cell by cell, left to right. With Reduce Motion on, the board
/// is drawn settled.
struct SplitFlapBoard: View {
    let item: FeedItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = 0

    private static let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    var body: some View {
        let rows = FlapBoard.rows(item)
        let colors = [Palette.textMuted, Palette.text, Palette.yea]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { c, char in
                        let index = r * FlapBoard.width + c
                        let shown: Character = reduceMotion || index < settled || char == " " ? char : Self.glyphs[(index * 7 + settled) % Self.glyphs.count]
                        Text(String(shown))
                            .font(Typography.display(17, weight: .extraBold, scales: false))
                            .foregroundStyle(colors[r])
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                LinearGradient(stops: [.init(color: Palette.flapTop, location: 0.49),
                                                       .init(color: Palette.flapBottom, location: 0.51)],
                                               startPoint: .top, endPoint: .bottom),
                                in: .rect(cornerRadius: 3)
                            )
                    }
                }
            }
            Text("LATEST FINAL\(item.vote.occurredAtDate.map { " · " + $0.formatted(.dateTime.month(.abbreviated).day()).uppercased() } ?? "")")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Palette.flapBoard, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.panelBorder, lineWidth: 1))
        // A lit board, so it stays dark in light mode, as the real ones do.
        .litObject()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Latest final: " + rows.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
        .accessibilityHint("Opens the vote")
        .task(id: item.id) {
            guard !reduceMotion else { settled = .max; return }
            let total = rows.count * FlapBoard.width
            for step in 0...total {
                settled = step
                try? await Task.sleep(for: .milliseconds(14))
                if Task.isCancelled { break }
            }
            settled = .max
        }
    }
}
