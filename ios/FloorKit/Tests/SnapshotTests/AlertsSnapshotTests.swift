#if os(iOS)
import Alerts
import APIClient
import DesignSystem
import Foundation
import Home
import LiveActivity
import Models
import Onboarding
import SnapshotTesting
import SwiftUI
import Testing

/// Round 8's Live Activity and Dynamic Island (sections A-B of
/// <https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn>) and the Alerts screen (round 9, section C of
/// <https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre>). The activity's content is the worker's own
/// contract fixture (`live-activity-*.json`): H.R. 1013, House roll call 321, Nov 11, 2026.
@MainActor
@Suite("Alerts and Live Activity snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct AlertsSnapshotTests {
    private let eastern = TimeZone(identifier: "America/New_York")!

    private func activity() throws -> (VoteActivityAttributes, open: VoteActivityAttributes.ContentState, final: VoteActivityAttributes.ContentState) {
        (try fixture("live-activity-attributes-hr1013"), try fixture("live-activity-open-hr1013"), try fixture("live-activity-final-hr1013"))
    }

    /// The lock screen's frosted panel, as `activityBackgroundTint` draws it over a wallpaper.
    private func onLockScreen<V: View>(_ view: V) -> some View {
        view
            .background(Color(red: 10 / 255, green: 11 / 255, blue: 14 / 255).opacity(0.92), in: .rect(cornerRadius: 24))
            .padding(8)
            .background(Color(red: 0.05, green: 0.08, blue: 0.13), in: .rect(cornerRadius: 30))
    }

    // MARK: - Live Activity

    @Test func liveActivityOpen() throws {
        let (a, open, _) = try activity()
        assertCard(onLockScreen(VoteActivityLockScreen(attributes: a, content: open, timeZone: eastern)))
    }

    @Test func liveActivityFinal() throws {
        let (a, _, final) = try activity()
        assertCard(onLockScreen(VoteActivityLockScreen(attributes: a, content: final, timeZone: eastern)), [.light, .dark])
    }

    /// The mock's third phone: a Senate vote lists both senators, timed by when the floor named it.
    @Test func liveActivitySenateTwoMembers() throws {
        let a = VoteActivityAttributes(
            voteId: "senate-119-2-300", chamber: .senate, kind: .question, rollNumber: nil, threshold: .majority,
            question: "Motion to Proceed", citation: "H.R. 2347", title: nil
        )
        let content = VoteActivityAttributes.ContentState(
            state: .open, result: nil, totals: nil, openedAt: nil, calledAt: "2026-11-11T19:31:00.000Z",
            members: [
                .init(id: "C001056", name: "Cornyn", position: nil, choice: nil),
                .init(id: "C001098", name: "Cruz", position: nil, choice: nil),
            ],
            moreMembers: 0
        )
        assertCard(onLockScreen(VoteActivityLockScreen(attributes: a, content: content, timeZone: eastern)), [.dark])
    }

    /// Long-press: the expanded island's body, and compact (open, final) and minimal beside it.
    @Test func dynamicIsland() throws {
        let (a, open, final) = try activity()
        let island = VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ChamberTile(size: 22)
                    Text(VoteActivityText.header(a).uppercased()).font(Typography.label(12)).foregroundStyle(Palette.textMuted).litObject()
                    Spacer()
                    VoteActivityStatus(content: final).litObject()
                }
                VoteActivityExpanded(attributes: a, content: final, timeZone: eastern)
            }
            .padding(16)
            .background(Color.black, in: .rect(cornerRadius: 34))
            ForEach([open, final], id: \.state) { content in
                HStack {
                    VoteActivityCompactLeading(attributes: a, content: content)
                    Spacer(minLength: 40)
                    VoteActivityCompactTrailing(content: content)
                }
                .padding(.horizontal, 12)
                .frame(width: 250, height: 36)
                .background(Color.black, in: .capsule)
            }
            VoteActivityMinimal().frame(width: 36, height: 36).background(Color.black, in: .circle)
        }
        assertCard(island, [.dark])
    }

    // MARK: - Alerts screen

    private static let schumer = Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D", state: "NY", district: nil, chamber: .senate)
    private static let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D", state: "NY", district: 8, chamber: .house)
    private static let hageman = Member(bioguideId: "H001096", firstName: "Harriet", lastName: "Hageman", party: "R", state: "WY", district: 0, chamber: .house)

    /// The mock's screen: your three reps on, Jeffries turned on, Schumer and Hageman off; plus a
    /// followed bill (off) — the extension to bills — and "A vote opened" off.
    private func mockFollows() throws -> (Follows, [Member]) {
        var state = FollowState()
        for member in [Self.hageman, Self.schumer, Self.jeffries] { state.follow(member: member) }
        let search: SearchResults = try fixture("search-hr1013")
        state.follow(bill: try #require(search.bills.first))
        state.setAlerts(member: Self.jeffries.bioguideId, true)
        state.follow(topic: "Health")
        return (Follows(store: InMemoryFollowStore(state)), try austin().members)
    }

    @Test func alertsScreen() throws {
        let (follows, reps) = try mockFollows()
        let view = NavigationStack { AlertsView(model: AlertsModel(follows: follows, reps: reps, sync: nil)) }
        assertScreen(view, height: 1000)
    }

    /// Alerts on, and Floor has never asked: the card that asks, which the defaults alone never do.
    @Test func alertsAskForPermission() async throws {
        let (follows, reps) = try mockFollows()
        let sync = AlertSync(
            registrar: NoRegistrar(), permissions: FixedPermission(value: .notDetermined), key: .generate(),
            environment: .sandbox, defaults: UserDefaults(suiteName: "alerts-snapshot")!, debounce: .seconds(600)
        ) { (follows.state, reps) }
        await sync.refreshPermission()
        let view = NavigationStack { AlertsView(model: AlertsModel(follows: follows, reps: reps, sync: sync)) }
        assertScreen(view, height: 700, [.light, .dark])
    }

    /// Following's top bar with the bell that opens Alerts.
    @Test func followingTopBarBell() throws {
        let model = HomeModel(delegation: nil, follows: Follows(store: InMemoryFollowStore()), api: FixtureServer.api)
        let view = FollowingView(model: model, onOpenMember: { _ in }, onOpenAlerts: {}, onFindReps: {}, onChangeAddress: {})
        assertScreen(view, height: 220, [.light, .dark])
    }

    @Test func alertsNothingFollowed() throws {
        let view = NavigationStack {
            AlertsView(model: AlertsModel(follows: Follows(store: InMemoryFollowStore()), reps: [], sync: nil))
        }
        assertScreen(view, height: 500, [.light])
    }
}

private struct NoRegistrar: DeviceRegistrar {
    func register(_ registration: DeviceRegistration, key: DeviceKey) async throws {}
    func unregister(key: DeviceKey) async throws {}
}

private struct FixedPermission: NotificationPermissions {
    let value: NotificationStatus
    func status() async -> NotificationStatus { value }
    func request() async -> Bool { false }
}
#endif
