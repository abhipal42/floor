import APIClient
import DesignSystem
import Models
import SwiftUI

/// The Finals tab: your delegation with a loyalty ring each, the catch-up deck, then the finals as
/// stories (v0.2.57, the locked feed option B, styled "Arena"): one card per bill or nominee with
/// every vote on it, by week, and an "Also this week" row for what only moved along.
public struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.pinnedNow) private var pinnedNow
    let model: HomeModel
    let onChangeAddress: () -> Void
    let onOpenMember: (Member) -> Void
    let onOpen: (HomeModel.Route) -> Void
    /// With no district, the header chip finds your reps instead of changing them.
    let onFindReps: () -> Void
    @State private var searching = false

    public init(
        model: HomeModel,
        onChangeAddress: @escaping () -> Void,
        onOpenMember: @escaping (Member) -> Void,
        onOpen: @escaping (HomeModel.Route) -> Void,
        onFindReps: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onChangeAddress = onChangeAddress
        self.onOpenMember = onOpenMember
        self.onOpen = onOpen
        self.onFindReps = onFindReps
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                delegationStrip
                if model.followsAnything { scopeSwitch }
                switch model.phase {
                case .loading:
                    ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
                case let .failed(message):
                    failure(message)
                case .loaded:
                    if let saved = model.saved { SavedDataNote(saved) }
                    if let note = model.unavailableNote {
                        Text(note).scaledFont(12).foregroundStyle(Palette.textMuted)
                    }
                    if model.shownScope == .yours, let note = model.billLimitNote {
                        Text(note).scaledFont(12).foregroundStyle(Palette.textMuted)
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
        .refreshable {
            await model.load()
            await model.loadSeats()
        }
        .background(alignment: .top) {
            // Arena's soft glow at the top of the ground.
            EllipticalGradient(colors: [Palette.groundGlow, Palette.ground], center: .top, startRadiusFraction: 0, endRadiusFraction: 0.6)
                .frame(height: 760)
                .ignoresSafeArea()
        }
        .background(Palette.ground)
        // Keyed by the set of your members and the chamber: following someone fetches just them, a
        // new chamber fetches its latest finals, and anything else (a first load, a refresh that was
        // cancelled) loads everything. Reordering only regroups the cards.
        .task(id: model.syncKey) { await model.sync() }
        .task(id: model.delegation?.district) { await model.loadSeats() }
        .onChange(of: model.orderKey) { model.regroup() }
        // The same search as Following › + ADD: any member, bill or topic, opened here without
        // following it first.
        .sheet(isPresented: $searching) {
            AddFollowsView(
                model: model.followSearch(),
                follows: model.follows,
                reps: model.reps.map(\.bioguideId),
                onOpenBill: { onOpen(.bill(id: $0)) },
                onOpenTopic: { onOpen(.topic(name: $0)) },
                onOpenElect: { onOpen(.elect(id: $0)) },
                onOpenMember: onOpenMember
            )
        }
    }

    private var header: some View {
        HStack {
            Text("FLOOR").font(Typography.headline(34)).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: model.delegation == nil ? onFindReps : onChangeAddress) {
                Text(model.delegation?.district.name ?? "Find my reps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.text.opacity(0.08), in: .capsule)
            }
            .accessibilityLabel(model.delegation.map { "District \($0.district.name). Change your address" }
                ?? "Find your representative and senators")
            Button { searching = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Palette.text.opacity(0.08), in: .circle)
            }
            .accessibilityLabel("Search members, bills and topics")
            AppearanceMenu()
        }
    }

    /// Your reps, minus any you hid. Members you follow are on the Following tab, not here: the
    /// strip is the mock's three, and a long follow list would not fit across.
    private var stripMembers: [Member] { model.follows.state.visibleReps(model.reps) }

    @ViewBuilder
    private var delegationStrip: some View {
        let rows = model.seatRows
        if SeatRow.changing(rows) {
            seatChangeList(rows)
        } else {
            cardStrip
        }
    }

    /// While a seat of yours is changing hands, the strip becomes the members-elect mock's "Your
    /// three" list (round 12, section A): the departing member tagged LEAVING, the elect under
    /// them, an undecided seat as its placeholder. Three across has no "under".
    private func seatChangeList(_ rows: [SeatRow]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                switch row {
                case let .member(member, leavingOn):
                    Button { onOpenMember(member) } label: { SeatMemberRow(member, leavingOn: leavingOn) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens their record")
                case let .elect(elect):
                    Button { onOpen(.elect(id: elect.id)) } label: { ElectRow(elect) }
                        .buttonStyle(.plain)
                case let .pending(seat):
                    PendingSeatCard(seat)
                }
            }
        }
    }

    private var cardStrip: some View {
        // Three across is the mock; at accessibility sizes a third of the width cannot hold a
        // surname and a seat, so the cards stack instead.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            ForEach(stripMembers) { member in
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
            Text(member.seatCaption)
                .scaledFont(10)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.delegationCard(member, withPartyShare: share))
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
                Text("The rule, the score, the twist, your members.")
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

    /// The mock's Finals switch: every recent final, or "Following" — the ones a member, bill or
    /// topic you follow is in (Round 10; it read "Your members" before bills and topics could be
    /// followed). Hidden when you follow nothing, since then "All" is the only feed there is.
    private var scopeSwitch: some View {
        HStack(spacing: 4) {
            ForEach(HomeModel.Scope.allCases, id: \.self) { option in
                let on = model.shownScope == option
                Button { model.scope = option } label: {
                    Text(option == .all ? "ALL" : "FOLLOWING")
                        .font(Typography.label(13))
                        .tracking(0.6)
                        .foregroundStyle(on ? Palette.text : Palette.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Palette.chip : Color.clear, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option == .all ? "All finals" : "Finals on members, bills and topics you follow")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
    }

    private var finalsHeader: some View {
        HStack {
            Text(model.shownScope == .yours ? "YOUR FINALS" : "FINALS").font(Typography.headline(26)).foregroundStyle(Palette.text)
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

    /// The reader's calendar with their zone and locale, for the week headers and short dates.
    private var readerCalendar: Calendar {
        var c = calendar
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    @ViewBuilder
    private var feed: some View {
        if model.visibleItems.isEmpty {
            Text(model.emptyFeedMessage)
                .font(Typography.body)
                .foregroundStyle(Palette.textMuted)
        } else {
            let cal = readerCalendar
            // Your three in "All"; everyone you follow in "Following".
            let allowed: Set<String>? = model.shownScope == .yours ? nil : Set(model.reps.map(\.bioguideId))
            ForEach(Stories.group(model.visibleItems, now: pinnedNow ?? Date(), calendar: cal)) { week in
                VStack(alignment: .leading, spacing: 14) {
                    if !week.stories.isEmpty {
                        weekHeader(week.title, range: Stories.range(week, calendar: cal))
                        ForEach(week.stories) { story in
                            StoryCard(story: story, members: Stories.members(story, allowed: allowed), calendar: cal, onOpen: onOpen)
                        }
                    }
                    if !week.minis.isEmpty {
                        weekHeader(week.stories.isEmpty ? week.title : week.alsoTitle,
                                   range: week.stories.isEmpty ? Stories.range(week, calendar: cal) : nil)
                        VStack(spacing: 8) {
                            ForEach(week.minis) { story in
                                Button { onOpen(.vote(id: story.latest.vote.id)) } label: { MiniStoryRow(story: story, calendar: cal) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekHeader(_ title: String, range: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typography.weekTitle).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let range {
                Text(range).scaledFont(Typography.Story.weekRange, weight: .semibold).foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.top, 6)
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
