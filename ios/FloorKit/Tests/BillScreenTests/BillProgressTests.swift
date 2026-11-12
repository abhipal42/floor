import Foundation
import Testing
@testable import BillScreen
import Models

/// Loads one of the real staging responses captured in `ModelsTests/Fixtures`.
private func bill(_ name: String) throws -> Bill {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // BillScreenTests
    dir.deleteLastPathComponent() // Tests
    let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
    return try JSONDecoder().decode(Bill.self, from: Data(contentsOf: url))
}

private func made(
    type: String, origin: Chamber?, introducedOn: String?, markers: [(String, String)]
) -> Bill {
    Bill(
        id: "x", congress: 118, type: type, number: 1, citation: "X. 1", title: "A measure",
        shortTitle: nil, sponsor: nil, introducedOn: introducedOn, originChamber: origin,
        policyArea: nil, summary: nil, summaryStage: nil, latestAction: nil, cboEstimates: [],
        // Newest first, as the API returns them.
        actions: markers.reversed().map { BillAction(actedOn: $0.0, chamber: nil, text: $0.1) },
        votes: []
    )
}

@Suite("Path to law")
struct BillProgressTests {
    @Test func tracksABillAllTheWayToLaw() throws {
        let steps = BillProgress(bill: try bill("bill-enacted")).steps
        #expect(steps.map(\.label) == ["Introduced", "Passed House", "Passed Senate", "Became law"])
        #expect(steps.allSatisfy { $0.state == .done })
        #expect(steps.last?.on == "2023-06-03") // Became Public Law No: 118-5
        #expect(BillProgress(bill: try bill("bill-enacted")).isSettled)
    }

    @Test func marksTheChamberThatRejectedIt() throws {
        // H.Con.Res. 21 of the 118th failed on the House floor.
        let progress = BillProgress(bill: try bill("bill-no-short-title"))
        #expect(progress.steps.map(\.label) == ["Introduced", "Agreed to in House", "Agreed to in Senate"])
        #expect(progress.steps[0].state == .done)
        #expect(progress.steps[1].state == .failed)
        // It never reached the Senate, and a concurrent resolution never reaches the President.
        #expect(progress.steps[2].state == .pending)
        #expect(progress.isSettled)
    }

    @Test func aConcurrentResolutionThatClearedBothChambersHasNoLawStep() throws {
        let progress = BillProgress(bill: try bill("bill"))
        #expect(progress.steps.map(\.label) == ["Introduced", "Agreed to in House", "Agreed to in Senate"])
        #expect(progress.steps.allSatisfy { $0.state == .done })
    }

    /// The API returns only the last 30 actions, so a long-running bill loses its introduction off
    /// the end. `introducedOn` is the authority, or the step would read "not yet introduced".
    @Test func trustsTheIntroducedDateWhenTheMarkerHasScrolledOff() {
        let truncated = made(
            type: "hr", origin: .house, introducedOn: "2025-05-20",
            markers: [("2025-07-01", "Passed/agreed to in Senate: Passed Senate.")]
        )
        let steps = BillProgress(bill: truncated).steps
        #expect(steps[0].state == .done)
        #expect(steps[0].on == "2025-05-20")
    }

    @Test func aSimpleResolutionNeverLeavesItsOwnChamber() {
        let house = made(
            type: "hres", origin: .house, introducedOn: "2025-01-05",
            markers: [("2025-01-06", "Passed/agreed to in House: On agreeing to the resolution Agreed to.")]
        )
        let progress = BillProgress(bill: house)
        #expect(progress.steps.map(\.label) == ["Introduced", "Agreed to in House"])
        #expect(progress.isSettled)
    }

    @Test func aSenateBillStartsInTheSenate() {
        let senate = made(
            type: "s", origin: .senate, introducedOn: "2025-01-05",
            markers: [("2025-02-01", "Passed/agreed to in Senate: Passed Senate.")]
        )
        let steps = BillProgress(bill: senate).steps
        #expect(steps.map(\.label) == ["Introduced", "Passed Senate", "Passed House", "Became law"])
        #expect(steps[1].state == .done)
        #expect(steps[2].state == .pending)
        #expect(BillProgress(bill: senate).isSettled == false)
    }

    @Test func aBillStillMovingIsNotSettled() {
        let moving = made(
            type: "hr", origin: .house, introducedOn: "2025-01-05",
            markers: [("2025-02-01", "Passed/agreed to in House: On passage Passed.")]
        )
        let progress = BillProgress(bill: moving)
        #expect(progress.steps.map(\.state) == [.done, .done, .pending, .pending])
        #expect(progress.isSettled == false)
    }

    @Test func readsOnlyTheSummaryMarkersNotTheChamberChatter() {
        // A chamber-attributed action can say "Passed" without it being the stage marker; only the
        // null-chamber summary rows count.
        let noisy = Bill(
            id: "x", congress: 118, type: "hr", number: 1, citation: "H.R. 1", title: "t",
            shortTitle: nil, sponsor: nil, introducedOn: "2025-01-05", originChamber: .house,
            policyArea: nil, summary: nil, summaryStage: nil, latestAction: nil, cboEstimates: [],
            actions: [
                BillAction(actedOn: "2025-02-01", chamber: .senate, text: "Passed Senate without amendment."),
            ],
            votes: []
        )
        let steps = BillProgress(bill: noisy).steps
        #expect(steps[2].state == .pending)
    }

    /// Bill actions lag their votes: a roll call lands within the hour, a bill's actions on a
    /// slower refresh. Without the fallback the screen says "Passed House" is pending directly
    /// below the passage vote it just listed.
    @Test func usesTheChambersOwnRollCallWhenTheMarkerHasNotLandedYet() {
        let passage = Vote(
            id: "house-119-2-321", kind: .question, chamber: .house, congress: 119, session: 2,
            rollNumber: 321, question: "On Passage", billId: "119-hr-1013", nominationId: nil,
            billRef: nil, occurredAt: "2026-11-11T19:43:00.000Z", state: .final,
            threshold: .majority,
            totals: VoteTotals(yea: 295, nay: 128, present: 0, notVoting: 10), candidates: [],
            result: "Passed"
        )
        let lagging = Bill(
            id: "119-hr-1013", congress: 119, type: "hr", number: 1013, citation: "H.R. 1013",
            title: "t", shortTitle: nil, sponsor: nil, introducedOn: "2025-02-04",
            originChamber: .house, policyArea: nil, summary: nil, summaryStage: nil,
            latestAction: nil, cboEstimates: [],
            actions: [BillAction(actedOn: "2025-02-05", chamber: nil, text: "Introduced in House")],
            votes: [passage]
        )
        let steps = BillProgress(bill: lagging).steps
        #expect(steps[1].label == "Passed House")
        #expect(steps[1].state == .done)
        #expect(steps[1].on == "2026-11-11")
        // The Senate has not acted, and no vote says otherwise.
        #expect(steps[2].state == .pending)
    }

    @Test func doesNotMistakeAProceduralVoteForPassage() {
        let recommit = Vote(
            id: "house-119-2-300", kind: .question, chamber: .house, congress: 119, session: 2,
            rollNumber: 300, question: "On Motion to Recommit", billId: "119-hr-1013",
            nominationId: nil, billRef: nil, occurredAt: "2026-11-11T18:00:00.000Z", state: .final,
            threshold: .majority, totals: VoteTotals(yea: 210, nay: 213, present: 0, notVoting: 10),
            candidates: [], result: "Failed"
        )
        // A rule vote carries "Passed" but is not this bill's passage.
        let rule = Vote(
            id: "house-119-2-310", kind: .question, chamber: .house, congress: 119, session: 2,
            rollNumber: 310, question: "On Ordering the Previous Question", billId: "119-hr-1013",
            nominationId: nil, billRef: nil, occurredAt: "2026-11-11T18:30:00.000Z", state: .final,
            threshold: .majority, totals: VoteTotals(yea: 214, nay: 209, present: 0, notVoting: 10),
            candidates: [], result: "Passed"
        )
        #expect(recommit.isFinalPassage == false)
        #expect(rule.isFinalPassage == false)
        let bill = Bill(
            id: "119-hr-1013", congress: 119, type: "hr", number: 1013, citation: "H.R. 1013",
            title: "t", shortTitle: nil, sponsor: nil, introducedOn: "2025-02-04",
            originChamber: .house, policyArea: nil, summary: nil, summaryStage: nil,
            latestAction: nil, cboEstimates: [], actions: [], votes: [recommit, rule]
        )
        #expect(BillProgress(bill: bill).steps[1].state == .pending)
    }

    @Test func classifiesWhichMeasuresCanBecomeLaw() {
        #expect(["hr", "s", "hjres", "sjres"].allSatisfy { type in
            made(type: type, origin: .house, introducedOn: nil, markers: []).canBecomeLaw
        })
        #expect(["hres", "sres", "hconres", "sconres"].allSatisfy { type in
            !made(type: type, origin: .house, introducedOn: nil, markers: []).canBecomeLaw
        })
        #expect(["hres", "sres", "hconres", "sconres"].allSatisfy { type in
            made(type: type, origin: .house, introducedOn: nil, markers: []).isResolution
        })
    }
}
