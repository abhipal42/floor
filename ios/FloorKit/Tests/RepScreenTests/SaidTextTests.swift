import Foundation
import Models
import Testing
@testable import RepScreen

/// The words the Said and Posts segments print. Times compare with U+202F replaced (lesson 67) and
/// are checked in two zones, since the view takes its zone from the environment (lesson 69).
@Suite("Said and Posts words")
struct SaidTextTests {
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US")

    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func postTimesFollowTheZone() throws {
        let bluesky = try #require(Formats.instant("2026-11-16T22:01:00.000Z"))
        #expect(plain(PostText.when(bluesky, timeZone: eastern, locale: locale)) == "Nov 16 · 5:01 PM")
        #expect(plain(PostText.when(bluesky, timeZone: utc, locale: locale)) == "Nov 16 · 10:01 PM")
        let youtube = try #require(Formats.instant("2026-11-16T20:04:48.000Z"))
        #expect(plain(PostText.when(youtube, timeZone: eastern, locale: locale)) == "Nov 16 · 3:04 PM")
    }

    @Test func postLinksSayWhereTheyGo() {
        #expect(PostText.open(.youtube) == "Watch on YouTube")
        #expect(PostText.open(.bluesky) == "Open on Bluesky")
        #expect(PostText.open(.mastodon) == "Open on Mastodon")
    }

    @Test func theDeckIsLabelledByRaceAndHeading() {
        let said = MemberPromises.sample
        #expect(SaidText.deckLabel(said) == "2024 CAMPAIGN · 1 PROMISE")
        #expect(SaidText.eyebrow(.sample, number: 2, of: 3) == "DEFENDING AND EXPANDING MICHIGAN’S MIDDLE CLASS · 2 OF 3")
        let bare = CampaignPromise(heading: nil, quote: "Q", headline: "Q", topic: nil)
        #expect(SaidText.eyebrow(bare, number: 1, of: 1) == "PROMISE · 1 OF 1")
        #expect(SaidText.archived(said, timeZone: eastern, locale: locale) == "Archived Oct 12, 2024")
        #expect(SaidText.address(said) == "elissaslotkin.org/priorities")
    }

    /// Gillibrand's copy was taken at 04:37 UTC on Oct 16: Oct 16 in UTC, still Oct 16 in New York.
    @Test func theStampDatesTheCopy() {
        let said = MemberPromises(status: .noPlatform, electionYear: 2024, siteUrl: "https://kirstengillibrand.com/",
                                  snapshotUrl: "https://web.archive.org/web/20241016043737/https://kirstengillibrand.com/",
                                  snapshotAt: "2024-10-16T04:37:37Z")
        #expect(SaidText.stamp(said, timeZone: eastern, locale: locale) == "WAYBACK\nOCT 16 2024")
        #expect(SaidText.address(said) == "kirstengillibrand.com")
        #expect(SaidText.gap(said, name: "Gillibrand").body == "Gillibrand's 2024 campaign site listed no issues.")
    }

    /// Every gap says which it is; none is empty.
    @Test func everyGapSaysWhichItIs() {
        let titles = [MemberPromises.Status.noSite, .noSnapshot, .unchecked].map {
            SaidText.gap(MemberPromises(status: $0, electionYear: 2024, siteUrl: "https://example-campaign.org"), name: "Doe").title
        }
        #expect(titles == ["No campaign site on file", "No archived copy", "Not read yet"])
        let noCopy = SaidText.gap(MemberPromises(status: .noSnapshot, electionYear: 2024, siteUrl: "https://example-campaign.org"), name: "Doe")
        #expect(noCopy.body.contains("example-campaign.org"))
        #expect(noCopy.body.contains("election day 2024"))
        #expect(SaidText.gap(.unchecked, name: "Doe").body.contains("Doe's campaign site"))
    }

    /// The Posts row: the networks Floor reads first, the record's handles over the route's, and a
    /// label that says which kind each is.
    @Test func accountMarksOrderAndLabels() {
        let member = Member(
            bioguideId: "S000148", firstName: "Chuck", lastName: "Schumer", party: "D", state: "NY", district: nil,
            chamber: .senate,
            social: MemberSocial(twitter: "SenSchumer", facebook: "senschumer", youtube: "SenatorSchumer", bluesky: "schumer.senate.gov")
        )
        let posts = MemberPosts(posts: [], links: PostLinks(x: "https://x.com/Other", instagram: "senschumer"))
        let links = AccountMarks.links(member: member, posts: posts)
        #expect(links.map(\.network) == [.bluesky, .youtube, .x, .instagram, .facebook])
        #expect(links.map(AccountMarks.label) == [
            "Bluesky, schumer.senate.gov, posts shown in Floor",
            "YouTube, SenatorSchumer, posts shown in Floor",
            "X, @SenSchumer, opens X",
            "Instagram, senschumer, opens Instagram",
            "Facebook, senschumer, opens Facebook",
        ])
        #expect(AccountMarks.links(member: nil, posts: MemberPosts(posts: [])).isEmpty)
    }
}
