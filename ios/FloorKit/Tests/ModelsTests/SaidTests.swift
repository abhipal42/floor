import Foundation
import Testing
@testable import Models

/// Round 13: campaign promises, official accounts and posts, from the hand-built fixtures (real
/// content: Slotkin's and Gillibrand's archived 2024 sites, Schumer's accounts and posts).
@Suite("Said, accounts and posts")
struct SaidTests {
    @Test func slotkinsDeckIsHerSitesOwnWords() throws {
        let said = try fixture("promises-slotkin", as: MemberPromises.self)
        #expect(said.status == .promises)
        #expect(said.electionYear == 2024)
        #expect(said.snapshotUrl == "https://web.archive.org/web/20241012144326/https://elissaslotkin.org/priorities/")
        #expect(said.snapshotDate == Date(timeIntervalSince1970: 1_728_744_206)) // 2024-10-12T14:43:26Z
        #expect(said.promises.map(\.heading) == [
            "Making Things in America", "Defending and Expanding Michigan’s Middle Class", "Keeping our Communities and Kids Safe",
        ])
        #expect(said.promises.map(\.topic) == ["Commerce", "Health", "Crime and Law Enforcement"])
        // Every headline is a clause of its own quote.
        for promise in said.promises {
            #expect(!promise.headline.isEmpty)
            #expect(CampaignPromise.isFragment(promise.headline, of: promise.quote))
        }
    }

    @Test func gillibrandListedNoIssues() throws {
        let said = try fixture("promises-gillibrand", as: MemberPromises.self)
        #expect(said.status == .noPlatform)
        #expect(said.promises.isEmpty)
        #expect(said.snapshotAt == "2024-10-16T04:37:37Z")
    }

    /// A headline that is not the quote's own words is dropped, never shown; an unknown topic is no topic.
    @Test func aRewrittenHeadlineIsDropped() throws {
        let json = #"{"heading":"H","quote":"We will build more homes, faster.","headline":"Build homes fast","topic":"Housing"}"#
        let promise = try JSONDecoder().decode(CampaignPromise.self, from: Data(json.utf8))
        #expect(promise.headline == "")
        #expect(promise.topic == nil)
        let kept = #"{"quote":"We will build more homes, faster.","headline":"build   more Homes","topic":"housing and community development"}"#
        let read = try JSONDecoder().decode(CampaignPromise.self, from: Data(kept.utf8))
        #expect(read.headline == "build   more Homes")
        #expect(read.topic == "Housing and Community Development")
    }

    /// Unknown statuses and broken promises never fail the segment.
    @Test func lenientWhereTheShapeMoves() throws {
        let odd = #"{"status":"failed","promises":[{"quote":""},{"heading":1}]}"#
        let read = try JSONDecoder().decode(MemberPromises.self, from: Data(odd.utf8))
        #expect(read.status == .unchecked)
        #expect(read.promises.isEmpty)
        // "promises" with none to show is no platform; with no archived copy to cite, no snapshot.
        let empty = #"{"status":"promises","snapshotUrl":"https://web.archive.org/x","promises":[]}"#
        #expect(try JSONDecoder().decode(MemberPromises.self, from: Data(empty.utf8)).status == .noPlatform)
        let uncited = #"{"status":"promises","promises":[{"quote":"Q","headline":"Q"}]}"#
        let noCopy = try JSONDecoder().decode(MemberPromises.self, from: Data(uncited.utf8))
        #expect(noCopy.status == .noSnapshot)
        #expect(noCopy.promises.isEmpty)
    }

    @Test func schumersAccountsBecomeLinks() throws {
        let detail = try fixture("member-detail-schumer", as: MemberDetail.self)
        let social = try #require(detail.member.social)
        let links = social.links
        #expect(links.map(\.network) == [.x, .facebook, .instagram, .youtube, .bluesky])
        #expect(links.map(\.url?.absoluteString) == [
            "https://x.com/SenSchumer", "https://www.facebook.com/senschumer", "https://www.instagram.com/senschumer",
            "https://www.youtube.com/channel/UC-ABttxh8uQv_10qmwGaidw", "https://bsky.app/profile/schumer.senate.gov",
        ])
        #expect(links.first?.displayHandle == "@SenSchumer")
        #expect(links[3].displayHandle == "SenatorSchumer")
    }

    /// 63 members have only a channel id: the link is built from it.
    @Test func aChannelIdAloneLinksTheChannel() throws {
        let json = #"{"youtubeId":"UC123"}"#
        let links = try JSONDecoder().decode(MemberSocial.self, from: Data(json.utf8)).links
        #expect(links.map(\.url?.absoluteString) == ["https://www.youtube.com/channel/UC123"])
    }

    /// The posts route sends full URLs; X still reads as a handle.
    @Test func postLinksAreFullURLs() {
        let link = SocialLink(network: .x, handle: "https://x.com/SenSchumer")
        #expect(link.url?.absoluteString == "https://x.com/SenSchumer")
        #expect(link.displayHandle == "@SenSchumer")
    }

    @Test func mastodonHandlesPointAtTheirInstance() {
        let link = SocialLink(network: .mastodon, handle: "@RepExample@mastodon.social")
        #expect(link.url?.absoluteString == "https://mastodon.social/@RepExample")
        #expect(SocialLink(network: .mastodon, handle: "nope").url == nil)
    }

    /// Lists and older responses have no `social`; a broken or blank one is none.
    @Test func socialIsOptionalAndLenient() throws {
        #expect(try fixture("member-detail-nadler", as: MemberDetail.self).member.social == nil)
        let broken = #"{"bioguideId":"X","firstName":"A","lastName":"B","party":"D","state":"NY","chamber":"senate","social":"@x"}"#
        #expect(try JSONDecoder().decode(Member.self, from: Data(broken.utf8)).social == nil)
        let blank = #"{"bioguideId":"X","firstName":"A","lastName":"B","party":"D","state":"NY","chamber":"senate","social":{"twitter":" "}}"#
        #expect(try JSONDecoder().decode(Member.self, from: Data(blank.utf8)).social == nil)
    }

    @Test func schumersPostsAreNewestFirstWithNoCounts() throws {
        let posts = try fixture("posts-schumer", as: MemberPosts.self)
        #expect(posts.posts.map(\.network) == [.bluesky, .youtube, .youtube])
        #expect(posts.posts.first?.text?.hasPrefix("Grocery prices are higher than ever.") == true)
        #expect(posts.posts.map(\.postedAt) == [
            "2026-11-16T22:01:00.000Z", "2026-11-16T20:04:48.000Z", "2026-11-10T17:24:47.000Z",
        ])
        #expect(posts.links?.links.map(\.url?.absoluteString) == [
            "https://x.com/SenSchumer", "https://www.facebook.com/senschumer", "https://www.instagram.com/senschumer",
        ])
    }

    /// Out of order on the wire is newest first on the phone; an unreadable post is dropped.
    @Test func postsAreSortedAndBadOnesDropped() throws {
        let json = #"{"posts":[{"id":"a","network":"youtube","postedAt":"2026-11-01T00:00:00Z","url":"https://y.example/a"},{"id":"b","network":"x","postedAt":"2026-11-02T00:00:00Z","url":"https://x.example/b"},{"id":"c","network":"bluesky","postedAt":"2026-11-03T00:00:00Z","url":"https://b.example/c"},{"id":"d","network":"bluesky","postedAt":"soon","url":"https://b.example/d"}]}"#
        let read = try JSONDecoder().decode(MemberPosts.self, from: Data(json.utf8))
        #expect(read.posts.map(\.id) == ["c", "a"])
    }

    @Test func theWallCarriesWhosePostItIs() throws {
        let wall = try fixture("posts-wall-schumer-nadler", as: PostsWall.self)
        #expect(wall.posts.count == 3)
        #expect(Set(wall.posts.compactMap(\.memberId)) == ["S000148"])
        #expect(wall.unreadable.isEmpty)
        // A wall post without its member can't be attributed, so it isn't shown.
        let json = #"{"posts":[{"id":"a","network":"youtube","postedAt":"2026-11-01T00:00:00Z","url":"https://y.example/a"}],"unreadable":["N000002",3]}"#
        let read = try JSONDecoder().decode(PostsWall.self, from: Data(json.utf8))
        #expect(read.posts.isEmpty)
        #expect(read.unreadable == ["N000002"])
    }

    @Test func onlyTheFreeNetworksAreRead() {
        #expect(SocialNetwork.allCases.filter(\.readable) == [.youtube, .bluesky, .mastodon])
    }
}
