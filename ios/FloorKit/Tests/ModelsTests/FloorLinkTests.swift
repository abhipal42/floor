import Foundation
import Testing
@testable import Models

@Suite("FloorLink")
struct FloorLinkTests {
    @Test func aVoteLinkRoundTrips() throws {
        let link = FloorLink.vote(id: "house-119-2-321")
        #expect(link.url.absoluteString == "floor://vote/house-119-2-321")
        #expect(FloorLink(url: link.url) == link)
        #expect(FloorLink(url: FloorLink.vote(id: "senate-119-2-258").url) == .vote(id: "senate-119-2-258"))
    }

    @Test func theOpenLinkRoundTrips() {
        #expect(FloorLink.open.url.absoluteString == "floor://open")
        #expect(FloorLink(url: FloorLink.open.url) == .open)
    }

    /// Any app can open a floor:// URL, so only the roll call id shape gets through.
    @Test func onlyRollCallIdsAreAccepted() throws {
        for string in [
            "floor://vote/house-119-2-321%2F..", "floor://vote/..%2Fstatus", "floor://vote/house-119-2",
            "floor://vote/house-119-2-321-1", "floor://vote/Senate-119-2-258", "floor://vote/house-119-2-x",
            "floor://vote/house-%D9%A1%D9%A1%D9%A9-2-321", // Arabic-Indic digits
            "floor://vote/house-119-2-321%20", "floor://vote/joint-119-2-1", "floor://vote/house--2-321",
        ] {
            #expect(FloorLink(url: try #require(URL(string: string))) == nil, "\(string)")
        }
        #expect(!FloorLink.isVoteId("house-١١٩-2-321"))
        #expect(FloorLink.isVoteId("house-119-2-321"))
        // An invalid id never builds a link that opens a vote.
        #expect(FloorLink(url: FloorLink.vote(id: "../status").url) == nil)
    }

    @Test func rejectsLinksThatAreNotOurs() throws {
        for string in [
            "https://floor.app/vote/house-119-2-321", "floor://vote", "floor://vote/", "floor://bill/119-hr-1013",
            "floor://vote/a/b", "floor://vote/house-119-2-321/", "floor://vote//house-119-2-321",
        ] {
            #expect(FloorLink(url: try #require(URL(string: string))) == nil, "\(string)")
        }
    }

    @Test func theSchemeIsCaseInsensitive() throws {
        #expect(FloorLink(url: try #require(URL(string: "FLOOR://vote/house-119-2-321"))) == .vote(id: "house-119-2-321"))
    }
}
