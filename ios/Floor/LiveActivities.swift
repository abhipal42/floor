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
        Task {
            for await token in activity.pushTokenUpdates {
                await self.send(token.hexToken, voteId: voteId)
            }
        }
    }

    /// Tokens the API refused because this phone was not registered yet (alerts still off, or the
    /// registration not sent): kept and sent again after the next registration succeeds.
    private var unsent: [String: String] = [:]

    private func send(_ token: String, voteId: String) async {
        do {
            try await api.setActivityToken(token, voteId: voteId, key: key)
            unsent[voteId] = nil
        } catch {
            unsent[voteId] = token
        }
    }

    /// After a registration: resend what was refused, for activities still running.
    func resendUnsent() {
        let live = Set(running().keys)
        for (voteId, token) in unsent where live.contains(voteId) {
            Task { await send(token, voteId: voteId) }
        }
        unsent = unsent.filter { live.contains($0.key) }
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
                // With Live Activities off for Floor a push-to-start shows nothing — and it carries
                // the "vote opened" alert — so the token is offered only while they are on; without
                // it the worker sends a plain alert instead.
                lastStartToken = token.hexToken
                sync.pushToStartToken = enabled ? token.hexToken : nil
            }
        }
        sync.onRegistered = { [weak self] in self?.resendUnsent() }
    }

    private var lastStartToken: String?

    /// Live Activities can be turned on or off in Settings while the app is away: re-read on
    /// coming forward.
    func refreshEnabled(sync: AlertSync) {
        sync.pushToStartToken = enabled ? lastStartToken : nil
    }
}
