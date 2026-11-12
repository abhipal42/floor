import Foundation
import Testing
@testable import Models

@Suite("Vote")
struct VoteTests {
    /// Same payload the API test returns for GET /v1/votes/house-119-1-100.
    let json = """
    {
      "id": "house-119-1-100",
      "chamber": "house",
      "congress": 119,
      "session": 1,
      "rollNumber": 100,
      "question": "On Motion to Concur in the Senate Amendment",
      "billId": "119-hconres-14",
      "state": "final",
      "threshold": "majority",
      "totals": { "yea": 216, "nay": 214, "present": 0, "notVoting": 3 },
      "result": "Passed"
    }
    """

    @Test func decodesTheAPIPayload() throws {
        let vote = try JSONDecoder().decode(Vote.self, from: Data(json.utf8))
        #expect(vote == .sample)
    }

    @Test func decodesProceduralVotesWithoutABill() throws {
        let procedural = json
            .replacingOccurrences(of: "\"119-hconres-14\"", with: "null")
            .replacingOccurrences(of: "\"Passed\"", with: "null")
        let vote = try JSONDecoder().decode(Vote.self, from: Data(procedural.utf8))
        #expect(vote.billId == nil)
        #expect(vote.result == nil)
    }

    @Test func computesVotesNeededFromWhoVoted() {
        #expect(Vote.sample.votesNeeded == 216)  // 430 voting -> 216
        #expect(Vote.sample.leader == .yea)
    }

    @Test(arguments: [
        (VoteThreshold.majority, 435, 100, 218),
        (.majority, 408, 100, 205),
        (.twoThirds, 420, 100, 280),
        (.twoThirds, 421, 100, 281),
        (.threeFifthsSworn, 97, 100, 60),
        (.threeFifthsSworn, 99, 99, 60),
    ])
    func thresholdsMatchTheBackend(threshold: VoteThreshold, voting: Int, sworn: Int, needed: Int) {
        #expect(threshold.votesNeeded(voting: voting, sworn: sworn) == needed)
    }
}
