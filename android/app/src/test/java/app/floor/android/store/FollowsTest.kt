package app.floor.android.store

import app.floor.android.Fixtures
import app.floor.android.api.FloorApi
import app.floor.android.model.Bill
import app.floor.android.model.Chamber
import app.floor.android.model.Delegation
import app.floor.android.model.Member
import app.floor.android.model.SearchResults
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/** What you follow, kept on the phone (iOS `FollowsTests`, less alerts and the iCloud merge). */
class FollowsTest {
    private val austin = Fixtures.decode("reps-location-austin", Delegation.serializer())
    private val cruz get() = austin.members.first { it.lastName == "Cruz" }
    private val jeffries = Member("J000294", "Hakeem", "Jeffries", "D", "NY", 8, Chamber.HOUSE)
    private val schumer = Member("S000148", "Charles", "Schumer", "D", "NY", null, Chamber.SENATE)

    @Test
    fun followingAddsToTheFrontAndUnfollowingRemoves() {
        var state = FollowState()
        state = state.follow(FollowKind.MEMBER, jeffries.bioguideId, member = jeffries, at = 1)
        state = state.follow(FollowKind.MEMBER, schumer.bioguideId, member = schumer, at = 2)
        state = state.follow(FollowKind.TOPIC, "Health")
        assertEquals(listOf("Schumer", "Jeffries"), state.followedMembers.map { it.lastName })
        // Following again keeps its place.
        state = state.follow(FollowKind.MEMBER, jeffries.bioguideId, member = jeffries)
        assertEquals(listOf("Schumer", "Jeffries"), state.followedMembers.map { it.lastName })
        state = state.move(FollowKind.MEMBER, jeffries.bioguideId, -1)
        assertEquals(listOf("Jeffries", "Schumer"), state.followedMembers.map { it.lastName })
        assertEquals(listOf("Health"), state.followedTopics)
        state = state.unfollow(FollowKind.MEMBER, schumer.bioguideId)
        assertFalse(state.isFollowing(schumer.bioguideId))
        assertTrue(state.isFollowingTopic("Health"))
    }

    @Test
    fun aRepIsARepNeverAlsoAFollowedMember() {
        var state = FollowState().follow(FollowKind.MEMBER, cruz.bioguideId, member = cruz).follow(FollowKind.MEMBER, jeffries.bioguideId, member = jeffries)
        assertEquals(listOf("Doggett", "Cornyn", "Cruz", "Jeffries"), state.yourMembers(austin.members).map { it.lastName })
        assertEquals(listOf("Jeffries"), state.followed(austin.members).map { it.lastName })
        state = state.setHidden(cruz.bioguideId, true)
        // Hidden wins, even over the old follow entry.
        assertEquals(listOf("Doggett", "Cornyn", "Jeffries"), state.yourMembers(austin.members).map { it.lastName })
        state = state.adoptReps(austin.memberIds)
        assertFalse(state.isFollowing(cruz.bioguideId))
        assertEquals(emptyList<String>(), state.forgetReps(austin.memberIds).hiddenReps)
    }

    @Test
    fun followsSurviveTheTripThroughStorageAndAnUnreadableEntryIsDroppedAlone() {
        val bill = Fixtures.decode("search-hr1013", SearchResults.serializer()).bills.first()
        val state = FollowState().follow(FollowKind.BILL, bill.id, bill = bill).follow(FollowKind.MEMBER, jeffries.bioguideId, member = jeffries)
        val json = FloorApi.json.encodeToString(FollowState.serializer(), state)
        assertEquals(state, FloorApi.json.decodeFromString(FollowState.serializer(), json))
        val damaged = """{"entries":[{"kind":"party","id":"x"},{"kind":"topic","id":"Health","followedAt":3}],"hiddenReps":[]}"""
        assertEquals(listOf("Health"), FloorApi.json.decodeFromString(FollowState.serializer(), damaged).followedTopics)
    }

    @Test
    fun aFollowedBillsRowFollowsItsRecord() {
        val record = Fixtures.decode("bill-hr1013", Bill.serializer())
        val row = listItem(record, today = LocalDate.of(2026, 11, 16))
        assertEquals("H.R. 1013", row.citation)
        assertTrue(row.hasFloorVote)
        val follows = Follows(InMemoryFollowStore())
        follows.refresh(record)
        assertTrue(follows.state.entries.isEmpty()) // no follow by side effect
        follows.toggle(row)
        follows.refresh(record)
        assertEquals(record.id, follows.state.followedBills.single().id)
        follows.toggle(row)
        assertTrue(follows.state.followedBills.isEmpty())
    }

    @Test
    fun theSessionKeepsTheDistrictAndForgetsTheOldOne() {
        val store = InMemoryDelegationStore()
        val session = Session(store, InMemoryFollowStore())
        assertTrue(session.onboarding)
        session.skip()
        assertFalse(session.onboarding)
        assertTrue(store.skipped())
        session.follows.toggle(cruz)
        session.findReps()
        assertTrue(session.changingAddress)
        session.finish(austin)
        assertEquals(austin, store.load())
        // Cruz turned out to be a rep: pinned, not followed.
        assertFalse(session.follows.state.isFollowing(cruz.bioguideId))
        assertEquals(3, session.yourMembers.size)
        assertNull(InMemoryDelegationStore().load())
    }
}
