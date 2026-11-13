#if os(iOS)
import DesignSystem
import Models
import SnapshotTesting
import SwiftUI
import Testing

/// `ScoreboardCard` in each state it is drawn in, on real votes from the captured member records.
///
/// The card is on every screen and is where the 2/1/6 digit bug lived, so it gets the most
/// references: each state in light, dark and the largest accessibility text size.
@MainActor
@Suite("ScoreboardCard snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct ScoreboardCardSnapshotTests {
    init() { _ = NoPortraits.installed }

    /// A card as Home's feed builds it, for one of `member`'s captured votes.
    private func card(_ record: String, _ voteId: String, member lastName: String) throws -> ScoreboardCard {
        let entry = try memberVote(record, voteId)
        let member = try #require(try austin().members.first { $0.lastName == lastName })
        return ScoreboardCard(
            vote: entry.vote,
            title: entry.measure?.title ?? entry.vote.question,
            citation: entry.measure?.citation,
            positions: [MemberPosition(member: member, position: entry.position, choice: entry.choice)]
        )
    }

    /// Three digits a side: 295–128, the shape that once stacked as 2/1/6.
    @Test func passedThreeDigits() throws {
        assertCard(try card("member-votes-doggett-40", "house-119-2-321", member: "Doggett"))
    }

    /// Yea ahead but short of two-thirds: FAILED with the most votes.
    @Test func failedShortOfTwoThirds() throws {
        assertCard(try card("member-votes-doggett-40", "house-119-2-293", member: "Doggett"))
    }

    /// Nay leads, one digit against two: 1–94.
    @Test func nayLeadsOneDigitAgainstTwo() throws {
        assertCard(try card("member-votes-cruz-40", "senate-119-2-246", member: "Cruz"))
    }

    /// A shutout: 424–0.
    @Test func shutout() throws {
        assertCard(try card("member-votes-doggett-40", "house-119-2-303", member: "Doggett"))
    }

    /// A 1,309-character resolution title, held to three lines (more at accessibility sizes).
    @Test func longMeasureTitle() throws {
        assertCard(try card("member-votes-doggett-40", "house-119-2-299", member: "Doggett"))
    }

    /// A procedural vote on no measure: no citation, the question as the title.
    @Test func proceduralNoCitation() throws {
        assertCard(try card("member-votes-cruz-40", "senate-119-2-223", member: "Cruz"))
    }

    /// Both senators on one card, as Home groups them.
    @Test func twoSenators() throws {
        let detail: VoteDetail = try fixture("vote-cloture-failed")
        let measure = try #require(detail.measure)
        assertCard(ScoreboardCard(vote: detail.vote, title: measure.title, citation: measure.citation, positions: detail.positions))
    }

    /// A Speaker ballot that elected nobody (lesson 16).
    @Test func speakerBallotNoWinner() throws {
        let detail: VoteDetail = try fixture("vote-election")
        assertCard(ScoreboardCard(vote: detail.vote, title: detail.vote.question))
    }

    /// Open and scheduled: the API has served neither yet (that is M3's live layer), so these take
    /// a real final and change only its state — VOTING and SOON, never an outcome.
    @Test func openVote() throws {
        let detail: VoteDetail = try fixture("vote-passage-hr1013")
        var vote = detail.vote
        vote.state = .open
        assertCard(ScoreboardCard(vote: vote, title: detail.measure?.title ?? vote.question, citation: detail.measure?.citation))
    }

    @Test func scheduledVote() throws {
        let detail: VoteDetail = try fixture("vote-passage-hr1013")
        var vote = detail.vote
        vote.state = .scheduled
        vote.totals = VoteTotals(yea: 0, nay: 0, present: 0, notVoting: 0)
        assertCard(ScoreboardCard(vote: vote, title: detail.measure?.title ?? vote.question, citation: detail.measure?.citation))
    }
}
#endif
