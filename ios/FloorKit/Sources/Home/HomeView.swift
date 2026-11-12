import APIClient
import DesignSystem
import Models
import Onboarding
import BillScreen
import SwiftUI
import VoteScreen

/// The Floor screen: your delegation, then their recent votes.
///
/// Follows the v2 canvas's Home artboard, minus the sections that need data we do not have yet —
/// the live strip, the projection row and the "For you" block are M3 and M4.
public struct HomeView: View {
    @State private var model: HomeModel
    @State private var path: [HomeModel.Route] = []
    private let onChangeAddress: () -> Void

    public init(model: HomeModel, onChangeAddress: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onChangeAddress = onChangeAddress
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                background
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        delegationStrip
                        chamberFilter
                        feed
                    }
                    .padding(.bottom, 28)
                }
                .refreshable { await model.load() }
            }
            .hideNavigationBar()
            .navigationDestination(for: HomeModel.Route.self) { route in
                switch route {
                case let .vote(id):
                    VoteScreenView(model: model.voteScreen(id: id)) { measure in
                        if measure.kind == .bill { path.append(.bill(id: measure.id)) }
                    }
                    .navigationTitle("Vote")
                    .inlineNavigationTitle()
                case let .bill(id):
                    BillScreenView(model: model.billScreen(id: id)) { vote in
                        path.append(.vote(id: vote.id))
                    }
                    .navigationTitle("Bill")
                    .inlineNavigationTitle()
                }
            }
        }
        .tint(Palette.accent)
        .task { if model.items.isEmpty { await model.load() } }
        .preferredColorScheme(.dark)
    }

    /// The canvas puts a green wash behind the top of the screen, fading to the ground by 440pt.
    private var background: some View {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x0B4A33), location: 0),
                .init(color: Color(hex: 0x08251A), location: 0.13),
                .init(color: Palette.ground, location: 0.28),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        // The district appears once, in the chip that changes it; the canvas's second line is the
        // day's session status, which needs floor data we do not have yet.
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Floor")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(action: onChangeAddress) {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 12, weight: .bold))
                        Text(model.delegation.district.name).font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.12), in: .capsule)
                    .foregroundStyle(Palette.text)
                }
                .accessibilityLabel("Change your district")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var delegationStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.delegation.members) { member in
                    VStack(spacing: 6) {
                        Text(initials(member))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.text)
                            .frame(width: 46, height: 46)
                            .background(Palette.partyTint(member.party), in: .circle)
                            .overlay(alignment: .bottomTrailing) {
                                Text(member.party)
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Palette.ground)
                                    .frame(width: 19, height: 19)
                                    .background(Palette.party(member.party), in: .circle)
                                    .overlay(Circle().stroke(Palette.card, lineWidth: 2))
                                    .offset(x: 3, y: 2)
                            }
                        Text(member.lastName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Text(member.chamber == .house ? "Rep." : "Senator")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .frame(width: 104)
                    .padding(.vertical, 12)
                    .background(Palette.card, in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.cardBorder, lineWidth: 1))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(member.fullName), \(member.chamber == .house ? "Representative" : "Senator")"
                    )
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 18)
    }

    private var chamberFilter: some View {
        HStack(spacing: 8) {
            ForEach(HomeModel.Filter.allCases, id: \.self) { option in
                let selected = model.filter == option
                Button { model.filter = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(selected ? Palette.accent : Palette.chip, in: .capsule)
                        .foregroundStyle(selected ? Palette.ground : Palette.textSecondary)
                }
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    @ViewBuilder
    private var feed: some View {
        switch model.phase {
        case .loading:
            HStack {
                Spacer()
                ProgressView().tint(Palette.accent)
                Spacer()
            }
            .padding(.top, 48)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Button("Try again") { Task { await model.load() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 14)
            .padding(.top, 22)
        case .loaded:
            if model.visibleItems.isEmpty {
                Text("No recent votes in this chamber.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
            } else {
                VStack(spacing: 10) {
                    sectionTitle
                    ForEach(model.visibleItems) { item in
                        NavigationLink(value: HomeModel.Route.vote(id: item.vote.id)) {
                            card(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
            }
        }
    }

    private var sectionTitle: some View {
        HStack {
            Text("Recent votes")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.text)
            Spacer()
            Text("\(model.visibleItems.count)")
                .font(Typography.body)
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, 6)
    }

    private func card(_ item: FeedItem) -> some View {
        VStack(spacing: 8) {
            ScoreboardCard(vote: item.vote, title: item.title)
            if !item.positions.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.isSplit ? Palette.scheduled : Palette.accent)
                        .frame(width: 6, height: 6)
                    Text(item.summary)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func initials(_ member: Member) -> String {
        let first = member.firstName.first.map(String.init) ?? ""
        let last = member.lastName.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

private extension View {
    /// Navigation-bar styling that exists only on iOS. The package also builds for macOS, where
    /// `swift test` runs the models, so these cannot be applied unconditionally.
    @ViewBuilder
    func hideNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#Preview("Home") {
    // Needs `npm run dev -w @floor/api` running to fill the feed.
    HomeView(
        model: HomeModel(delegation: .sample, api: FloorAPI(baseURL: FloorAPI.localDevelopment)),
        onChangeAddress: {}
    )
}
