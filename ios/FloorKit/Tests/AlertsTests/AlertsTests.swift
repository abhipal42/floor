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
    _ follows: Follows, permissions: Permissions, recorder: Recorder, defaults: UserDefaults, apns: String? = String(repeating: "ab", count: 32)
) -> AlertSync {
    let sync = AlertSync(
        registrar: recorder, permissions: permissions, key: DeviceKey.generate(), environment: .sandbox,
        defaults: defaults, debounce: .seconds(600)
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

    @Test func unregistersWhenNothingIsOnOrPermissionIsGone() async {
        let follows = Follows(store: InMemoryFollowStore())
        let recorder = Recorder()
        let permissions = Permissions(.allowed)
        let sync = makeSync(follows, permissions: permissions, recorder: recorder, defaults: freshDefaults())
        await sync.sync()
        follows.update { state in for rep in reps { state.setAlerts(member: rep.bioguideId, false) } }
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
}

@Suite("Device key")
struct DeviceKeyTests {
    @Test func isRandomBase64URLAndKeptOnceMade() {
        let a = DeviceKey.generate(), b = DeviceKey.generate()
        #expect(a != b)
        #expect(a.value.count == 43)
        #expect(a.authorization.hasPrefix("Device "))
        #expect(DeviceKey(value: "short") == nil)
        let defaults = freshDefaults()
        #expect(DeviceKey.stored(in: defaults) == DeviceKey.stored(in: defaults))
    }

    @Test func tokensAreSentAsLowerCaseHex() {
        #expect(Data([0xAB, 0x01, 0xFF]).hexToken == "ab01ff")
    }

    @Test func aRegistrationEncodesEveryKeyTheRouteRequires() throws {
        let data = try JSONEncoder().encode(DeviceRegistration.sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["apnsToken", "apnsEnvironment", "pushToStartToken", "voteOpened", "subscriptions"])
        #expect(object["pushToStartToken"] is NSNull)
    }
}
