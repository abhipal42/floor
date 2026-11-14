import Foundation
import Models
@testable import Onboarding
import Testing

private let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D",
                              state: "NY", district: 8, chamber: .house)

/// Round 10: bills and topics in the same record as members, with no migration.
@Suite("Following bills and topics")
struct FollowBillsTopicsStateTests {
    @Test func billsAndTopicsAreKeptBesideMembersInTheirOwnOrder() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(bill: .sample)
        state.follow(topic: "Health")
        state.follow(bill: .sampleDisapproval)
        state.follow(topic: "Taxation")
        #expect(state.followedBills.map(\.id) == ["119-sjres-197", "119-hr-2493"])
        #expect(state.followedBillIds == ["119-sjres-197", "119-hr-2493"])
        #expect(state.followedTopics == ["Taxation", "Health"])
        #expect(state.followedMembers == [jeffries])
        state.unfollow(bill: "119-hr-2493")
        state.unfollow(topic: "Health")
        #expect(state.followedBillIds == ["119-sjres-197"])
        #expect(state.followedTopics == ["Taxation"])
        #expect(state.isFollowing(member: jeffries.bioguideId))
    }

    /// A fresher row replaces the saved one where it is; a bill you don't follow is not followed by it.
    @Test func refreshingABillUpdatesOnlyAFollowedOne() {
        var state = FollowState()
        state.follow(bill: .sample)
        var moved = BillListItem.sample
        moved.stage = .passedBoth
        state.refresh(bill: moved)
        #expect(state.followedBills.first?.stage == .passedBoth)
        state.refresh(bill: .sampleDisapproval)
        #expect(!state.isFollowing(bill: "119-sjres-197"))
        // Following again refreshes too, and keeps the place.
        state.follow(bill: .sampleDisapproval)
        state.follow(bill: .sample)
        #expect(state.followedBillIds == ["119-sjres-197", "119-hr-2493"])
        #expect(state.followedBills.last?.stage == .passedHouse)
    }

    /// A v0.2.28 record (no `bill` on its entries) opens unchanged; a bill entry with no saved row
    /// keeps its id for the feed and is left out of the named list.
    @Test func olderRecordsOpen() throws {
        let old = #"{"entries":[{"kind":"member","id":"J000294","followedAt":0,"member":{"bioguideId":"J000294","firstName":"Hakeem","lastName":"Jeffries","party":"D","state":"NY","district":8,"chamber":"house"}},{"kind":"bill","id":"119-hr-1013","followedAt":0},{"kind":"topic","id":"Health","followedAt":0}],"hiddenReps":[],"alerts":{}}"#
        let state = try JSONDecoder().decode(FollowState.self, from: Data(old.utf8))
        #expect(state.followedMembers.map(\.lastName) == ["Jeffries"])
        #expect(state.followedBillIds == ["119-hr-1013"])
        #expect(state.followedBills.isEmpty)
        #expect(state.followedTopics == ["Health"])
    }

    /// One unreadable blob loses only what it must: a saved bill or member row this build can't read
    /// is dropped and its entry kept (the next fetch refills it); an entry of a kind it doesn't know
    /// is dropped alone. The record never reads as following nobody because of one.
    @Test func oneBadBlobDoesNotWipeTheFollows() throws {
        let record = #"""
        {"entries":[
          {"kind":"member","id":"J000294","followedAt":0,"member":{"bioguideId":"J000294","firstName":"Hakeem","lastName":"Jeffries","party":"D","state":"NY","district":8,"chamber":"house"}},
          {"kind":"member","id":"C001098","followedAt":0,"member":{"bioguideId":"C001098","chamber":"senate"}},
          {"kind":"bill","id":"119-hr-1013","followedAt":0,"bill":{"id":"119-hr-1013","citation":42}},
          {"kind":"committee","id":"HSWM","followedAt":0},
          {"kind":"bill","followedAt":0},
          {"kind":"topic","id":"Health","followedAt":"not a date"}
        ],"hiddenReps":["S000148"],"alerts":{"J000294":"yes"}}
        """#
        let state = try JSONDecoder().decode(FollowState.self, from: Data(record.utf8))
        #expect(state.followedMembers.map(\.lastName) == ["Jeffries"])
        #expect(state.isFollowing(member: "C001098")) // kept, unnamed until its record is fetched
        #expect(state.followedBillIds == ["119-hr-1013"])
        #expect(state.followedBills.isEmpty)
        #expect(state.followedTopics == ["Health"])
        #expect(state.entries.count == 4)
        #expect(state.hiddenReps == ["S000148"])
        #expect(state.alerts.isEmpty)
        // And through the store, which used to fall back to `.empty` on any failure.
        let defaults = try #require(UserDefaults(suiteName: "follows-lossy-\(UUID())"))
        defaults.set(Data(record.utf8), forKey: "floor.follows.v1")
        #expect(UserDefaultsFollowStore(defaults: defaults).load().entries.count == 4)
    }

    /// The bill screen's fresh record refreshes a followed bill's saved row, keeping a stage the
    /// record lacks; a bill you don't follow is left alone.
    @MainActor
    @Test func aFreshRecordRefreshesTheSavedRow() {
        var state = FollowState()
        state.follow(bill: .sample)
        let follows = Follows(store: InMemoryFollowStore(state))
        var record = Bill.sample
        record.id = BillListItem.sample.id
        record.latestAction = LatestAction(on: "2026-11-13", text: "Placed on Senate Legislative Calendar under General Orders.")
        record.stage = nil
        follows.refresh(record: record)
        let row = follows.state.followedBills.first
        #expect(row?.latestAction?.on == "2026-11-13")
        #expect(row?.stage == BillListItem.sample.stage)
        var other = record
        other.id = "119-hr-9"
        follows.refresh(record: other)
        #expect(!follows.isFollowing(bill: "119-hr-9"))
    }

    @Test func roundTripsWithItsBillRows() throws {
        var state = FollowState()
        state.follow(bill: .sampleDisapproval)
        state.follow(topic: "Arts, Culture, Religion")
        let store = UserDefaultsFollowStore(defaults: try #require(UserDefaults(suiteName: "follows-bills-\(UUID())")))
        store.save(state)
        #expect(store.load() == state)
        #expect(store.load().followedBills.first?.label == BillListItem.sampleDisapproval.label)
    }

    @MainActor
    @Test func togglesSaveAndSaySo() {
        let store = InMemoryFollowStore()
        var changes = 0
        let follows = Follows(store: store) { changes += 1 }
        follows.toggle(bill: .sample)
        follows.toggle(topic: "Health")
        #expect(store.load().isFollowing(bill: "119-hr-2493"))
        #expect(store.load().isFollowing(topic: "Health"))
        follows.toggle(bill: .sample)
        #expect(!follows.isFollowing(bill: "119-hr-2493"))
        #expect(changes == 3)
    }
}
