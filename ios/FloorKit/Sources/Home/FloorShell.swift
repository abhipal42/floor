import DesignSystem
import Models
import RepScreen
import SwiftUI
import VoteScreen
import BillScreen

/// The app once you are onboarded (or skipped it): three tabs — Finals, Bills, Following — under
/// the locked mocks' floating tab bar. Following replaced "Your three" (the locked
/// Following mock, <https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre>).
///
/// The mocks' fourth tab, Money, is not built: it needs donor and disclosure data the API does not
/// serve. Each tab keeps its own navigation stack, so switching tabs never loses your place.
public struct FloorShell: View {
    public enum Tab: String, CaseIterable, Sendable {
        case finals = "Finals"
        case bills = "Bills"
        case following = "Following"

        var symbol: String {
            switch self {
            case .finals: "chart.bar.xaxis"
            case .bills: "doc.text"
            case .following: "person.2"
            }
        }
    }

    @State private var model: HomeModel
    @State private var tab: Tab = .finals
    @State private var finalsPath: [HomeModel.Route] = []
    @State private var billsPath: [HomeModel.Route] = []
    @State private var followingPath: [HomeModel.Route] = []
    private let onChangeAddress: () -> Void
    /// "Find my reps", with no district: back to onboarding, keeping who you follow.
    private let onFindReps: () -> Void
    /// A link from a widget. The shell opens it on Finals and sets it back to nil.
    @Binding private var link: FloorLink?

    public init(
        model: HomeModel, onChangeAddress: @escaping () -> Void, onFindReps: @escaping () -> Void = {},
        link: Binding<FloorLink?> = .constant(nil)
    ) {
        _model = State(initialValue: model)
        self.onChangeAddress = onChangeAddress
        self.onFindReps = onFindReps
        _link = link
        FloorFonts.register()
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            stack(.finals, path: $finalsPath, title: "Finals") {
                HomeView(
                    model: model,
                    onChangeAddress: onChangeAddress,
                    onOpenMember: { finalsPath.append(.member(id: $0.bioguideId)) },
                    onOpen: { finalsPath.append($0) },
                    onFindReps: onFindReps
                )
            }
            stack(.bills, path: $billsPath, title: "Bills") {
                BillsView(model: model) { billsPath.append(.bill(id: $0)) }
            }
            stack(.following, path: $followingPath, title: "Following") {
                FollowingView(
                    model: model,
                    onOpenMember: { followingPath.append(.member(id: $0.bioguideId)) },
                    onOpenBill: { followingPath.append(.bill(id: $0)) },
                    onOpenTopic: { followingPath.append(.topic(name: $0)) },
                    onFindReps: onFindReps,
                    onChangeAddress: onChangeAddress
                )
            }
            tabBar
        }
        .tint(Palette.accent)
        .onChange(of: link, initial: true) { _, incoming in follow(incoming) }
    }

    /// A widget's vote opens on Finals, over whatever that tab was showing, as a pushed vote screen
    /// so Back returns to the feed.
    private func follow(_ incoming: FloorLink?) {
        guard let incoming else { return }
        link = nil
        switch incoming {
        case let .vote(id):
            tab = .finals
            finalsPath = [.vote(id: id)]
        case .open:
            break
        }
    }

    private func stack<Root: View>(
        _ which: Tab, path: Binding<[HomeModel.Route]>, title: String, @ViewBuilder root: () -> Root
    ) -> some View {
        let shown = tab == which
        return NavigationStack(path: path) {
            root()
                .clearsTabBar()
                // The root screens hide the navigation bar, so give the status bar a ground to sit
                // on rather than letting cards scroll under the clock.
                .overlay(alignment: .top) {
                    Color.clear.frame(height: 0)
                        .background((which == .finals ? Palette.groundGlow : Palette.ground).opacity(0.94).ignoresSafeArea(edges: .top))
                }
                .navigationTitle(title)
                .hideNavigationBar()
                .navigationDestination(for: HomeModel.Route.self) { route in
                    destination(route, path: path)
                        .clearsTabBar()
                        .groundNavigationBar()
                }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
    }

    @ViewBuilder
    private func destination(_ route: HomeModel.Route, path: Binding<[HomeModel.Route]>) -> some View {
        switch route {
        case let .vote(id):
            VoteScreenView(
                model: model.voteScreen(id: id),
                onOpenMeasure: { measure in
                    if measure.kind == .bill { path.wrappedValue.append(.bill(id: measure.id)) }
                },
                onOpenMember: { path.wrappedValue.append(.member(id: $0.bioguideId)) }
            )
            .navigationTitle("Vote")
        case let .bill(id):
            BillScreenView(
                model: model.billScreen(id: id), follows: model.follows,
                onOpenTopic: { path.wrappedValue.append(.topic(name: $0)) }
            ) { vote in
                path.wrappedValue.append(.vote(id: vote.id))
            }
            .navigationTitle("Bill")
        case let .topic(name):
            TopicPageView(model: model.topicPage(name: name), follows: model.follows) {
                path.wrappedValue.append(.bill(id: $0))
            }
            .navigationTitle(name)
            .toolbar {
                // The name is the page's own headline; an empty principal item keeps the bar from
                // printing it a second time, while the navigation title still names the back link.
                ToolbarItem(placement: .principal) { Text(verbatim: " ").accessibilityHidden(true) }
            }
        case let .member(id):
            RepScreenView(model: model.repScreen(id: id), follows: model.follows, reps: model.reps.map(\.bioguideId)) { vote in
                path.wrappedValue.append(.vote(id: vote.id))
            }
            .navigationTitle("Member")
        case .catchUp:
            CatchUpDeckView(model: model) { path.wrappedValue.append(.vote(id: $0)) }
                .navigationTitle("Catch up")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                let on = tab == item
                Button {
                    if tab == item {
                        // A second tap on the current tab goes back to its top, as system tab bars do.
                        switch item {
                        case .finals: finalsPath.removeAll()
                        case .bills: billsPath.removeAll()
                        case .following: followingPath.removeAll()
                        }
                    }
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 19, weight: .medium)).frame(height: 22)
                        Text(item.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(on ? Palette.yea : Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(8)
        .background(Palette.panel.opacity(0.94), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.panelBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

extension View {
    /// Room under every screen for the floating tab bar, so the last card can scroll clear of it.
    func clearsTabBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 76) }
    }

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

    /// The pushed screens' bar sits on the ground colour, light or dark with the system.
    @ViewBuilder
    func groundNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.ground, for: .navigationBar)
        #else
        self
        #endif
    }
}

#Preview("Floor") {
    // Needs `npm run dev -w @floor/api` running to fill the feed.
    FloorShell(
        model: HomeModel(delegation: .sample, api: .init(baseURL: URL(string: "http://localhost:8787")!)),
        onChangeAddress: {}
    )
}
