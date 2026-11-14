import Foundation
import Models
import Testing
@testable import BillScreen

/// Speak up's fixed text (round 11, section C): only the bill's facts, the district, and the stance
/// the person chose; and the offline share line.
@Suite("Speak up template")
struct SpeakUpTests {
    private func load<T: Decodable>(_ name: String) throws -> T {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json")))
    }

    private func austin() throws -> Reps { try load("reps-location-austin") }

    /// H.R. 5267 on the week of Nov 16, as the House listed it.
    private func scheduledFacts() throws -> BillFacts {
        let bill: Bill = try load("bill-hr5267")
        let schedule: Schedule = try load("schedule-2026-11-16")
        let listing = try #require(FloorListing(schedule: schedule, billId: bill.id))
        return BillFacts(bill: bill, listing: listing)
    }

    @Test func theMockMessageForDoggett() throws {
        let reps = try austin()
        let doggett = try #require(reps.representative)
        let text = SpeakUpTemplate.message(to: doggett, district: reps.district, facts: try scheduledFacts(), stance: .howWillYouVote)
        #expect(text == """
        Dear Representative Doggett,

        I live in Texas' 37th District. H.R. 5267, the American Franchise Act, is scheduled for a House vote the week of November 16. How do you plan to vote, and why?

        [Add your own words (optional)]

        [Your name and address go in the office's form]
        """)
    }

    @Test func aSenatorIsWrittenToAsOneAndLivesInTheState() throws {
        let reps = try austin()
        let cornyn = try #require(reps.senators.first { $0.lastName == "Cornyn" })
        let text = SpeakUpTemplate.message(to: cornyn, district: reps.district, facts: try scheduledFacts(), stance: .support)
        #expect(text.hasPrefix("Dear Senator Cornyn,\n\nI live in Texas. H.R. 5267"))
        #expect(text.contains("I support it."))
        #expect(!text.contains("District"))
    }

    /// Each stance changes one line and nothing else: Floor never writes the argument.
    @Test func stancesDifferOnlyInTheirLine() throws {
        let reps = try austin()
        let doggett = try #require(reps.representative)
        let facts = try scheduledFacts()
        let texts = Stance.allCases.map { SpeakUpTemplate.message(to: doggett, district: reps.district, facts: facts, stance: $0) }
        #expect(Set(texts).count == 4)
        for (stance, text) in zip(Stance.allCases, texts) {
            let line = SpeakUpTemplate.stanceLine(stance, member: doggett)
            #expect(text.replacingOccurrences(of: line, with: "") == texts[0].replacingOccurrences(of: SpeakUpTemplate.stanceLine(.support, member: doggett), with: ""))
        }
    }

    @Test func changingTheStanceKeepsTheEdits() throws {
        let reps = try austin()
        let doggett = try #require(reps.representative)
        let original = SpeakUpTemplate.message(to: doggett, district: reps.district, facts: try scheduledFacts(), stance: .support)
        let edited = original.replacingOccurrences(of: SpeakUpTemplate.ownWords, with: "My family runs a franchise.")
        let swapped = try #require(SpeakUpTemplate.restanced(edited, from: .support, to: .oppose, member: doggett))
        #expect(swapped.contains("I oppose it."))
        #expect(!swapped.contains("I support it."))
        #expect(swapped.contains("My family runs a franchise."))
        // The person rewrote the stance line: nothing to swap.
        #expect(SpeakUpTemplate.restanced("Dear Rep, hello", from: .support, to: .oppose, member: doggett) == nil)
    }

    @Test func withoutAListingTheFactIsTheStage() throws {
        let bill: Bill = try load("bill-stuck-senate")
        let facts = BillFacts(bill: bill, listing: nil)
        #expect(facts.listing == nil)
        #expect(!facts.sentence.contains("scheduled"))
        #expect(facts.sentence.hasPrefix(bill.citation))
        #expect(facts.sentence.hasSuffix("."))
    }

    @Test func aDescriptiveTitleIsNotReadAsAName() {
        let bill = Bill(
            id: "119-hr-7254", congress: 119, type: "hr", number: 7254, citation: "H.R. 7254",
            title: "To amend the National Trails System Act to direct the Secretary of the Interior to conduct a study",
            shortTitle: nil, sponsor: nil, introducedOn: nil, originChamber: .house, policyArea: nil, summary: nil,
            summaryStage: nil, latestAction: nil, cboEstimates: [], actions: [], votes: [], stage: .introduced
        )
        let facts = BillFacts(bill: bill, listing: nil)
        #expect(facts.name == nil)
        #expect(facts.sentence == "H.R. 7254 was introduced in the House.")
    }

    @Test func theCallScriptReadsTheSameFacts() throws {
        let reps = try austin()
        let cornyn = try #require(reps.senators.first { $0.lastName == "Cornyn" })
        let facts = try scheduledFacts()
        let none = SpeakUpTemplate.callScript(to: cornyn, district: reps.district, facts: facts, stance: nil)
        #expect(none.count == 4)
        #expect(none[0] == "\"Hi, I'm a constituent from [your city], Texas.\"")
        #expect(none[1] == "\"I'm calling about H.R. 5267, the American Franchise Act. It is scheduled for a House vote the week of November 16.\"")
        #expect(none[2].contains("(you pick)"))
        let chosen = SpeakUpTemplate.callScript(to: cornyn, district: reps.district, facts: facts, stance: .howWillYouVote)
        #expect(chosen[2] == "\"I'd like to know how the Senator plans to vote.\"")
    }

    @Test func writeGoesToTheFormElseTheHouseFormElseTheWebsite() throws {
        let reps = try austin()
        let doggett = try #require(reps.representative)
        let cornyn = try #require(reps.senators.first)
        let none = MemberContact(phone: "202-225-4865", contactForm: nil, website: "https://doggett.house.gov", office: nil, address: nil)
        #expect(SpeakUpTemplate.formURL(for: doggett, contact: none) == SpeakUpTemplate.houseFindYourRep)
        #expect(SpeakUpTemplate.formURL(for: cornyn, contact: none)?.absoluteString == "https://doggett.house.gov")
        let form = MemberContact(phone: nil, contactForm: "https://www.cornyn.senate.gov/contact", website: nil, office: nil, address: nil)
        #expect(SpeakUpTemplate.formURL(for: cornyn, contact: form)?.absoluteString == "https://www.cornyn.senate.gov/contact")
        #expect(SpeakUpTemplate.telURL("202-225-4865")?.absoluteString == "tel:2022254865")
        #expect(SpeakUpTemplate.telURL(nil) == nil)
    }

    /// Offline, Share sends the same link shape and a line built the way the API builds its own.
    @Test func theShareFallbackMatchesTheAPI() throws {
        let bill: Bill = try load("bill-hr5267")
        let served: BillShare = try load("bill-share-hr5267")
        #expect(ShareFallback.url(bill).absoluteString == served.url)
        // The API names the bill only by a short title, and says "is up for"; ours is the same
        // sentence shape with the facts Floor has.
        #expect(ShareFallback.text(try scheduledFacts()).hasSuffix("What it does and how our members vote:"))
        #expect(ShareFallback.text(BillFacts(bill: bill, listing: nil)).hasSuffix("What it does and where it stands:"))
    }

    @Test func theBannerSaysHowTheHouseWillTakeItUp() throws {
        let schedule: Schedule = try load("schedule-2026-11-16")
        #expect(FloorListing(schedule: schedule, billId: "119-hr-5267")?.bannerLine
            == "Scheduled for House consideration under a rule, week of Nov 16.")
        #expect(FloorListing(schedule: schedule, billId: "119-hr-5490")?.bannerLine
            == "Scheduled for the House's fast track, needing two-thirds, week of Nov 16.")
        #expect(FloorListing(schedule: schedule, billId: "119-hr-2347")?.chamber == .senate)
        #expect(FloorListing(schedule: schedule, billId: "119-hr-1013") == nil)
    }
}
