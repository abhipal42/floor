import Foundation
import Models
@testable import Onboarding
import Testing

private let jeffries = Member(bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D",
                              state: "NY", district: 8, chamber: .house)
private let schumer = Member(bioguideId: "S000148", firstName: "Charles", lastName: "Schumer", party: "D",
                             state: "NY", district: nil, chamber: .senate)
private let hageman = Member(bioguideId: "H001096", firstName: "Harriet", lastName: "Hageman", party: "R",
                             state: "WY", district: 0, chamber: .house)
private let norton = Member(bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D",
                            state: "DC", district: 0, chamber: .house)

private func names(_ state: FollowState) -> [String] { state.followedMembers.map(\.lastName) }

@Suite("Follow list")
struct FollowStateTests {
    @Test func newestFirst() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(member: schumer)
        state.follow(member: hageman)
        #expect(names(state) == ["Hageman", "Schumer", "Jeffries"])
    }

    /// Following twice is one entry where it already was, with the newer record.
    @Test func followingAgainKeepsThePlaceAndRefreshesTheRecord() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(member: schumer)
        var moved = jeffries
        moved.party = "I"
        state.follow(member: moved)
        #expect(names(state) == ["Schumer", "Jeffries"])
        #expect(state.followedMembers.last?.party == "I")
    }

    @Test func unfollowRemovesTheEntryAndItsAlertChoice() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.setAlerts(member: jeffries.bioguideId, true)
        state.unfollow(member: jeffries.bioguideId)
        #expect(state.followedMembers.isEmpty)
        #expect(!state.isFollowing(member: jeffries.bioguideId))
        #expect(state.alerts.isEmpty)
    }

    /// `List.onMove`'s arguments: the destination is the index before the move.
    @Test func reordersAsListMovesDo() {
        var state = FollowState()
        for member in [hageman, schumer, jeffries] { state.follow(member: member) } // Jeffries, Schumer, Hageman
        state.moveMembers(fromOffsets: [0], toOffset: 3)
        #expect(names(state) == ["Schumer", "Hageman", "Jeffries"])
        state.moveMembers(fromOffsets: [2], toOffset: 0)
        #expect(names(state) == ["Jeffries", "Schumer", "Hageman"])
        state.moveMembers(fromOffsets: [1], toOffset: 1) // dropped where it was
        #expect(names(state) == ["Jeffries", "Schumer", "Hageman"])
        state.moveMembers(fromOffsets: [0, 1], toOffset: 3)
        #expect(names(state) == ["Hageman", "Jeffries", "Schumer"])
    }

    /// The store is generic: a bill or a topic is an entry too, and reordering members leaves
    /// them where they were.
    @Test func otherKindsKeepTheirPlacesWhenMembersMove() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(.bill, "119-hr-1")
        state.follow(member: schumer)
        state.follow(.topic, "Taxation")
        #expect(state.entries.map(\.key) == ["topic:Taxation", "member:S000148", "bill:119-hr-1", "member:J000294"])
        state.moveMembers(fromOffsets: [0], toOffset: 2)
        #expect(state.entries.map(\.key) == ["topic:Taxation", "member:J000294", "bill:119-hr-1", "member:S000148"])
        #expect(state.contains(.bill, "119-hr-1"))
        #expect(!state.contains(.member, "119-hr-1"))
        #expect(names(state) == ["Jeffries", "Schumer"])
    }

    @Test func yourMembersAreVisibleRepsThenFollowedWithoutRepeats() {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(member: .sampleSenator) // one of your reps, followed as well
        state.setHidden(rep: Member.sample.bioguideId, true)
        let reps = [Member.sample, .sampleSenator]
        #expect(state.yourMembers(reps: reps).map(\.lastName) == ["Cruz", "Jeffries"])
        state.setHidden(rep: Member.sample.bioguideId, false)
        #expect(state.yourMembers(reps: reps).map(\.lastName) == ["Adams", "Cruz", "Jeffries"])
        #expect(FollowState().yourMembers(reps: []).isEmpty)
    }

    @Test func aDelegateDistrictWorksLikeAnyOther() {
        var state = FollowState()
        state.follow(member: schumer)
        #expect(state.yourMembers(reps: [norton]).map(\.lastName) == ["Norton", "Schumer"])
        state.setHidden(rep: norton.bioguideId, true)
        #expect(state.yourMembers(reps: [norton]).map(\.lastName) == ["Schumer"])
    }

    /// The defaults the push work will read: on for your reps, off for members you follow.
    @Test func alertsDefaultOnForRepsAndOffForFollowed() {
        var state = FollowState()
        #expect(state.alertsOn(member: "D000399", isRep: true))
        #expect(!state.alertsOn(member: jeffries.bioguideId, isRep: false))
        state.setAlerts(member: jeffries.bioguideId, true)
        state.setAlerts(member: "D000399", false)
        #expect(state.alertsOn(member: jeffries.bioguideId, isRep: false))
        #expect(!state.alertsOn(member: "D000399", isRep: true))
    }

    /// "Change address" forgets what named the old district, and nothing you chose yourself.
    @Test func forgettingRepsKeepsWhoYouFollow() {
        var state = FollowState()
        state.follow(member: .sampleSenator)
        state.follow(member: jeffries)
        state.setHidden(rep: Member.sample.bioguideId, true)
        state.setAlerts(member: Member.sample.bioguideId, false)
        state.setAlerts(member: Member.sampleSenator.bioguideId, false)
        state.forgetReps([Member.sample.bioguideId, Member.sampleSenator.bioguideId])
        #expect(state.hiddenReps.isEmpty)
        #expect(state.alerts == [Member.sampleSenator.bioguideId: false]) // followed: still yours
        #expect(names(state) == ["Jeffries", "Cruz"])
    }

    @Test func decodingDropsDuplicatesAndToleratesMissingFields() throws {
        let entry = #"{"kind":"member","id":"J000294","followedAt":0,"member":{"bioguideId":"J000294","firstName":"Hakeem","lastName":"Jeffries","party":"D","state":"NY","district":8,"chamber":"house"}}"#
        let json = #"{"entries":[\#(entry),\#(entry)],"hiddenReps":["A","A"]}"#
        let state = try JSONDecoder().decode(FollowState.self, from: Data(json.utf8))
        #expect(names(state) == ["Jeffries"])
        #expect(state.hiddenReps == ["A"])
        #expect(state.alerts.isEmpty)
        #expect(try JSONDecoder().decode(FollowState.self, from: Data("{}".utf8)) == .empty)
    }

    /// An entry from a later build with no record (a bill-only build's member stub, a bad write)
    /// is kept but not shown, because it cannot be named.
    @Test func aMemberWithoutARecordIsNotShown() {
        let state = FollowState(entries: [FollowEntry(kind: .member, id: "X000001", followedAt: Date())])
        #expect(state.isFollowing(member: "X000001"))
        #expect(state.followedMembers.isEmpty)
    }
}

@Suite("Follow store")
struct FollowStoreTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "floor.tests.\(UUID())"))
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try suite()
        let store = UserDefaultsFollowStore(defaults: defaults)
        #expect(store.load() == .empty)
        var state = FollowState()
        state.follow(member: jeffries)
        state.setHidden(rep: "D000399", true)
        store.save(state)
        #expect(UserDefaultsFollowStore(defaults: defaults).load() == state)
    }

    @Test func anUnreadableRecordReadsAsFollowingNobody() throws {
        let defaults = try suite()
        defaults.set(Data("not json".utf8), forKey: UserDefaultsFollowStore.key)
        #expect(UserDefaultsFollowStore(defaults: defaults).load() == .empty)
    }

    /// Without the App Group (an unentitled build, `swift test`) following still works, in the
    /// app's own defaults; with it, the group is where it goes so the widget can read it.
    @Test func usesTheGroupWhenThereIsOneElseTheAppsDefaults() throws {
        let group = try suite()
        let fallback = try suite()
        var state = FollowState()
        state.follow(member: jeffries)

        UserDefaultsFollowStore.shared(group: group, fallback: fallback).save(state)
        #expect(group.data(forKey: UserDefaultsFollowStore.key) != nil)
        #expect(fallback.data(forKey: UserDefaultsFollowStore.key) == nil)

        UserDefaultsFollowStore.shared(group: nil, fallback: fallback).save(state)
        #expect(UserDefaultsFollowStore(defaults: fallback).load() == state)
    }

    /// Following keeps who you follow and which reps you hid — never where you are.
    @Test func theSavedRecordHoldsNoAddressOrCoordinate() throws {
        var state = FollowState()
        state.follow(member: jeffries)
        state.follow(member: norton)
        state.setHidden(rep: "D000399", true)
        state.setAlerts(member: jeffries.bioguideId, true)
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self).lowercased()
        for word in ["address", "latitude", "longitude", "\"lat\"", "\"lng\"", "coordinate", "countyfips", "street"] {
            #expect(!json.contains(word), "\(word)")
        }
    }

    @MainActor
    @Test func theModelSavesEachChangeAndSaysSo() throws {
        let store = InMemoryFollowStore()
        var changes = 0
        let follows = Follows(store: store) { changes += 1 }
        follows.toggle(jeffries)
        #expect(follows.isFollowing(jeffries))
        #expect(store.load().isFollowing(member: jeffries.bioguideId))
        follows.update { $0.follow(member: jeffries) } // no change: nothing saved, nothing said
        #expect(changes == 1)
        follows.toggle(jeffries)
        #expect(!follows.isFollowing(jeffries))
        #expect(changes == 2)
        // A new model reads what was saved.
        follows.toggle(schumer)
        #expect(Follows(store: store).isFollowing(schumer))
    }
}

@Suite("Follow list: reps you also followed")
struct FollowRepsTests {
    private let doggett = Member(bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D",
                                 state: "TX", district: 37, chamber: .house)
    private let cruz = Member(bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R",
                              state: "TX", district: nil, chamber: .senate)

    /// Skip the district, follow Cruz and Jeffries, then find TX-37: Cruz is a rep now, listed once,
    /// pinned; Jeffries stays followed.
    @MainActor
    @Test func skipThenFollowThenFindRepsListsTheRepOnce() {
        let follows = Follows(store: InMemoryFollowStore())
        follows.toggle(cruz)
        follows.toggle(jeffries)
        let texas = Delegation(district: District(congress: 119, state: "TX", district: 37, countyFips: nil),
                               members: [doggett, cruz])
        follows.adopt(texas)
        #expect(follows.state.followedMembers.map(\.lastName) == ["Jeffries"])
        #expect(follows.state.yourMembers(reps: texas.members).map(\.lastName) == ["Doggett", "Cruz", "Jeffries"])
        // And hiding Cruz now hides him everywhere.
        follows.update { $0.setHidden(rep: cruz.bioguideId, true) }
        #expect(follows.state.yourMembers(reps: texas.members).map(\.lastName) == ["Doggett", "Jeffries"])
    }

    /// The same rule without `adopt` (a record written before it existed): hidden wins, and the
    /// Following group leaves the rep out.
    @Test func hiddenWinsOverAFollowEntryForARep() {
        var state = FollowState()
        state.follow(member: cruz)
        state.follow(member: jeffries)
        state.setHidden(rep: cruz.bioguideId, true)
        #expect(state.yourMembers(reps: [doggett, cruz]).map(\.lastName) == ["Doggett", "Jeffries"])
        #expect(state.followed(excludingReps: [doggett, cruz]).map(\.lastName) == ["Jeffries"])
    }

    /// Reordering the shown list leaves an unshown entry (a rep's) where it was.
    @Test func reordersAmongTheShownOnly() {
        var state = FollowState()
        for member in [hageman, cruz, schumer, jeffries] { state.follow(member: member) } // J, S, C, H
        let shown = state.followed(excludingReps: [cruz]).map(\.bioguideId) // J, S, H
        state.moveMembers(shown, fromOffsets: [2], toOffset: 0)
        #expect(state.followedMembers.map(\.lastName) == ["Hageman", "Jeffries", "Cruz", "Schumer"])
    }
}

@Suite("Follow store: moving into the App Group")
struct FollowMigrationTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "floor.tests.\(UUID())"))
    }

    /// The delegation store's rules: an empty group takes the app's copy, a group record wins, the
    /// legacy copy survives loading and goes on the next save.
    @Test func copiesIntoAnEmptyGroupKeepsTheLegacyCopyUntilASave() throws {
        let legacy = try suite()
        let group = try suite()
        var old = FollowState()
        old.follow(member: jeffries)
        UserDefaultsFollowStore(defaults: legacy).save(old)

        let store = UserDefaultsFollowStore.shared(group: group, fallback: legacy)
        #expect(store.load() == old)
        #expect(legacy.data(forKey: UserDefaultsFollowStore.key) != nil) // loading deletes nothing
        _ = UserDefaultsFollowStore.shared(group: group, fallback: legacy).load()
        #expect(legacy.data(forKey: UserDefaultsFollowStore.key) != nil)

        var newer = old
        newer.follow(member: schumer)
        store.save(newer)
        #expect(legacy.data(forKey: UserDefaultsFollowStore.key) == nil)
        #expect(UserDefaultsFollowStore(defaults: group).load() == newer)
    }

    @Test func aGroupRecordWinsOverTheLegacyOne() throws {
        let legacy = try suite()
        let group = try suite()
        var inGroup = FollowState()
        inGroup.follow(member: schumer)
        UserDefaultsFollowStore(defaults: group).save(inGroup)
        var inLegacy = FollowState()
        inLegacy.follow(member: jeffries)
        UserDefaultsFollowStore(defaults: legacy).save(inLegacy)
        #expect(!UserDefaultsFollowStore.migrate(from: legacy, to: group))
        #expect(UserDefaultsFollowStore.shared(group: group, fallback: legacy).load() == inGroup)
    }
}
