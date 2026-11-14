import APIClient
import DesignSystem
import Home
import Models
import Onboarding
import SwiftUI
import UIKit
import WidgetFeed
import WidgetKit

@main
struct FloorApp: App {
    /// In the App Group, so the widget sees the district too. The first launch of this build moves
    /// a delegation saved by an older one out of the app's own defaults.
    private let store: UserDefaultsDelegationStore
    /// Every screen's responses are saved, so the app opens on what it last showed when offline or
    /// slow, then refreshes. If the store cannot open, the app runs without one.
    private let api = FloorAPI(baseURL: FloorApp.apiBaseURL, cache: SwiftDataResponseCache.onDisk())
    @State private var delegation: Delegation?
    /// Who you follow, in the App Group beside the district so the widget sees it too. No account:
    /// it lives on this phone.
    @State private var follows: Follows
    /// "Skip, I'll pick members myself" on onboarding: the app runs with no district until "Find my
    /// reps". A preference, not data about you, so it stays in the app's own defaults.
    @AppStorage("floor.districtSkipped.v1") private var skippedDistrict = false
    /// A `floor://` link from a widget, waiting for the shell to open it.
    @State private var pendingLink: FloorLink?
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    init() {
        // Read once at launch, before any screen exists, so the first frame is the right one.
        let store = UserDefaultsDelegationStore.shared()
        self.store = store
        _delegation = State(initialValue: store.load())
        // Following changes what the widgets show (the small one's latest final, the medium one's
        // default rows), so changes tell them to look again — once things settle, not per tap: a
        // burst of follows in the search sheet is one reload, not one each.
        let reload = WidgetReload()
        _follows = State(initialValue: Follows(store: UserDefaultsFollowStore.shared()) { reload.soon() })
        // An upgrade from before the widget just copied the district into the App Group. A widget
        // already on the home screen last read an empty group and says "pick your members"; tell
        // it to look again rather than wait out its 30 minutes.
        if store.movedFromLegacy {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Where the API lives.
    ///
    /// Taken from the `FloorAPIBaseURL` Info.plist key when it is set, so staging and production
    /// builds differ by configuration rather than code. Until the API is deployed there is nothing
    /// to point at, so this falls back to the local dev server: run `npm run dev -w @floor/api`
    /// and the Simulator reaches it on localhost.
    static var apiBaseURL: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FloorAPIBaseURL") as? String,
           let url = URL(string: configured) {
            return url
        }
        return FloorAPI.localDevelopment
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if delegation != nil || skippedDistrict {
                    FloorShell(
                        model: HomeModel(delegation: delegation, follows: follows, api: api),
                        onChangeAddress: startOver,
                        onFindReps: { withAnimation { skippedDistrict = false } },
                        link: $pendingLink
                    )
                    // A new delegation is a different feed, so the screen is rebuilt rather than
                    // reused with stale votes in it.
                    .id(delegation?.district.name ?? "no district")
                } else {
                    OnboardingView(
                        model: OnboardingModel(api: api, store: store),
                        onSkip: { withAnimation { skippedDistrict = true } }
                    ) { saved in
                        skippedDistrict = false
                        // Anyone you followed before finding your district who is one of its members
                        // is a rep now: pinned and hideable, not listed twice.
                        follows.adopt(saved)
                        withAnimation { delegation = saved }
                        // The widgets were showing "pick your members"; now they have some.
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
            // Before onboarding there is no vote screen to open, so a link waits until there is.
            .onOpenURL { url in pendingLink = FloorLink(url: url) }
            .onChange(of: appearance, initial: true) { _, choice in Self.apply(choice) }
        }
    }

    /// Sets the window's own style rather than `preferredColorScheme`, which does not reliably go
    /// back to following the system once it has been set to nil. `.unspecified` follows it.
    @MainActor
    private static func apply(_ choice: Appearance) {
        let style: UIUserInterfaceStyle = switch choice {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }

    /// Forgets the district, and every saved response with it: those name the old members, so they
    /// would say where you used to live. Onboarding appears only once they are gone, so nothing the
    /// new district saves can be swept up by the clear.
    private func startOver() {
        // A hidden rep or an alert choice for one names the old district too; who you follow stays.
        let oldReps = delegation?.memberIds ?? []
        follows.update { $0.forgetReps(oldReps) }
        store.clear()
        // The widget's saved votes name the old members too.
        WidgetSnapshotStore.shared()?.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Task {
            await api.clearSavedResponses()
            withAnimation {
                delegation = nil
                skippedDistrict = false
            }
        }
    }
}

/// Reloads the widgets a couple of seconds after the last change asked for it.
@MainActor
final class WidgetReload {
    private var pending: Task<Void, Never>?

    func soon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
