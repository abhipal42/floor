import Foundation
import Testing
@testable import Models

@Suite("Topics")
struct TopicsTests {
    /// A page as the API sends it, with the two nullable fields null: a bill listed but not yet staged
    /// and with no action, which is what a fresh import looks like.
    @Test func decodesATopicPageWithUnstagedBills() throws {
        let json = """
        {"congress":119,"topic":{"name":"Health","bills":3,"billsWithFloorVote":1,"latestActionOn":null},
         "filter":"stalled","nextCursor":"WyIyMDI2LTA0LTIyIiwiMTE5LWhyLTI0OTMiXQ",
         "bills":[{"id":"119-hr-6","congress":119,"type":"hr","number":6,"citation":"H.R. 6","label":"An Act",
                   "title":"An Act","policyArea":null,"stage":null,"stalled":true,"latestAction":null,"hasFloorVote":false}]}
        """
        let page = try JSONDecoder().decode(TopicBills.self, from: Data(json.utf8))
        #expect(page.filter == .stalled)
        #expect(page.bills.first?.stage == nil)
        #expect(page.bills.first?.latestAction == nil)
        #expect(page.nextCursor != nil)
    }

    /// A stage added on the server after this build shipped reads as "not staged", and the rest of
    /// the page still decodes.
    @Test func decodesAStageItDoesNotKnowAsNil() throws {
        let json = """
        [{"id":"119-hr-2493","congress":119,"type":"hr","number":2493,"citation":"H.R. 2493","label":"Improving Care",
          "title":"Improving Care","policyArea":"Health","stage":"in_conference","stalled":false,"latestAction":null,
          "hasFloorVote":true},
         {"id":"119-s-2","congress":119,"type":"s","number":2,"citation":"S. 2","label":"Secure America Act",
          "title":"Secure America Act","policyArea":"Immigration","stage":"law","stalled":false,"latestAction":null,
          "hasFloorVote":true}]
        """
        let bills = try JSONDecoder().decode([BillListItem].self, from: Data(json.utf8))
        #expect(bills.map(\.stage) == [nil, .law])
    }

    @Test func roundTripsTheSamples() throws {
        let data = try JSONEncoder().encode(SearchResults.sample)
        #expect(try JSONDecoder().decode(SearchResults.self, from: data) == .sample)
    }

    @Test func placesEachStageOnTheFiveStepRoad() {
        #expect(BillStage.introduced.roadSteps == 1)
        #expect(BillStage.passedHouse.roadSteps == 2)
        #expect(BillStage.passedSenate.roadSteps == 2)
        #expect(BillStage.passedBoth.roadSteps == 3)
        #expect(BillStage.toPresident.roadSteps == 4)
        #expect(BillStage.vetoed.roadSteps == 4)
        #expect(BillStage.law.roadSteps == 5)
        #expect(BillStage.failed.roadSteps == nil)
        #expect(BillStage.adopted.roadSteps == nil)
        #expect(BillStage.allCases.filter(\.isSettled) == [.law, .vetoed, .failed, .adopted])
    }
}
