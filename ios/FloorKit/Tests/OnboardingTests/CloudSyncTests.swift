import Foundation
import Models
@testable import Onboarding
import Testing

private let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D",
                              state: "NY", district: 8, chamber: .house)
private let schumer = Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D",
                             state: "NY", district: nil, chamber: .senate)

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

/// The iCloud merge (round 11, section F): a union by entry, last write wins per entry between a
/// follow and an unfollow (tombstone), and the other choices taken whole from the newer copy.
@Suite("iCloud merge")
struct FollowMergeTests {
    @Test func aFollowOnEitherPhoneIsKept() {
        var a = FollowState()
        a.follow(member: jeffries, at: at(1))
        var b = FollowState()
        b.follow(topic: "Health", at: at(2))
        let merged = a.merged(with: b)
        #expect(merged.isFollowing(member: jeffries.bioguideId))
        #expect(merged.isFollowing(topic: "Health"))
        // The other phone's new entries go in front, as following adds to the front.
        #expect(merged.entries.map(\.key) == ["topic:Health", "member:J000294"])
        #expect(b.merged(with: a).entries.count == 2)
    }

    @Test func anUnfollowAfterTheFollowWins() {
        var a = FollowState()
        a.follow(member: jeffries, at: at(1))
        var b = a
        b.unfollow(.member, jeffries.bioguideId, at: at(5))
        let merged = a.merged(with: b)
        #expect(!merged.isFollowing(member: jeffries.bioguideId))
        #expect(merged.removed["member:J000294"] == at(5))
        // Either way round.
        #expect(!b.merged(with: a).isFollowing(member: jeffries.bioguideId))
    }

    @Test func aFollowAfterTheUnfollowWins() {
        var a = FollowState()
        a.follow(member: jeffries, at: at(1))
        a.unfollow(.member, jeffries.bioguideId, at: at(2))
        var b = FollowState()
        b.follow(member: jeffries, at: at(3))
        let merged = a.merged(with: b)
        #expect(merged.isFollowing(member: jeffries.bioguideId))
        #expect(merged.removed["member:J000294"] == nil, "a kept follow clears its tombstone")
        #expect(merged.followedMembers == [jeffries])
    }

    @Test func theNewerSettingsAreTakenWhole() {
        var a = FollowState()
        a.follow(bill: .sample, at: at(0))
        var b = a
        a.setVoteOpened(true) // now
        b.setBillStep(\.committee, true)
        b.setAlerts(bill: BillListItem.sample.id, true) // later than a's change
        let merged = a.merged(with: b)
        #expect(merged.billSteps.committee)
        #expect(merged.alertsOn(bill: BillListItem.sample.id))
        #expect(!merged.voteOpened, "settings are one record: b changed last, so b's voteOpened")
        #expect(merged.settingsChangedAt == b.settingsChangedAt)
    }

    @Test func mergingIsStableAndKeepsRecords() {
        var a = FollowState()
        a.follow(.member, schumer.bioguideId, at: at(1))
        var b = FollowState()
        b.follow(member: schumer, at: at(1))
        let merged = a.merged(with: b)
        #expect(merged.followedMembers == [schumer], "the record comes from whichever copy has it")
        #expect(merged.merged(with: b) == merged)
        #expect(merged.merged(with: merged) == merged)
    }

    @Test func oldTombstonesArePruned() {
        var a = FollowState()
        a.follow(topic: "Health", at: at(0))
        a.unfollow(.topic, "Health", at: at(0))
        #expect(a.pruned(now: at(1)).removed.count == 1)
        #expect(a.pruned(now: t0.addingTimeInterval(FollowState.tombstoneLifetime + 1)).removed.isEmpty)
    }

    @Test func oldRecordsStillOpen() throws {
        // A record saved before round 11: no steps, tombstones or settings date.
        let old = Data(#"{"entries":[],"hiddenReps":[],"alerts":{},"voteOpened":true,"liveActivities":true}"#.utf8)
        let state = try JSONDecoder().decode(FollowState.self, from: old)
        #expect(state.billSteps == .defaults)
        #expect(state.removed.isEmpty)
        #expect(state.settingsChangedAt == .distantPast)
        #expect(state.voteOpened)
    }
}

@Suite("iCloud sync")
@MainActor
struct CloudSyncTests {
    private final class Delegations: DelegationStore, @unchecked Sendable {
        var stored: Delegation?
        init(_ stored: Delegation? = nil) { self.stored = stored }
        func load() -> Delegation? { stored }
        func save(_ delegation: Delegation) { stored = delegation }
        func clear() { stored = nil }
    }

    private func defaults() -> UserDefaults {
        let name = "cloud-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func availabilityFollowsTheBuild() {
        #expect(!CloudSync.isAvailable(info: nil))
        #expect(!CloudSync.isAvailable(info: ["FloorICloudKVS": ""]))
        #expect(!CloudSync.isAvailable(info: ["FloorICloudKVS": "$(FLOOR_ICLOUD_KVS)"]))
        // Unsigned: no team prefix, so the value is just the bundle id.
        #expect(!CloudSync.isAvailable(info: ["FloorICloudKVS": "app.floor.ios", "CFBundleIdentifier": "app.floor.ios"]))
        #expect(CloudSync.isAvailable(info: ["FloorICloudKVS": "ABCDE12345.app.floor.ios", "CFBundleIdentifier": "app.floor.ios"]))
    }

    @Test func withoutTheStoreItIsAPlaceholderThatNeverTurnsOn() {
        let sync = CloudSync(follows: Follows(store: InMemoryFollowStore()), delegations: Delegations(), cloud: nil, defaults: defaults())
        #expect(sync.status == .unavailable)
        sync.setEnabled(true)
        #expect(sync.status == .unavailable)
    }

    @Test func twoPhonesConverge() throws {
        let cloud = InMemoryCloudStore()
        let phoneA = Follows(store: InMemoryFollowStore())
        let phoneB = Follows(store: InMemoryFollowStore())
        let delegation = Delegation(district: District(congress: 119, state: "NY", district: 8, countyFips: nil), members: [jeffries, schumer])
        let storeA = Delegations(delegation)
        let storeB = Delegations()
        let a = CloudSync(follows: phoneA, delegations: storeA, cloud: cloud, defaults: defaults(), now: { at(10) })
        let b = CloudSync(follows: phoneB, delegations: storeB, cloud: cloud, defaults: defaults(), now: { at(20) })
        var incoming: Delegation??
        b.onDelegation = { incoming = $0 }

        phoneA.update { $0.follow(topic: "Health", at: at(1)) }
        a.setEnabled(true)
        #expect(a.status == .on(lastSynced: at(10)))

        phoneB.update { $0.follow(bill: .sample, at: at(2)) }
        b.setEnabled(true)
        #expect(phoneB.state.isFollowing(topic: "Health"))
        #expect(phoneB.state.isFollowing(bill: BillListItem.sample.id))
        // The district came across as a district: no address anywhere in what iCloud holds.
        #expect(storeB.stored == delegation)
        #expect(incoming == .some(delegation))
        let payload = try #require(cloud.data(forKey: CloudSync.cloudKey))
        #expect(!String(decoding: payload, as: UTF8.self).contains("address"))

        a.pull()
        #expect(phoneA.state.isFollowing(bill: BillListItem.sample.id))

        // An unfollow on B reaches A.
        phoneB.update { $0.unfollow(.topic, "Health", at: at(30)) }
        b.push()
        a.pull()
        #expect(!phoneA.state.isFollowing(topic: "Health"))
        #expect(a.summary == "2 members, 1 bill, 0 topics")
    }

    @Test func clearingTheDistrictTravelsToo() {
        let cloud = InMemoryCloudStore()
        let delegation = Delegation(district: District(congress: 119, state: "NY", district: 8, countyFips: nil), members: [jeffries], resolvedAt: at(0))
        let storeA = Delegations(delegation)
        let storeB = Delegations(delegation)
        let a = CloudSync(follows: Follows(store: InMemoryFollowStore()), delegations: storeA, cloud: cloud, defaults: defaults(), now: { at(10) })
        let b = CloudSync(follows: Follows(store: InMemoryFollowStore()), delegations: storeB, cloud: cloud, defaults: defaults(), now: { at(20) })
        a.setEnabled(true)
        b.setEnabled(true)
        storeA.clear()
        a.delegationChanged()
        b.pull()
        #expect(storeB.stored == nil, "Change address on one phone is not undone by the other")
    }
}
