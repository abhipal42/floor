import Foundation
import Testing
@testable import Models

private func captured<T: Decodable>(_ name: String) throws -> T {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private func action(_ text: String, on: String = "2026-11-12") -> LatestAction { LatestAction(on: on, text: text) }

/// The Round 10 design's stage chips, read from the stage and the latest action as real bills
/// carry them (texts from the topic and search responses captured on 2026-11-13).
@Suite("Stage chips")
struct StageChipTests {
    @Test func settledStagesNameThemselves() {
        #expect(StageChip.of(stage: .law, latestAction: action("Became Public Law No: 119-140.")) == StageChip("LAW", .law))
        #expect(StageChip.of(stage: .adopted, latestAction: nil) == StageChip("ADOPTED", .law))
        #expect(StageChip.of(stage: .vetoed, latestAction: nil) == StageChip("VETOED", .failed))
        #expect(StageChip.of(stage: .failed, latestAction: nil) == StageChip("FAILED", .failed))
        // Known only from the list, whose one action is the enactment: law, as the API stages it.
        #expect(StageChip.of(stage: nil, latestAction: action("Became Public Law No: 119-37.")) == StageChip("LAW", .law))
    }

    /// "VOTE FAILED" comes from the latest action: a failed motion to proceed leaves the stage alone.
    @Test func aFailedVoteIsReadFromTheLatestAction() {
        let proceed = action("Motion to proceed to consideration of measure not agreed to in Senate by Yea-Nay Vote. 48 - 51.")
        #expect(StageChip.of(stage: .introduced, latestAction: proceed) == StageChip("VOTE FAILED", .failed))
        let suspension = action("Failed of passage/not agreed to in House On motion to suspend the rules and pass the bill.")
        #expect(StageChip.of(stage: .passedSenate, latestAction: suspension) == StageChip("VOTE FAILED", .failed))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Cloture on the motion to proceed not invoked in Senate by Yea-Nay Vote. 53 - 47."))
            == StageChip("VOTE FAILED", .failed))
        // A motion to table failing is the bill surviving, not failing.
        #expect(StageChip.of(stage: .passedHouse, latestAction: action("Motion to table the motion to reconsider not agreed to."))
            == StageChip("PASSED HOUSE", .neutral))
    }

    /// The measure-level failures, in Congress.gov's own words, and the look-alikes that are not.
    @Test func onlyTheMeasureFailingIsAFailedVote() {
        let failed = [
            "Motion to proceed to consideration of measure not agreed to in Senate by Yea-Nay Vote. 48 - 51. Record Vote Number: 260.",
            "Cloture on the motion to proceed to the measure not invoked in Senate by Yea-Nay Vote. 51 - 48. Record Vote Number: 87.",
            "Cloture on the motion to proceed not invoked in Senate by Yea-Nay Vote. 53 - 47.",
            "Cloture on the measure not invoked in Senate by Yea-Nay Vote. 54 - 45. Record Vote Number: 302.",
            "Failed of passage/not agreed to in House: On motion to suspend the rules and pass the bill Failed by the Yeas and Nays: (2/3 required): 232 - 188 (Roll no. 47).",
            "Failed of passage in Senate by Yea-Nay Vote. 49 - 51. Record Vote Number: 12.",
        ]
        for text in failed {
            #expect(StageChip.failedVote(text.lowercased()), "\(text)")
            #expect(StageChip.of(stage: .introduced, latestAction: action(text)) == StageChip("VOTE FAILED", .failed), "\(text)")
        }
        let notTheBill = [
            // Amendments.
            "S.Amdt.2104 Amendment SA 2104 not agreed to in Senate by Yea-Nay Vote. 47 - 53. Record Vote Number: 140.",
            "Amendment SA 1847 not agreed to in Senate by Yea-Nay Vote. 45 - 54.",
            "H.Amdt.123 On agreeing to the Jayapal amendment (A003) Failed by recorded vote: 200 - 225 (Roll no. 310).",
            "Cloture on SA 2050 not invoked in Senate by Yea-Nay Vote. 50 - 49.",
            // Procedural motions whose failure is not the bill's.
            "On motion to recommit Failed by the Yeas and Nays: 203 - 215 (Roll no. 99).",
            "Motion to commit to Senate Committee on Finance with instructions not agreed to in Senate by Yea-Nay Vote. 47 - 52.",
            "Motion to waive all applicable budgetary discipline with respect to the measure not agreed to in Senate by Yea-Nay Vote. 45 - 53.",
            "Motion to instruct conferees not agreed to by the Yeas and Nays: 190 - 228 (Roll no. 401).",
            "Motion to table the motion to reconsider not agreed to.",
            // A different question entirely.
            "Cloture motion on the motion to proceed to the measure presented in Senate.",
        ]
        for text in notTheBill {
            #expect(!StageChip.failedVote(text.lowercased()), "\(text)")
        }
    }

    /// IN COMMITTEE is a referral, a hearing or a markup — not a discharge, and not the House
    /// sitting as the Committee of the Whole.
    @Test func inCommitteeIsNarrow() {
        #expect(StageChip.of(stage: .introduced, latestAction: action("Referred to the House Committee on Ways and Means."))
            == StageChip("IN COMMITTEE", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Committee Consideration and Mark-up Session Held"))
            == StageChip("IN COMMITTEE", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Senate Committee on Finance discharged by Unanimous Consent."))
            == StageChip("INTRODUCED", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("House resolved itself into the Committee of the Whole House on the state of the Union."))
            == StageChip("INTRODUCED", .neutral))
        #expect(StageChip.of(stage: .passedHouse, latestAction: action("The House rose from the Committee of the Whole House on the state of the Union to report it back to the House."))
            == StageChip("PASSED HOUSE", .neutral))
    }

    @Test func whereItSitsComesBeforeHowFarItGot() {
        #expect(StageChip.of(stage: .passedHouse, latestAction: action("Received in the Senate. Read twice. Placed on Senate Legislative Calendar under General Orders. Calendar No. 76."))
            == StageChip("SENATE CALENDAR", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Placed on the Union Calendar, Calendar No. 412."))
            == StageChip("HOUSE CALENDAR", .neutral))
        // H.R. 1013 on 2026-11-13: passed the House, now in a Senate committee.
        #expect(StageChip.of(stage: .passedHouse, latestAction: action("Received in the Senate and Read twice and referred to the Committee on Banking, Housing, and Urban Affairs."))
            == StageChip("IN COMMITTEE", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Subcommittee Hearings Held")) == StageChip("IN COMMITTEE", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Reported by the Committee on Energy and Commerce. H. Rept. 119-400."))
            == StageChip("REPORTED", .neutral))
        #expect(StageChip.of(stage: .toPresident, latestAction: action("Presented to President.")) == StageChip("TO THE PRESIDENT", .neutral))
        #expect(StageChip.of(stage: .passedBoth, latestAction: action("Message on Senate action sent to the House.")) == StageChip("PASSED BOTH", .neutral))
    }

    @Test func otherwiseTheStage() {
        #expect(StageChip.of(stage: .passedHouse, latestAction: action("Motion to reconsider laid on the table Agreed to without objection."))
            == StageChip("PASSED HOUSE", .neutral))
        #expect(StageChip.of(stage: .passedSenate, latestAction: action("Passed Senate without amendment by Unanimous Consent."))
            == StageChip("PASSED SENATE", .neutral))
        #expect(StageChip.of(stage: .introduced, latestAction: action("Introduced in Senate")) == StageChip("INTRODUCED", .neutral))
        #expect(StageChip.of(stage: nil, latestAction: action("Sponsor introductory remarks on measure.")) == nil)
        #expect(StageChip.of(stage: nil, latestAction: nil) == nil)
    }

    /// Every row of a real topic page gets a chip or deliberately none, and its road matches its stage.
    @Test func aRealTopicPage() throws {
        let page: TopicBills = try captured("topic-bills-health")
        for bill in page.bills {
            if bill.stage != nil { #expect(bill.chip != nil, "\(bill.citation) has a stage but no chip") }
            #expect(bill.roadSteps == bill.stage?.roadSteps)
        }
        let law = try #require(page.bills.first { $0.citation == "H.R. 1703" })
        #expect(law.chip == StageChip("LAW", .law))
        #expect(law.roadSteps == 5)
    }
}

@Suite("Bill rows")
struct BillRowTextTests {
    @Test func latestStepIsTheActionAndItsDay() {
        #expect(BillListItem.sample.latestStep
            == "Received in the Senate and Read twice and referred to the Committee on Health, Education, Labor, and Pensions. · Apr 22")
        #expect(Formats.monthDay("2026-11-11") == "Nov 11")
        #expect(BillRoad.legend == "Road to law: introduced · passed one chamber · passed both · to the President · law")
    }

    @Test func voiceOverReadsTheRowAsSentences() {
        #expect(Spoken.billRow(.sample) == "H.R. 2493, Improving Care in Rural America Reauthorization Act of 2025. "
            + "In Committee. Latest: Received in the Senate and Read twice and referred to the Committee on Health, "
            + "Education, Labor, and Pensions, Apr 22. Road to law: 2 of 5, passed one chamber.")
        #expect(Spoken.billRow(.sampleDisapproval).contains("Vote Failed."))
        #expect(Spoken.topicRow(Topic(name: "Health", bills: 724, billsWithFloorVote: 9, latestActionOn: "2026-11-12"))
            == "Health. 724 bills, 9 with a floor vote. Latest action Nov 12.")
        #expect(Spoken.topicRow(Topic(name: "Animals", bills: 1, billsWithFloorVote: 0, latestActionOn: nil))
            == "Animals. 1 bill, 0 with a floor vote.")
        #expect(Spoken.followReasons([]) == nil)
        #expect(Spoken.followReasons(["H.R. 1013"]) == "You follow H.R. 1013.")
        #expect(Spoken.followReasons(["H.R. 1013", "Health"]) == "You follow H.R. 1013 and Health.")
    }

    /// A bill's own record as a row: the API's label and stage, and "stalled" by the API's rule.
    @Test func aBillBecomesARow() throws {
        var bill: Bill = try captured("bill-hr1013")
        let now = try #require(Formats.instant("2026-11-13T17:00:00Z"))
        bill.stage = .passedHouse
        let row = BillListItem(bill: bill, now: now)
        #expect(row.citation == "H.R. 1013")
        #expect(row.label == bill.displayTitle) // no label in the capture: the display title
        #expect(row.stage == .passedHouse)
        #expect(row.hasFloorVote)
        #expect(!row.stalled)
        bill.latestAction = LatestAction(on: "2026-08-14", text: "Referred.")
        #expect(BillListItem(bill: bill, now: now).stalled) // 91 days
        bill.latestAction = LatestAction(on: "2026-08-15", text: "Referred.")
        #expect(!BillListItem(bill: bill, now: now).stalled) // 90 days
        bill.stage = .law
        bill.latestAction = LatestAction(on: "2025-01-01", text: "Became Public Law No: 119-1.")
        #expect(!BillListItem(bill: bill, now: now).stalled) // settled is never stalled
    }
}

@Suite("Round 10 fields")
struct Round10FieldTests {
    /// Responses saved before v0.2.29 carry none of the new fields, and must still open.
    @Test func olderResponsesStillDecode() throws {
        let bill: Bill = try captured("bill")
        #expect(bill.label == nil)
        #expect(bill.stage == nil)
        #expect(bill.listLabel == bill.displayTitle)
        let votes: MemberVotes = try captured("member-votes-doggett-40")
        #expect(votes.votes.compactMap(\.measure).allSatisfy { $0.policyArea == nil })
    }

    @Test func aBillCarriesItsStageAndLabelAndAnUnknownStageIsNil() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Bill.sample)) as! [String: Any]
        #expect(json["stage"] as? String == "passed_house")
        json["stage"] = "in_conference"
        let decoded = try JSONDecoder().decode(Bill.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.stage == nil)
        #expect(decoded.label == Bill.sample.label)
        #expect(Bill.sample.measure.policyArea == "Economics and Public Finance")
    }

    @Test func capturedTopicAndSearchResponsesDecode() throws {
        let topics: TopicList = try captured("topics")
        #expect(topics.topics.count == 32)
        let page: TopicBills = try captured("topic-bills-health")
        #expect(page.bills.count == 25)
        #expect(page.nextCursor != nil)
        let words: SearchResults = try captured("search-rural-health")
        #expect(!words.billNumber)
        let number: SearchResults = try captured("search-hr1013")
        #expect(number.billNumber)
        #expect(number.bills.map(\.citation) == ["H.R. 1013"])
    }
}
