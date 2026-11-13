import Foundation
import Testing
@testable import Models

/// What VoiceOver reads for each card, on real staging responses.
@Suite("Spoken")
struct SpokenTests {
    private func reps(_ name: String) throws -> [String: Member] {
        let reps = try fixture(name, as: Reps.self)
        return Dictionary(uniqueKeysWithValues: reps.members.map { ($0.lastName, $0) })
    }

    @Test func aPassageReadsAsOneSentenceWithYourRepFirst() throws {
        let detail = try fixture("vote-passage-hr1013", as: VoteDetail.self)
        let measure = try #require(detail.measure)
        let text = Spoken.scoreboard(
            vote: detail.vote, title: measure.title, citation: measure.citation,
            positions: detail.positions, day: "Nov 11"
        )
        #expect(text == "H.R. 1013, On Passage, passed, 295 yea to 128 nay; your rep Jeffries voted nay. "
            + "Retirement Fairness for Charities and Educational Institutions Act of 2025. "
            + "House, Nov 11, needed 212.")
    }

    @Test func aFailedSuspensionSaysFailedAndTheTwoThirdsLine() throws {
        let detail = try fixture("vote-two-thirds-failed", as: VoteDetail.self)
        let measure = try #require(detail.measure)
        let text = Spoken.scoreboard(
            vote: detail.vote, title: measure.title, citation: measure.citation, positions: detail.positions
        )
        // The title already ends in a full stop; it is not doubled.
        #expect(text == "H.J.Res. 1, On Motion to Suspend the Rules and Pass, failed, 212 yea to 206 nay; "
            + "your rep Doggett voted nay. Proposing an amendment to the Constitution of the United States "
            + "to require that the Supreme Court of the United States be composed of nine justices. "
            + "House, needed 279.")
    }

    @Test func twoSenatorsWhoVotedAlikeAreReadTogether() throws {
        let detail = try fixture("vote-cloture-failed", as: VoteDetail.self)
        let text = Spoken.scoreboard(
            vote: detail.vote, title: "Stop Insider Trading Act", citation: "H.R. 7008",
            positions: detail.positions, day: "Sep 30"
        )
        #expect(text == "H.R. 7008, On Cloture on the Motion to Proceed, rejected, 53 yea to 47 nay; "
            + "your senators Cornyn and Cruz voted yea. Stop Insider Trading Act. Senate, Sep 30, needed 60.")
    }

    @Test func aSpeakerBallotSaysWhoLedAndThatNobodyWon() throws {
        let detail = try fixture("vote-election", as: VoteDetail.self)
        let text = Spoken.scoreboard(
            vote: detail.vote, title: detail.vote.question, citation: nil, positions: [], day: "Jan 5"
        )
        // No citation, so the question leads; the title is the question, so it is not read twice.
        #expect(text == "Election of the Speaker, Jeffries led with 212, McCarthy had 201; "
            + "nobody was elected on this ballot. House, Jan 5.")
    }

    @Test func anElectedSpeakerIsSaidToBeElected() throws {
        var vote = try fixture("vote-election", as: VoteDetail.self).vote
        vote.candidates = [Candidate(name: "McCarthy", total: 216), Candidate(name: "Jeffries", total: 212)]
        #expect(Spoken.result(vote) == "McCarthy elected Speaker with 216")
    }

    @Test func aTiedSpeakerBallotNamesBothAndNoLeader() throws {
        var vote = try fixture("vote-election", as: VoteDetail.self).vote
        vote.candidates = [Candidate(name: "Jeffries", total: 212), Candidate(name: "McCarthy", total: 212)]
        #expect(Spoken.result(vote) == "Jeffries and McCarthy tied with 212; nobody was elected on this ballot")
    }

    @Test func anAgreedVoteDoesNotDoubleTheTo() throws {
        let votes = try fixture("member-votes-cruz-40", as: MemberVotes.self)
        let vote = try #require(votes.votes.first { $0.vote.id == "senate-119-2-258" }).vote
        #expect(Spoken.result(vote) == "agreed to, 62 yea to 21 nay")
    }

    @Test func openAndScheduledVotesDoNotClaimAnOutcome() throws {
        var vote = try fixture("vote-passage-hr1013", as: VoteDetail.self).vote
        vote.state = .open
        #expect(Spoken.result(vote) == "voting now, 295 yea to 128 nay so far")
        vote.state = .scheduled
        #expect(Spoken.result(vote) == "scheduled")
        // A scheduled vote has no line to speak of yet.
        #expect(Spoken.scoreboard(vote: vote, title: "On Passage", citation: "H.R. 1013", positions: [])
            == "H.R. 1013, On Passage, scheduled. House.")
    }

    @Test func aSpeakerBallotPositionNamesTheCandidate() throws {
        let doggett = try #require(try reps("reps-location-austin")["Doggett"])
        let position = MemberPosition(member: doggett, position: .candidate, choice: "Jeffries")
        #expect(Spoken.members([position]) == "your rep Doggett voted for Jeffries")
        let missed = MemberPosition(member: doggett, position: .notVoting, choice: nil)
        #expect(Spoken.members([missed]) == "your rep Doggett did not vote")
    }

    @Test func aSplitDelegationKeepsEachGroupApart() throws {
        let members = try reps("reps-location-austin")
        let positions = try [
            MemberPosition(member: #require(members["Doggett"]), position: .nay, choice: nil),
            MemberPosition(member: #require(members["Cornyn"]), position: .yea, choice: nil),
            MemberPosition(member: #require(members["Cruz"]), position: .present, choice: nil),
        ]
        #expect(Spoken.members(positions)
            == "your rep Doggett voted nay, your senator Cornyn voted yea, your senator Cruz voted present")
    }

    @Test func memberCardsSpellOutTheSeat() throws {
        let austin = try reps("reps-location-austin")
        let doggett = try #require(austin["Doggett"])
        let cruz = try #require(austin["Cruz"])
        let hageman = try #require(try reps("reps-location-cheyenne")["Hageman"])
        let norton = try #require(try reps("reps-location-dc")["Norton"])
        #expect(Spoken.member(doggett) == "Lloyd Doggett, Democrat, Representative for Texas' 37th District")
        #expect(Spoken.member(cruz) == "Ted Cruz, Republican, Senator for Texas")
        #expect(Spoken.member(hageman) == "Harriet Hageman, Republican, Representative for Wyoming's at-large district")
        #expect(Spoken.member(norton) == "Eleanor Norton, Democrat, Delegate for the District of Columbia")
    }

    @Test func aDelegationCardReadsTheLoyaltyFigureOrItsAbsence() throws {
        let detail = try fixture("member-detail", as: MemberDetail.self)
        #expect(Spoken.delegationCard(detail.member, withPartyShare: detail.partyLoyalty.withPartyShare)
            == "Alma Adams, Democrat, Representative for North Carolina's 12th District. "
            + "Voted with their party 98.7 percent of the time")
        #expect(Spoken.delegationCard(detail.member, withPartyShare: nil)
            == "Alma Adams, Democrat, Representative for North Carolina's 12th District. No party-loyalty figure")
    }

    @Test func aVoteScreenRowReadsNameSeatAndPosition() throws {
        let detail = try fixture("vote-passage-hr1013", as: VoteDetail.self)
        let position = try #require(detail.positions.first)
        #expect(Spoken.memberPosition(position, partyNote: "with 128 of 211 Democrats")
            == "Hakeem Jeffries, Representative for New York's 8th District, voted nay, with 128 of 211 Democrats")
    }
}
