import APIClient
import DesignSystem
import Home
import Models
import Onboarding
import SwiftUI
import UIKit

@main
struct FloorApp: App {
    private let store = UserDefaultsDelegationStore()
    /// Every screen's responses are saved, so the app opens on what it last showed when offline or
    /// slow, then refreshes. If the store cannot open, the app runs without one.
    private let api = FloorAPI(baseURL: FloorApp.apiBaseURL, cache: SwiftDataResponseCache.onDisk())
    @State private var delegation: Delegation?
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    init() {
        // Read once at launch, before any screen exists, so the first frame is the right one.
        _delegation = State(initialValue: UserDefaultsDelegationStore().load())
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
                if let delegation {
                    FloorShell(
                        model: HomeModel(delegation: delegation, api: api),
                        onChangeAddress: startOver
                    )
                    // A new delegation is a different feed, so the screen is rebuilt rather than
                    // reused with stale votes in it.
                    .id(delegation.district.name)
                } else {
                    OnboardingView(model: OnboardingModel(api: api, store: store)) { saved in
                        withAnimation { delegation = saved }
                    }
                }
            }
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
        store.clear()
        Task {
            await api.clearSavedResponses()
            withAnimation { delegation = nil }
        }
    }
}
