import APIClient
import Foundation
import Testing
@testable import Alerts
import Models
import Onboarding

let doggett = Member(bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX", district: 37, chamber: .house)
let cornyn = Member(bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX", district: nil, chamber: .senate)
let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: nil, chamber: .senate)
let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D", state: "NY", district: 8, chamber: .house)
let norton = Member(bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D", state: "DC", district: 0, chamber: .house)
let reps = [doggett, cornyn, cruz]
let hr1013 = BillListItem.sample

final class Recorder: DeviceRegistrar, @unchecked Sendable {
    var registered: [DeviceRegistration] = []
    var unregistered = 0
    var fails = false
    func register(_ registration: DeviceRegistration, key: DeviceKey) async throws {
        if fails { throw URLError(.notConnectedToInternet) }
        registered.append(registration)
    }
    func unregister(key: DeviceKey) async throws {
        if fails { throw URLError(.notConnectedToInternet) }
        unregistered += 1
    }
}

final class Permissions: NotificationPermissions, @unchecked Sendable {
    var current: NotificationStatus
    var answer: Bool
    var asked = 0
    init(_ current: NotificationStatus, answer: Bool = true) {
        self.current = current
        self.answer = answer
    }
    func status() async -> NotificationStatus { current }
    func request() async -> Bool {
        asked += 1
        current = answer ? .allowed : .denied
        return answer
    }
}

@MainActor
func makeSync(
    _ follows: Follows, permissions: Permissions, recorder: Recorder, defaults: UserDefaults, apns: String? = String(repeating: "ab", count: 32),
    activities: Bool = false, now: @escaping () -> Date = Date.init
) -> AlertSync {
    let sync = AlertSync(
        registrar: recorder, permissions: permissions, key: DeviceKey.generate(), environment: .sandbox,
        defaults: defaults, debounce: .seconds(600), now: now, activitiesEnabled: { activities }
    ) { (follows.state, reps) }
    sync.apnsToken = apns
    return sync
}

func freshDefaults() -> UserDefaults {
    let name = "alerts-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Alert choices in FollowState")
struct AlertChoiceTests {
    @Test func billsAndVoteOpenedStartOffAndOlderRecordsOpenWithThem() throws {
        var state = FollowState()
        state.follow(bill: hr1013)
        #expect(!state.alertsOn(bill: hr1013.id))
        #expect(!state.voteOpened)
        state.setAlerts(bill: hr1013.id, true)
        state.setVoteOpened(true)
        let decoded = try JSONDecoder().decode(FollowState.self, from: try JSONEncoder().encode(state))
        #expect(decoded.alertsOn(bill: hr1013.id))
        #expect(decoded.voteOpened)
        // A v0.2.29 record: no billAlerts, no voteOpened.
        let old = Data(#"{"entries":[],"hiddenReps":[],"alerts":{"J000294":true}}"#.utf8)
        let opened = try JSONDecoder().decode(FollowState.self, from: old)
        #expect(!opened.voteOpened)
        #expect(opened.alertsOn(member: "J000294", isRep: false))
    }

    @Test func unfollowingABillForgetsItsChoice() {
        var state = FollowState()
        state.follow(bill: hr1013)
        state.setAlerts(bill: hr1013.id, true)
        state.unfollow(bill: hr1013.id)
        state.follow(bill: hr1013)
        #expect(!state.alertsOn(bill: hr1013.id))
    }

    @Test func anythingOnIsYourRepsByDefault() {
        var state = FollowState()
        #expect(state.anyAlertOn(members: reps, reps: reps))
        for rep in reps { state.setAlerts(member: rep.bioguideId, false) }
        #expect(!state.anyAlertOn(members: reps, reps: reps))
        state.follow(member: jeffries)
        #expect(!state.anyAlertOn(members: state.yourMembers(reps: reps), reps: reps), "a followed member starts off")
        state.setVoteOpened(true)
        #expect(state.anyAlertOn(members: state.yourMembers(reps: reps), reps: reps))
    }
}

@Suite("AlertSync")
@MainActor
struct AlertSyncTests {
    @Test func registersEveryMemberAndBillWithItsSwitch() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(bill: hr1013)
        state.setAlerts(member: cruz.bioguideId, false)
        state.follow(topic: "Health")
        let r = AlertSync.registration(state: state, reps: reps, apnsToken: "t", pushToStartToken: nil, environment: .production)
        #expect(r.subscriptions == [
            DeviceSubscription(kind: .member, id: "D000399", howVoted: true),
            DeviceSubscription(kind: .member, id: "C001056", howVoted: true),
            DeviceSubscription(kind: .member, id: "C001098", howVoted: false),
            DeviceSubscription(kind: .member, id: "J000294", howVoted: false),
            DeviceSubscription(kind: .bill, id: hr1013.id, howVoted: false),
        ])
        #expect(!r.voteOpened)
        // Topics never reach the API.
        #expect(!r.subscriptions.contains { $0.id == "Health" })
    }

    @Test func registersOnlyWithPermissionAndAToken() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let permissions = Permissions(.notDetermined)
        let sync = makeSync(follows, permissions: permissions, recorder: recorder, defaults: freshDefaults(), apns: nil)
        await sync.sync()
        #expect(recorder.registered.isEmpty)
        permissions.current = .allowed
        await sync.sync()
        #expect(recorder.registered.isEmpty, "no token yet")
        sync.apnsToken = String(repeating: "ab", count: 32)
        await sync.sync()
        #expect(recorder.registered.count == 1)
        #expect(recorder.registered[0].apnsEnvironment == .sandbox)
        #expect(permissions.asked == 0, "the defaults never ask")
    }

    @Test func sendsOnlyWhatChangedAndRetriesAfterAFailure() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let defaults = freshDefaults()
        let sync = makeSync(follows, permissions: Permissions(.allowed), recorder: recorder, defaults: defaults)
        await sync.sync()
        await sync.sync()
        #expect(recorder.registered.count == 1)
        follows.update { $0.setVoteOpened(true) }
        recorder.fails = true
        await sync.sync()
        recorder.fails = false
        await sync.sync()
        #expect(recorder.registered.count == 2)
        #expect(recorder.registered.last?.voteOpened == true)
    }

    /// A cold launch: the registration exists, and the APNs token has not come back yet. Waiting is
    /// right; unregistering would delete the API's copy and every Live Activity token with it.
    @Test func aTokenNotHereYetNeverUnregisters() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let defaults = freshDefaults()
        let sync = makeSync(follows, permissions: Permissions(.allowed), recorder: recorder, defaults: defaults)
        var resent = 0
        sync.onRegistered = { resent += 1 }
        await sync.sync()
        #expect(resent == 1)
        let relaunched = makeSync(follows, permissions: Permissions(.allowed), recorder: recorder, defaults: defaults, apns: nil)
        await relaunched.sync()
        #expect(recorder.unregistered == 0)
        #expect(recorder.registered.count == 1)
    }

    /// Live Activities need no notification permission: with them enabled the phone registers
    /// without an alert token, so its activities can be started and ended by push.
    @Test func registersForLiveActivitiesWithoutNotificationPermission() async {
        let follows = Follows(store: InMemoryFollowStore())
        follows.update { state in for rep in reps { state.setAlerts(member: rep.bioguideId, false) } }
        let recorder = Recorder()
        let sync = makeSync(follows, permissions: Permissions(.denied), recorder: recorder, defaults: freshDefaults(), activities: true)
        sync.pushToStartToken = String(repeating: "cd", count: 32)
        await sync.sync()
        #expect(recorder.registered.count == 1)
        #expect(recorder.registered[0].apnsToken == nil, "no alert token without permission")
        #expect(recorder.registered[0].liveActivities)
        #expect(recorder.registered[0].pushToStartToken != nil)
    }

    /// Server-side loss heals: the same registration goes again on each launch and once a day.
    @Test func resendsOnceALaunchAndAfterADay() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let defaults = freshDefaults()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = makeSync(follows, permissions: Permissions(.allowed), recorder: recorder, defaults: defaults, now: { clock })
        await sync.sync()
        await sync.sync()
        #expect(recorder.registered.count == 1)
        clock = clock.addingTimeInterval(25 * 3600)
        await sync.sync()
        #expect(recorder.registered.count == 2)
        let relaunched = makeSync(follows, permissions: Permissions(.allowed), recorder: recorder, defaults: defaults, now: { clock })
        await relaunched.sync()
        #expect(recorder.registered.count == 3)
    }

    @Test func capsTheSubscriptionsAtTheRoutesLimit() {
        var state = FollowState()
        for i in 0..<1_005 {
            state.follow(bill: BillListItem(
                id: "119-hr-\(i)", congress: 119, type: "hr", number: i, citation: "H.R. \(i)", label: "L", title: "T",
                policyArea: nil, stage: nil, stalled: false, latestAction: nil, hasFloorVote: false
            ))
        }
        let r = AlertSync.registration(state: state, reps: reps, apnsToken: nil, pushToStartToken: nil, environment: .production)
        #expect(r.subscriptions.count == AlertSync.subscriptionCap)
        #expect(r.subscriptions.prefix(3).allSatisfy { $0.kind == .member })
        #expect(AlertSync.overCap(state: state, reps: reps))
    }

    @Test func unregistersWhenNothingIsOnOrPermissionIsGone() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let permissions = Permissions(.allowed)
        let sync = makeSync(follows, permissions: permissions, recorder: recorder, defaults: freshDefaults())
        await sync.sync()
        follows.update { state in
            for rep in reps { state.setAlerts(member: rep.bioguideId, false) }
            state.setLiveActivities(false)
        }
        await sync.sync()
        #expect(recorder.unregistered == 1)
        await sync.sync()
        #expect(recorder.unregistered == 1, "once")
        follows.update { $0.setVoteOpened(true) }
        await sync.sync()
        #expect(recorder.registered.count == 2)
        permissions.current = .denied
        await sync.sync()
        #expect(recorder.unregistered == 2)
    }
}

@Suite("Alerts screen model")
@MainActor
struct AlertsModelTests {
    @Test func listsRepsThenFollowedThenBillsWithTheMocksCaptionsAndDefaults() {
        let follows = Follows(store: InMemoryFollowStore())
        follows.update {
            $0.follow(member: jeffries)
            $0.follow(bill: hr1013)
        }
        let model = AlertsModel(follows: follows, reps: reps, sync: nil)
        #expect(model.members.map(\.caption) == ["Your rep", "Your senator", "Your senator", "Following"])
        #expect(model.members.map(\.on) == [true, true, true, false])
        #expect(model.bills.map(\.citation) == [hr1013.citation])
        #expect(model.bills.map(\.on) == [false])
        #expect(!model.voteOpened)
        #expect(AlertsModel.repCaption(norton) == "Your delegate")
        #expect(AlertsModel.citation(billId: "119-hjres-12") == "H.J.Res. 12")
    }

    @Test func turningSomethingOnAsksForPermissionOnceAndTurningItOffNever() async {
        let follows = Follows(store: InMemoryFollowStore())
        follows.update { $0.follow(member: jeffries) }
        let permissions = Permissions(.notDetermined, answer: false)
        let sync = makeSync(follows, permissions: permissions, recorder: Recorder(), defaults: freshDefaults())
        let model = AlertsModel(follows: follows, reps: reps, sync: sync)
        await model.refresh()
        #expect(model.notice == .askPermission, "reps are on by default, and Floor has never asked")
        await model.setMember(doggett.bioguideId, false)
        #expect(permissions.asked == 0)
        await model.setMember(jeffries.bioguideId, true)
        #expect(permissions.asked == 1)
        #expect(follows.state.alertsOn(member: jeffries.bioguideId, isRep: false))
        #expect(model.notice == .permissionDenied)
        await model.setVoteOpened(true)
        #expect(permissions.asked == 1, "asked once; the system would not show it again")
        #expect(follows.state.voteOpened)
    }

    @Test func showsNoNoticeWithNothingOn() async {
        let follows = Follows(store: InMemoryFollowStore())
        follows.update { state in for rep in reps { state.setAlerts(member: rep.bioguideId, false) } }
        let sync = makeSync(follows, permissions: Permissions(.denied), recorder: Recorder(), defaults: freshDefaults())
        let model = AlertsModel(follows: follows, reps: reps, sync: sync)
        await model.refresh()
        #expect(model.notice == nil)
    }

    @Test func liveActivitiesAreOnByDefaultAndNeverAskForNotifications() async {
        let follows = Follows(store: InMemoryFollowStore())
        let permissions = Permissions(.notDetermined)
        let sync = makeSync(follows, permissions: permissions, recorder: Recorder(), defaults: freshDefaults())
        let model = AlertsModel(follows: follows, reps: reps, sync: sync)
        #expect(model.liveActivities)
        await model.setLiveActivities(false)
        await model.setLiveActivities(true)
        #expect(permissions.asked == 0)
        #expect(follows.state.liveActivities)
    }
}

@Suite("Device key")
struct DeviceKeyTests {
    @Test func isRandomBase64URLAndKeptOnceMade() {
        let a = DeviceKey.generate(), b = DeviceKey.generate()
        #expect(a != b)
        #expect(a.value.count == 43)
        #expect(a.authorization.hasPrefix("Device "))
        #expect(DeviceKey(value: "short") == nil)
        let keychain = MemoryKeyStore(), defaults = freshDefaults()
        #expect(DeviceKey.stored(in: keychain, legacy: defaults) == DeviceKey.stored(in: keychain, legacy: defaults))
        #expect(defaults.string(forKey: "floor.deviceKey.v1") == nil, "kept in the Keychain, not the defaults")
    }

    @Test func movesAKeyFromTheDefaultsIntoTheKeychainAndFallsBackIfItRefuses() {
        let old = DeviceKey.generate()
        let defaults = freshDefaults()
        defaults.set(old.value, forKey: "floor.deviceKey.v1")
        let keychain = MemoryKeyStore()
        #expect(DeviceKey.stored(in: keychain, legacy: defaults) == old)
        #expect(keychain.value == old.value)
        #expect(defaults.string(forKey: "floor.deviceKey.v1") == nil)
        let refusing = MemoryKeyStore(refuses: true), fallback = freshDefaults()
        let kept = DeviceKey.stored(in: refusing, legacy: fallback)
        #expect(DeviceKey.stored(in: refusing, legacy: fallback) == kept)
    }

    @Test func tokensAreSentAsLowerCaseHex() {
        #expect(Data([0xAB, 0x01, 0xFF]).hexToken == "ab01ff")
    }

    @Test func aRegistrationEncodesEveryKeyTheRouteRequires() throws {
        let data = try JSONEncoder().encode(DeviceRegistration.sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["apnsToken", "apnsEnvironment", "pushToStartToken", "voteOpened", "liveActivities", "subscriptions"])
        #expect(object["pushToStartToken"] is NSNull)
    }
}

final class MemoryKeyStore: DeviceKeyStore, @unchecked Sendable {
    var value: String?
    let refuses: Bool
    init(refuses: Bool = false) { self.refuses = refuses }
    func read() -> String? { value }
    func write(_ value: String) -> Bool {
        guard !refuses else { return false }
        self.value = value
        return true
    }
}
