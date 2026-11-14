import ActivityKit
import APIClient
import Alerts
import Foundation
import LiveActivity
import Models

/// ActivityKit behind FloorKit's `ActivityHost`, plus the tokens the worker needs: the phone's
/// push-to-start token (to start an activity while the app is closed) and each running activity's
/// update token (to show the final and end it).
@MainActor
final class ActivityKitHost: ActivityHost {
    private let api: FloorAPI
    private let key: DeviceKey
    /// Activities whose token updates are already being watched.
    private var watching: Set<String> = []

    init(api: FloorAPI, key: DeviceKey) {
        self.api = api
        self.key = key
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var activities: [Activity<VoteActivityAttributes>] {
        Activity<VoteActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    func running() -> [String: VoteActivityAttributes.ContentState] {
        Dictionary(activities.map { ($0.attributes.voteId, $0.content.state) }, uniquingKeysWith: { a, _ in a })
    }

    func start(_ attributes: VoteActivityAttributes, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async throws {
        // `.token`: the activity gets its own push token, so the worker can end it with the final
        // even after the app has gone to the background.
        let activity = try Activity.request(
            attributes: attributes, content: ActivityContent(state: content, staleDate: staleAt), pushType: .token
        )
        watch(activity)
    }

    func update(voteId: String, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async {
        await Self.update(voteId: voteId, content, staleAt: staleAt)
    }

    func end(voteId: String, _ content: VoteActivityAttributes.ContentState, dismissAt: Date) async {
        if await Self.end(voteId: voteId, content, dismissAt: dismissAt) {
            try? await api.removeActivityToken(voteId: voteId, key: key)
        }
    }

    // `Activity` is not Sendable, so it is found and changed off the main actor rather than sent
    // across from it.
    private nonisolated static func update(voteId: String, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async {
        for activity in Activity<VoteActivityAttributes>.activities where activity.attributes.voteId == voteId {
            await activity.update(ActivityContent(state: content, staleDate: staleAt))
        }
    }

    private nonisolated static func end(voteId: String, _ content: VoteActivityAttributes.ContentState, dismissAt: Date) async -> Bool {
        var ended = false
        for activity in Activity<VoteActivityAttributes>.activities
        where activity.attributes.voteId == voteId && activity.activityState != .ended && activity.activityState != .dismissed {
            let policy: ActivityUIDismissalPolicy = dismissAt <= Date() ? .immediate : .after(dismissAt)
            await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: policy)
            ended = true
        }
        return ended
    }

    /// Sends each of an activity's push tokens to the API as it arrives.
    private func watch(_ activity: Activity<VoteActivityAttributes>) {
        guard watching.insert(activity.id).inserted else { return }
        let voteId = activity.attributes.voteId
        Task { [api, key] in
            for await token in activity.pushTokenUpdates {
                // 404 until this phone is registered (alerts off): nothing can reach it then anyway.
                try? await api.setActivityToken(token.hexToken, voteId: voteId, key: key)
            }
        }
    }

    /// Watches every activity, including ones the worker started by push while the app was closed,
    /// and the phone's push-to-start token. Runs for the app's lifetime.
    func observe(sync: AlertSync) {
        for activity in Activity<VoteActivityAttributes>.activities { watch(activity) }
        Task {
            for await activity in Activity<VoteActivityAttributes>.activityUpdates { watch(activity) }
        }
        Task {
            for await token in Activity<VoteActivityAttributes>.pushToStartTokenUpdates {
                sync.pushToStartToken = token.hexToken
            }
        }
    }
}
