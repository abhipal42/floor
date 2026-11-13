import DesignSystem
import Models
import RepScreen
import SwiftUI
import VoteScreen
import BillScreen

/// The app once you are onboarded: three tabs — Finals, Bills, Your three — under the locked
/// mocks' floating tab bar.
///
/// The mocks' fourth tab, Money, is not built: it needs donor and disclosure data the API does not
/// serve. Each tab keeps its own navigation stack, so switching tabs never loses your place.
public struct FloorShell: View {
    public enum Tab: String, CaseIterable, Sendable {
        case finals = "Finals"
        case bills = "Bills"
        case yourThree = "Your three"

        var symbol: String {
            switch self {
            case .finals: "chart.bar.xaxis"
            case .bills: "doc.text"
            case .yourThree: "person"
            }
        }
    }

    @State private var model: HomeModel
    @State private var tab: Tab = .finals
    @State private var finalsPath: [HomeModel.Route] = []
    @State private var billsPath: [HomeModel.Route] = []
    @State private var threePath: [HomeModel.Route] = []
    private let onChangeAddress: () -> Void

    public init(model: HomeModel, onChangeAddress: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onChangeAddress = onChangeAddress
        FloorFonts.register()
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            stack(.finals, path: $finalsPath, title: "Finals") {
                HomeView(
                    model: model,
                    onChangeAddress: onChangeAddress,
                    onOpenMember: { member in
                        model.yourThree.selectedId = member.bioguideId
                        tab = .yourThree
                    },
                    onOpen: { finalsPath.append($0) }
                )
            }
            stack(.bills, path: $billsPath, title: "Bills") {
                BillsView(model: model) { billsPath.append(.bill(id: $0)) }
            }
            stack(.yourThree, path: $threePath, title: "Your three") {
                YourThreeView(model: model.yourThree) { threePath.append(.vote(id: $0.id)) }
            }
            tabBar
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
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
                        .darkNavigationBar()
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
            BillScreenView(model: model.billScreen(id: id)) { vote in
                path.wrappedValue.append(.vote(id: vote.id))
            }
            .navigationTitle("Bill")
        case let .member(id):
            RepScreenView(model: model.repScreen(id: id)) { vote in
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
                        case .yourThree: threePath.removeAll()
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

    @ViewBuilder
    func darkNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.ground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
