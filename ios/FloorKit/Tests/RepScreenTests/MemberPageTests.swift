import Foundation
import Models
import Testing
@testable import RepScreen

private func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent()
    dir.deleteLastPathComponent()
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")))
}

private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

private func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    c.locale = Locale(identifier: "en_US")
    return c
}

/// The member page's words, from Schumer's record as the API served it on 2026-11-17. Expected
/// values are counted from the fixture by hand: 15 yea and 25 nay; on the winning side on 9 yeas
/// that carried and 5 nays on questions that failed.
@Suite("Member page words")
struct MemberPageTextTests {
    private let schumer: MemberDetail
    private let votes: [MemberVote]

    init() throws {
        schumer = try load("member-detail-schumer-2026-11-17", as: MemberDetail.self)
        votes = try load("member-votes-schumer-40-2026-11-17", as: MemberVotes.self).votes
    }

    @Test func theEyebrowSaysWhoTheyAreToYou() {
        let member = schumer.member
        #expect(MemberPageText.eyebrow(member, isRep: true, following: false) == "YOUR SENATOR · NEW YORK")
        #expect(MemberPageText.eyebrow(member, isRep: false, following: true) == "FOLLOWING")
        #expect(MemberPageText.eyebrow(member, isRep: false, following: false) == "SENATE · NEW YORK")
        let nadler = Member(bioguideId: "N000002", firstName: "Jerrold", lastName: "Nadler", party: "D", state: "NY",
                            district: 12, chamber: .house)
        #expect(MemberPageText.eyebrow(nadler, isRep: true, following: false) == "YOUR REP · NY-12")
        #expect(MemberPageText.line(member) == "Democrat · Senate")
    }

    @Test func theTilesAreTheRecordsNumbers() {
        let tiles = MemberPageText.stats(schumer.partyLoyalty, RecordStats(votes: votes))
        #expect(tiles.map(\.value) == ["97.6%", "40/40", "14/40"])
        #expect(tiles.map(\.label) == ["With party", "Showed up", "Winning side"])
    }

    @Test func theStreakIsReadAloudOldestToNewest() {
        let calls = RecordStats(votes: votes).calls
        #expect(calls.first?.vote.occurredAt == votes.last?.vote.occurredAt)
        #expect(MemberPageText.streak(calls) == "Last 40 calls: 15 yea, 25 nay.")
    }

    /// The newest vote, 19:15 UTC on Nov 17: Nov 17 in New York, 04:15 on Nov 18 in Tokyo.
    @Test func aVoteRowSaysHowItWentInTheReadersZone() throws {
        let newest = try #require(votes.first)
        #expect(MemberPageText.voteLine(newest, calendar: calendar("America/New_York")) == "Confirmed 52–46 · Nov 17")
        #expect(MemberPageText.voteLine(newest, calendar: calendar("Asia/Tokyo")) == "Confirmed 52–46 · Nov 18")
        let position = MemberPageText.position(newest)
        #expect(position.word == "NAY")
        #expect(position.side == "lost")
    }

    @Test func aPromiseCardNamesItsTopicAndSite() throws {
        let said = try load("promises-schumer", as: MemberPromises.self)
        let education = try #require(said.promises.first { $0.topic == "Education" })
        #expect(MemberPageText.promiseTopic(education, said: said) == "EDUCATION · 2022 SITE")
        let noTopic = try #require(said.promises.first { $0.topic == nil })
        #expect(MemberPageText.promiseTopic(noTopic, said: said) == "ON THE ISSUES · 2022 SITE")
    }
}

/// What a post card draws, from the posts the API served on 2026-11-17.
@Suite("Post parts")
struct PostPartsTests {
    private let wall: PostsWall

    init() throws {
        wall = try load("posts-wall-schumer-nadler-2026-11-17", as: PostsWall.self)
    }

    private func post(_ containing: String) throws -> MemberPost {
        try #require(wall.posts.first { ($0.text ?? "").contains(containing) })
    }

    @Test func aYouTubePostIsAVideo() throws {
        let parts = PostParts(try post("WATCH: I am speaking live"))
        guard case .video = parts.media else { Issue.record("\(parts.media)"); return }
        #expect(parts.thread == nil)
    }

    /// The play button is YouTube's only: a Bluesky video's thumbnail is drawn as a photo.
    @Test func aBlueskyVideoThumbnailIsAPhoto() throws {
        let parts = PostParts(try post("briefed over A YEAR AGO"))
        guard case let .photo(url) = parts.media else { Issue.record("\(parts.media)"); return }
        #expect(url.host == "video.bsky.app")
    }

    @Test func aBlueskyImageIsAPhoto() throws {
        let parts = PostParts(try post("air traffic control"))
        guard case .photo = parts.media else { Issue.record("\(parts.media)"); return }
        #expect(parts.thread == "Thread · 2 posts")
    }

    /// Nadler's post ends in "www.billboard.com/pro/congress...": a link card, the address out of
    /// the text, nothing fetched.
    @Test func aLinkWithAnImageIsALinkCard() throws {
        let parts = PostParts(try post("Stolen Intelligence"))
        #expect(parts.media == .link(
            image: URL(string: "https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:lawfan5jdv75zng4kwjyfzey/bafkreiec66bzqgagqi36upa66pi6qzymrd56oe6juuqipbnjckalkyhq7q")!,
            domain: "billboard.com", address: "billboard.com/pro/congress…"
        ))
        #expect(parts.text == "Trump calls Artificial Intelligence \"Super Intelligence\". In reality, a more accurate name would be \"Stolen Intelligence.\"")
    }

    @Test func textAloneHasNoMedia() throws {
        let parts = PostParts(try post("We must invest in public education"))
        #expect(parts.media == .none)
        #expect(parts.thread == "Thread · 2 posts")
    }

    @Test func onlyTheLiteralThreadPatternsCount() {
        #expect(PostParts.thread("We must act. (1/2)") == "Thread · 2 posts")
        #expect(PostParts.thread("A long one 1/") == "Thread")
        #expect(PostParts.thread("(2/2) and the rest") == nil)
        #expect(PostParts.thread("Up 1/2 a point") == nil)
        #expect(PostParts.thread("Second part (2/2)") == nil)
    }

    @Test func theHandleIsTheMembersOwnOrTheAddresss() throws {
        let schumer = try load("member-detail-schumer-2026-11-17", as: MemberDetail.self).member
        let youtube = try post("WATCH: I am speaking live")
        #expect(PostText.handle(youtube, member: schumer) == "@SenatorSchumer")
        // On the wall, with no accounts: a video's address names no channel, so the time stands alone.
        #expect(PostText.handle(youtube, member: nil) == nil)
        let nadler = try post("We must invest in public education")
        // No member on file: the handle in the post's own address.
        #expect(PostText.handle(nadler, member: nil) == "@nadler.house.gov")
        let mastodon = MemberPost(id: "mastodon:1", network: .mastodon, postedAt: "2026-11-17T00:00:00.000Z", text: nil,
                                  url: "https://mastodon.social/@example/1")
        #expect(PostText.handle(mastodon, member: nil) == "@example@mastodon.social")
        #expect(PostText.partyChip(schumer) == "D-NY")
    }

    /// The wall's day dividers, against noon Eastern on Nov 17: Schumer's 18:02 UTC video is today in
    /// New York; Nadler's 01:27 UTC Nov 11 post is still Nov 10 there, and Nov 11 in UTC.
    @Test func dayDividersFollowTheReadersZone() throws {
        let now = try #require(Formats.instant("2026-11-17T17:00:00.000Z"))
        let eastern = calendar("America/New_York")
        let video = try #require(try post("WATCH: I am speaking live").postedDate)
        #expect(PostText.day(video, now: now, calendar: eastern) == "Today")
        let grocery = try #require(try post("Grocery prices").postedDate)
        #expect(PostText.day(grocery, now: now, calendar: eastern) == "Yesterday")
        let zabar = try #require(try post("Stanley Zabar").postedDate)
        #expect(PostText.day(zabar, now: now, calendar: eastern) == "Tue, Nov 10")
        #expect(PostText.day(zabar, now: now, calendar: calendar("UTC")) == "Wed, Nov 11")
        let days = PostText.days(wall.posts, now: now, calendar: eastern)
        #expect(days.first?.title == "Today")
        #expect(days.map(\.posts.count).reduce(0, +) == wall.posts.count)
        #expect(Set(days.map(\.title)).count == days.count)
        #expect(plain(PostText.time(video, timeZone: eastern.timeZone, locale: Locale(identifier: "en_US"))) == "1:02 PM")
    }
}
