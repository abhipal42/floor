import Foundation
import Testing
@testable import Models

/// The pieces of the Finals stories that live in Models: the topic table, which votes only move a
/// measure along, a step's name and the verdict, and the new fields on the feed's rows.
@Suite("Stories: topics, steps, verdicts")
struct StoryModelTests {
    @Test func everyPolicyAreaHasAFamily() {
        for area in Topic.names {
            #expect(TopicGroup.table[area] != nil, "\(area) has no topic family")
        }
        // Nothing in the table that is not one of the 32.
        #expect(Set(TopicGroup.table.keys) == Set(Topic.names))
        #expect(TopicGroup.of(policyArea: "Armed Forces and National Security") == .defense)
        #expect(TopicGroup.of(policyArea: "Private Legislation") == .other)
        #expect(TopicGroup.of(policyArea: nil) == .other)
    }

    @Test func aNominationIsCourtsWhenItsPostIsAJudgeAndGovernmentOtherwise() {
        func nomination(_ position: String?) -> MeasureSummary {
            MeasureSummary(id: "119-pn-1", kind: .nomination, citation: "PN1", title: "x", position: position)
        }
        // Real posts from the feed on 2026-11-17.
        #expect(TopicGroup.of(nomination("United States Circuit Judge for the Tenth Circuit")) == .courts)
        #expect(TopicGroup.of(nomination("United States District Judge for the Northern District of Alabama")) == .courts)
        #expect(TopicGroup.of(nomination("Secretary of Labor")) == .gov)
        #expect(TopicGroup.of(nomination(nil)) == .gov)
        #expect(TopicGroup.of(nil) == .other)
    }

    /// Every kind the API's registry emits falls on exactly one side: procedural or deciding.
    @Test func everyVoteKindIsProceduralOrDecidesSomething() throws {
        let kinds = Set(try fixture("vote-kinds", as: VoteKindList.self).kinds.map(\.kind))
        let deciding: Set<String> = [
            "nomination", "treaty", "suspension", "passage", "joint_resolution", "resolution", "concurrent_resolution",
            "veto_override", "conference_report", "amendment", "concur", "concur_with_amendment", "speaker_election",
        ]
        #expect(Vote.proceduralKinds.isDisjoint(with: deciding))
        #expect(Vote.proceduralKinds.union(deciding) == kinds, "a vote kind is on neither side, or a stale one is listed")
    }

    private func vote(_ kind: String?, chamber: Chamber = .house, result: String) -> Vote {
        var vote = Vote.sample
        vote.chamber = chamber
        vote.result = result
        vote.explainer = kind.map { VoteExplainer(kind: $0, text: "", source: "") }
        return vote
    }

    @Test func aVoteWithNoExplainerDecidesSomething() {
        #expect(!vote(nil, result: "Passed").isProcedural)
        #expect(vote("rule", result: "Passed").isProcedural)
        #expect(!vote("passage", result: "Passed").isProcedural)
    }

    @Test func namesTheStepInPlainWords() {
        #expect(vote("rule", result: "Passed").stepName == "Rule for debate")
        #expect(vote("discharge", result: "Passed").stepName == "Discharge petition")
        #expect(vote("nomination", result: "Nomination Confirmed").stepName == "Confirmation")
        #expect(vote("suspension", result: "Passed").stepName == "Passage")
    }

    @Test func theVerdictSaysWhereItPassed() {
        #expect(vote("passage", chamber: .house, result: "Passed").verdict == "PASSED HOUSE")
        #expect(vote("passage", chamber: .senate, result: "Bill Passed").verdict == "PASSED SENATE")
        #expect(vote("nomination", chamber: .senate, result: "Nomination Confirmed").verdict == "CONFIRMED")
        #expect(vote("nomination", chamber: .senate, result: "Nomination Rejected").verdict == "REJECTED")
        #expect(vote("amendment", chamber: .senate, result: "Amendment Rejected").verdict == "FAILED")
        #expect(vote("cloture", chamber: .senate, result: "Cloture Motion Agreed to").verdict == "AGREED TO")
        #expect(vote("passage", result: "Failed").verdict == "FAILED")
    }

    /// `GET /v1/votes` on 2026-11-17, through this branch's API: the new measure fields and the
    /// party split.
    @Test func decodesTheFeedsNewFields() throws {
        let rows = try fixture("votes-recent-2026-11-17", as: RecentVotes.self).votes
        let passage = try #require(rows.first { $0.vote.id == "house-119-2-323" })
        #expect(passage.measure?.sponsor == MeasureSponsor(bioguideId: "B001257", lastName: "Bilirakis", party: "R", state: "FL"))
        #expect(passage.measure?.summaryLead == "This bill allows a veteran with a combat-related disability to receive retirement pay, "
            + "without reduction, concurrently with their disability compensation.")
        #expect(Set(passage.partyTotals.map(\.party)) == ["D", "R"])
        let republicans = try #require(passage.partyTotals.first { $0.party == "R" })
        #expect(republicans.yea == 182 && republicans.nay == 18)
        let rule = try #require(rows.first { $0.vote.id == "house-119-2-322" })
        #expect(rule.measure?.forBillId == "119-hr-2102")
        let domenico = try #require(rows.first { $0.vote.id == "senate-119-2-263" })
        #expect(domenico.measure?.position == "United States Circuit Judge for the Tenth Circuit")
        #expect(domenico.measure?.sponsor == nil)
    }

    /// A response saved by a build before v0.2.57 has none of them, and still decodes.
    @Test func decodesAnOlderResponseWithoutThem() throws {
        let rows = try fixture("votes-recent", as: RecentVotes.self).votes
        #expect(rows.allSatisfy { $0.partyTotals.isEmpty })
        #expect(rows.allSatisfy { $0.measure?.summaryLead == nil && $0.measure?.forBillId == nil })
    }
}
