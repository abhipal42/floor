import Foundation
import Testing
@testable import Models

/// `Fixtures/live.json` is the real API code (`GET /v1/live?since=120`) answering from a database the
/// real live worker filled from the House floor summary of 2026-11-10 and the real roll 319 XML, with
/// the clock set to that evening: staging cannot answer it until the M3 migration is applied.
@Suite("Live")
struct LiveTests {
    @Test func decodesTheLiveViewWithBothChambersAndEachVoteState() throws {
        let live = try fixture("live", as: Live.self)
        #expect(live.chambers.map(\.chamber) == [.house, .senate])
        #expect(live.chambers.first?.inSession == true)
        #expect(live.chambers.last?.convenesAt == "2026-11-16T20:00:00.000Z")
        #expect(live.votes.map(\.id) == ["house-119-2-319", "house-119-2-318", "house-119-2-317"])
        #expect(live.openVotes.map(\.id) == ["house-119-2-318", "house-119-2-317"])
    }

    @Test func aFinalVoteCarriesWhenItOpenedAndWhenItsXMLWasSeen() throws {
        let final = try #require(try fixture("live", as: Live.self).votes.first)
        // The vote's own fields decode from the same flat object as the timestamps beside them.
        #expect(final.vote.state == .final)
        #expect(final.vote.totals.yea == 215)
        #expect(final.openedAt == "2026-11-10T23:20:53.000Z")
        #expect(final.postedAt == "2026-11-10T23:33:10.000Z")
        let opened = try #require(final.openedAt.flatMap(Formats.instant))
        let posted = try #require(final.postedAt.flatMap(Formats.instant))
        #expect(posted.timeIntervalSince(opened) == 737)
    }

    @Test func anOpenVoteHasNoPostingTimeYet() throws {
        let open = try #require(try fixture("live", as: Live.self).openVotes.first)
        #expect(open.vote.result == "Agreed to")
        #expect(open.postedAt == nil)
        #expect(open.announcedAt != nil)
    }

    @Test func roundTripsFlat() throws {
        let data = try JSONEncoder().encode(LiveVote.sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == "house-119-2-319")
        #expect(object.keys.contains("postedAt"))
        #expect(try JSONDecoder().decode(LiveVote.self, from: data) == .sample)
    }
}
