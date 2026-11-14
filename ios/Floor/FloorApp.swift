import Alerts
import APIClient
import DesignSystem
import Home
import LiveActivity
import Models
import Onboarding
import SwiftUI
import UIKit
import WidgetFeed
import WidgetKit

@main
struct FloorApp: App {
    /// The APNs token, notification taps, and alerts arriving while the app is open.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// In the App Group, so the widget sees the district too. The first launch of this build moves
    /// a delegation saved by an older one out of the app's own defaults.
    private let store: UserDefaultsDelegationStore
    /// Every screen's responses are saved, so the app opens on what it last showed when offline or
    /// slow, then refreshes. If the store cannot open, the app runs without one.
    private let api: FloorAPI
    @State private var delegation: Delegation?
    /// Who you follow, in the App Group beside the district so the widget sees it too. No account:
    /// it lives on this phone.
    @State private var follows: Follows
    /// Keeps the API's copy of the Alerts screen's choices current (`PUT /v1/devices`).
    @State private var alertSync: AlertSync
    /// ActivityKit, and the foreground poller that starts and ends Live Activities from `/v1/live`.
    private let activityHost: ActivityKitHost
    @State private var liveActivities: LiveActivityCoordinator
    @State private var polling: Task<Void, Never>?
    /// "Skip, I'll pick members myself" on onboarding: the app runs with no district until "Find my
    /// reps". A preference, not data about you, so it stays in the app's own defaults.
    @AppStorage("floor.districtSkipped.v1") private var skippedDistrict = false
    /// A `floor://` link from a widget or an alert, waiting for the shell to open it.
    @State private var pendingLink: FloorLink?
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    init() {
        let api = FloorAPI(baseURL: FloorApp.apiBaseURL, cache: SwiftDataResponseCache.onDisk())
        self.api = api
        // Read once at launch, before any screen exists, so the first frame is the right one.
        let store = UserDefaultsDelegationStore.shared()
        self.store = store
        _delegation = State(initialValue: store.load())
        // Following changes what the widgets show (the small one's latest final, the medium one's
        // default rows), so changes tell them to look again — once things settle, not per tap: a
        // burst of follows in the search sheet is one reload, not one each. The same change may
        // change what alerts this phone wants, so the registration is synced too.
        let reload = WidgetReload()
        let follows = Follows(store: UserDefaultsFollowStore.shared()) {
            reload.soon()
            PushRelay.shared.sync?.schedule()
        }
        _follows = State(initialValue: follows)

        let key = DeviceKey.stored()
        let sync = AlertSync(
            registrar: api, permissions: SystemNotificationPermissions(), key: key, environment: FloorApp.apnsEnvironment,
            onAllowed: { PushRelay.shared.registerForRemoteNotifications() }
        ) {
            // Read at sync time: the district can change ("Change address") while the app runs.
            (follows.state, store.load()?.members ?? [])
        }
        _alertSync = State(initialValue: sync)
        PushRelay.shared.sync = sync

        let host = ActivityKitHost(api: api, key: key)
        activityHost = host
        _liveActivities = State(initialValue: LiveActivityCoordinator(source: api, host: host) {
            let state = follows.state
            return .init(
                members: state.yourMembers(reps: store.load()?.members ?? []),
                bills: Set(state.followedBillIds),
                voteOpened: state.voteOpened
            )
        })
        host.observe(sync: sync)

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

    /// Which APNs gateway this build's tokens belong to (`FloorAPNSEnvironment`, from the
    /// `FLOOR_APNS_ENV` build setting): `sandbox` for a Debug build run from Xcode, `production`
    /// for TestFlight and the App Store.
    static var apnsEnvironment: DeviceRegistration.Environment {
        (Bundle.main.object(forInfoDictionaryKey: "FloorAPNSEnvironment") as? String)
            .flatMap(DeviceRegistration.Environment.init(rawValue:)) ?? .production
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if delegation != nil || skippedDistrict {
                    FloorShell(
                        model: homeModel(),
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
                        alertSync.schedule()
                    }
                }
            }
            // Before onboarding there is no vote screen to open, so a link waits until there is.
            .onOpenURL { url in pendingLink = FloorLink(url: url) }
            .onChange(of: appearance, initial: true) { _, choice in Self.apply(choice) }
            .onAppear { PushRelay.shared.onLink = { link in pendingLink = link } }
            .onChange(of: scenePhase, initial: true) { _, phase in foreground(phase == .active) }
        }
    }

    private func homeModel() -> HomeModel {
        let model = HomeModel(delegation: delegation, follows: follows, api: api)
        model.alertSync = alertSync
        return model
    }

    /// Live Activities poll `/v1/live` only while the app is in front; nothing polls in the
    /// background (a vote that opens then arrives by push-to-start). Coming forward also rereads the
    /// notification permission, which may have changed in Settings.
    private func foreground(_ active: Bool) {
        polling?.cancel()
        polling = nil
        guard active else { return }
        polling = Task { await liveActivities.run() }
        Task {
            await alertSync.refreshPermission()
            alertSync.schedule()
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
        // The registration named the old reps; re-sync it for who is left.
        alertSync.schedule()
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
