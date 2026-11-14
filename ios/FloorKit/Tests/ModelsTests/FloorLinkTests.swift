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
            "https://floor.app/vote/house-119-2-321", "floor://vote", "floor://vote/", "floor://bill/119-pn-1013",
            "floor://vote/a/b", "floor://vote/house-119-2-321/", "floor://vote//house-119-2-321",
        ] {
            #expect(FloorLink(url: try #require(URL(string: string))) == nil, "\(string)")
        }
    }

    @Test func aBillLinkRoundTrips() throws {
        let link = FloorLink.bill(id: "119-hr-1013")
        #expect(link.url.absoluteString == "floor://bill/119-hr-1013")
        #expect(FloorLink(url: link.url) == link)
        #expect(FloorLink(url: FloorLink.bill(id: "119-sconres-7").url) == .bill(id: "119-sconres-7"))
    }

    /// The share page's link opens the bill screen when iOS hands it to the app.
    @Test func theShareLinkOpensTheBill() throws {
        #expect(FloorLink(url: try #require(URL(string: "https://floor.app/bill/119/hr/5267"))) == .bill(id: "119-hr-5267"))
        #expect(FloorLink(url: try #require(URL(string: "https://www.floor.app/bill/119/s/2"))) == .bill(id: "119-s-2"))
        for string in [
            "https://floor.app/bill/119/hr/5267/card.png", "https://floor.app/bill/119/HR/5267", "https://floor.app/bill/119/hr",
            "https://evil.example/bill/119/hr/5267", "http://floor.app/bill/119/hr/5267", "https://floor.app/bill/119/hr/05267",
            "https://floor.app/bill/119/hr/5267%2F..", "floor://bill/119-hr-", "floor://bill/1-hr-1", "floor://bill/119-hr-1/x",
        ] {
            #expect(FloorLink(url: try #require(URL(string: string))) == nil, "\(string)")
        }
        #expect(FloorLink(url: FloorLink.bill(id: "../status").url) == nil)
    }

    @Test func theSchemeIsCaseInsensitive() throws {
        #expect(FloorLink(url: try #require(URL(string: "FLOOR://vote/house-119-2-321"))) == .vote(id: "house-119-2-321"))
    }
}
