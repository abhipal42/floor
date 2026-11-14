import Alerts
import Models
import UIKit
import UserNotifications

/// The system's half of alerts: the APNs token, notification permission, and what a tap on an
/// alert opens. Everything that decides *what* to register lives in FloorKit's `Alerts` module.
@MainActor
final class PushRelay {
    static let shared = PushRelay()

    /// Set once the app has built its `AlertSync`; a token that arrives earlier waits here.
    var sync: AlertSync? {
        didSet { if let token = pendingToken { sync?.apnsToken = token } }
    }
    private var pendingToken: String?
    /// A tapped alert's `floor://` link, for the shell to open.
    var onLink: ((FloorLink) -> Void)?

    func received(token: Data) {
        let hex = token.hexToken
        pendingToken = hex
        sync?.apnsToken = hex
    }

    /// Asks APNs for a token; harmless to repeat, and only called once alerts are allowed.
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRelay.shared.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // No token (the simulator without a paired device, no network): nothing registers, and the
        // next launch asks again.
    }

    /// An alert that arrives while Floor is open still shows: the vote screen is a tap away.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the vote (`link: floor://vote/<id>`), or Finals for the day's digest.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: raw), let link = FloorLink(url: url) else { return }
        await MainActor.run { PushRelay.shared.onLink?(link) }
    }
}

/// `UNUserNotificationCenter`, as the `Alerts` module sees it.
struct SystemNotificationPermissions: NotificationPermissions {
    func status() async -> NotificationStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
