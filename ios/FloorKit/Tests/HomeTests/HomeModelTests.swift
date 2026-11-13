import Foundation
import Testing
@testable import Home
import Models
import Onboarding

private let rep = Member(
    bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX",
    district: 37, chamber: .house
)
private let cruz = Member(
    bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX",
    district: nil, chamber: .senate
)
private let cornyn = Member(
    bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX",
    district: nil, chamber: .senate
)

private func vote(_ id: String, chamber: Chamber, at: String?) -> Vote {
    Vote(
        id: id, kind: .question, chamber: chamber, congress: 119, session: 1, rollNumber: 1,
        question: "On Passage", billId: "119-hr-1", nominationId: nil, billRef: "H R 1",
        occurredAt: at, state: .final, threshold: .majority,
        totals: VoteTotals(yea: 220, nay: 210, present: 0, notVoting: 5), candidates: [],
        result: "Passed"
    )
}

private let measure = MeasureSummary(
    id: "119-hr-1", kind: .bill, citation: "H.R. 1", title: "Lower Energy Costs Act"
)

private func row(_ v: Vote, _ position: Position, measure m: MeasureSummary? = measure) -> MemberVote {
    MemberVote(vote: v, position: position, choice: nil, measure: m)
}

@Suite("Home feed")
struct HomeModelTests {
    /// Two senators on the same roll call is one card carrying both, not two cards.
    @Test func mergesTheSameVoteFromTwoMembersIntoOneCard() {
        let senateVote = vote("senate-119-1-90", chamber: .senate, at: "2025-02-25T16:15:00.000Z")
        let items = HomeModel.merge([
            (cruz, [row(senateVote, .yea)]),
            (cornyn, [row(senateVote, .nay)]),
        ])
        #expect(items.count == 1)
        #expect(items[0].positions.count == 2)
        #expect(items[0].isSplit)
        // Ordered by chamber then surname, whatever order the requests finished in.
        #expect(items[0].positions.map(\.member.lastName) == ["Cornyn", "Cruz"])
        #expect(items[0].summary == "Cornyn Nay · Cruz Yea")
    }

    @Test func readsAsOneSentenceWhenOnlyOneMemberVoted() {
        let houseVote = vote("house-119-1-1", chamber: .house, at: "2025-01-10T15:00:00.000Z")
        let items = HomeModel.merge([(rep, [row(houseVote, .nay)])])
        #expect(items[0].summary == "Doggett voted Nay")
        #expect(items[0].isSplit == false)
    }

    @Test func ordersNewestFirstAndSinksVotesWithNoTimestamp() {
        let older = vote("house-119-1-1", chamber: .house, at: "2025-01-10T15:00:00.000Z")
        let newer = vote("house-119-1-2", chamber: .house, at: "2025-03-10T15:00:00.000Z")
        let undated = vote("house-119-1-3", chamber: .house, at: nil)
        let items = HomeModel.merge([(rep, [row(older, .yea), row(undated, .yea), row(newer, .nay)])])
        #expect(items.map(\.vote.id) == ["house-119-1-2", "house-119-1-1", "house-119-1-3"])
    }

    @Test func labelsACardWithTheMeasureAndFallsBackToTheQuestion() {
        let v = vote("house-119-1-1", chamber: .house, at: nil)
        #expect(HomeModel.merge([(rep, [row(v, .yea)])])[0].title == "H.R. 1 · Lower Energy Costs Act")
        // A procedural vote names no measure, so the question is all there is.
        let procedural = HomeModel.merge([(rep, [row(v, .yea, measure: nil)])])
        #expect(procedural[0].title == "On Passage")
    }

    /// One member's row may know the measure when another's does not; a null must not win.
    @Test func keepsTheMeasureWhicheverRowCarriesIt() {
        let senateVote = vote("senate-119-1-90", chamber: .senate, at: nil)
        let items = HomeModel.merge([
            (cruz, [row(senateVote, .yea, measure: nil)]),
            (cornyn, [row(senateVote, .nay)]),
        ])
        #expect(items[0].measure?.citation == "H.R. 1")
    }

    @Test func namesTheCandidateOnASpeakerElection() {
        var election = vote("house-118-1-10", chamber: .house, at: nil)
        election.kind = .election
        let items = HomeModel.merge([
            (rep, [MemberVote(vote: election, position: .candidate, choice: "Jeffries", measure: nil)]),
        ])
        #expect(items[0].summary == "Doggett voted Jeffries")
    }

    @Test func saysWhenAMemberDidNotVote() {
        let v = vote("house-119-1-1", chamber: .house, at: nil)
        // Not "Doggett voted did not vote".
        #expect(HomeModel.merge([(rep, [row(v, .notVoting)])])[0].summary == "Doggett did not vote")
        #expect(HomeModel.merge([(rep, [row(v, .present)])])[0].summary == "Doggett voted Present")
    }

    @Test func readsCorrectlyWhenOneSenatorMissedAVoteTheOtherMade() {
        let senateVote = vote("senate-119-1-90", chamber: .senate, at: nil)
        let items = HomeModel.merge([
            (cornyn, [row(senateVote, .notVoting)]),
            (cruz, [row(senateVote, .yea)]),
        ])
        #expect(items[0].summary == "Cornyn did not vote · Cruz Yea")
        #expect(items[0].isSplit)
    }

    @MainActor
    @Test func filtersByChamberWithoutRefetching() {
        let model = HomeModel(delegation: .sample, api: .init(baseURL: URL(string: "https://x.test")!))
        let house = vote("house-119-1-1", chamber: .house, at: "2025-01-10T15:00:00.000Z")
        let senate = vote("senate-119-1-90", chamber: .senate, at: "2025-02-25T16:15:00.000Z")
        model.items = HomeModel.merge([(rep, [row(house, .yea)]), (cruz, [row(senate, .nay)])])

        #expect(model.visibleItems.count == 2)
        model.filter = .house
        #expect(model.visibleItems.map(\.vote.id) == ["house-119-1-1"])
        model.filter = .senate
        #expect(model.visibleItems.map(\.vote.id) == ["senate-119-1-90"])
    }

    /// D.C.'s delegation, as `/v1/reps?lat=38.8977&lng=-77.0365` returned it on 2026-11-12: one
    /// delegate, no senators. Its Senate filter is empty by design and must say why.
    @MainActor
    @Test func explainsAnEmptySenateFeedWhereThereAreNoSenators() {
        let norton = Member(bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D",
                            state: "DC", district: 0, chamber: .house)
        let dc = Delegation(district: District(congress: 119, state: "DC", district: 0, countyFips: "11001"),
                            members: [norton])
        let model = HomeModel(delegation: dc, api: .init(baseURL: URL(string: "https://x.test")!))
        #expect(model.emptyFeedMessage == "No recent votes in this chamber.")
        model.filter = .senate
        #expect(model.visibleItems.isEmpty)
        #expect(model.emptyFeedMessage == "District of Columbia has no senators, so there are no Senate votes to show.")

        let texas = HomeModel(delegation: .sample, api: .init(baseURL: URL(string: "https://x.test")!))
        texas.filter = .senate
        #expect(texas.emptyFeedMessage == "No recent votes in this chamber.")
    }
}
