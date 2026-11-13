import Foundation
import Testing
@testable import BillScreen
import Models

private func bill(_ name: String) throws -> Bill {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // BillScreenTests
    dir.deleteLastPathComponent() // Tests
    let url = dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")
    return try JSONDecoder().decode(Bill.self, from: Data(contentsOf: url))
}

@Suite("Six levels to law")
struct LawLevelsTests {
    /// H.R. 9340, the Ratepayer Protection Act: 417–3 in the House under suspension, then a cloture
    /// vote in the Senate that fell three short of sixty. The mock's own example.
    @Test func stopsAtTheSixty() throws {
        let levels = LawLevels(bill: try bill("bill-stuck-senate"))
        #expect(levels.levels.map(\.name) == ["Introduced", "Committee", "House", "Senate", "Same text", "Signed"])
        #expect(levels.levels.map(\.state) == [.done, .done, .done, .stuck, .pending, .pending])
        #expect(levels.levels.map(\.boss) == [false, false, true, true, false, true])
        #expect(levels.reached == 3)
        #expect(levels.status == "STOPPED AT THE 60")
        #expect(levels.sentence == "H.R. 9340 is stuck in the Senate.")
        #expect(levels.stoppedBy?.id == "senate-119-2-254")
    }

    /// H.R. 3746 of the 118th, enacted: every level done, and the Senate's 60-vote passage makes it
    /// a BOSS level even though the House needed a simple majority.
    @Test func climbsAllSixToLaw() throws {
        let levels = LawLevels(bill: try bill("bill-enacted"))
        #expect(levels.levels.allSatisfy { $0.state == .done })
        #expect(levels.levels.map(\.boss) == [false, false, false, true, false, true])
        #expect(levels.reached == 6)
        #expect(levels.status == "LAW")
        #expect(levels.isLaw)
    }

    /// H.Con.Res. 14: the Senate amended it and the House agreed to the amendment, so both chambers
    /// hold the same text — and a concurrent resolution is never signed.
    @Test func adoptsAConcurrentResolutionWithNoSignature() throws {
        let levels = LawLevels(bill: try bill("bill"))
        #expect(levels.levels.map(\.state) == [.done, .done, .done, .done, .done, .notApplicable])
        #expect(levels.levels[5].boss == false)
        #expect(levels.status == "ADOPTED")
        #expect(levels.sentence == "H.Con.Res. 14 was adopted.")
    }

    /// H.Con.Res. 21 of the 118th failed on the House floor.
    @Test func marksTheChamberThatRejectedIt() throws {
        let levels = LawLevels(bill: try bill("bill-no-short-title"))
        #expect(levels.levels[2].state == .failed)
        #expect(levels.status == "FAILED IN THE HOUSE")
        #expect(levels.sentence == "H.Con.Res. 21 failed in the House.")
    }

    @Test func saysWhatIsNextForABillHalfwayThere() throws {
        var halfway = try bill("bill-stuck-senate")
        // Drop the Senate's losing vote: passed the House, waiting on the Senate.
        halfway.votes.removeAll { $0.chamber == .senate }
        let levels = LawLevels(bill: halfway)
        #expect(levels.levels[3].state == .pending)
        #expect(levels.status == "LEVEL 3 OF 6")
        #expect(levels.sentence == "H.R. 9340 passed the House. Next: the Senate.")
    }

    /// A failed amendment or motion to recommit is how a bill usually gets through; it must not
    /// mark the chamber stuck.
    @Test func aFailedAmendmentDoesNotStickTheBill() throws {
        var pending = try bill("bill-stuck-senate")
        pending.votes = pending.votes.map { vote in
            var v = vote
            if v.chamber == .senate { v.question = "On the Amendment"; v.threshold = .majority }
            return v
        }
        #expect(LawLevels(bill: pending).levels[3].state == .pending)
    }

    @Test func describesEachKeyPlay() throws {
        let votes = try bill("bill-stuck-senate").votes
        #expect(votes.map(\.playDescription) == [
            "Senate cloture, 60 needed — 3 short",
            "House suspension, two-thirds needed",
        ])
        #expect(BillScreenModel.latestVotes(try bill("bill-stuck-senate"))[.senate]?.id == "senate-119-2-254")
    }

    @Test func writesTheSponsorLine() throws {
        #expect(try bill("bill-stuck-senate").sponsor?.sponsorLine == "Rep. Gabe Evans (R-CO-8)")
    }
}
