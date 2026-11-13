import Foundation
import Testing
@testable import Models

/// `/v1/members/{id}/funding`, on the real responses the landing page's tests use (captured from
/// staging 2026-11-13, copied from `apps/web/fixtures`). The expected strings are the landing page's
/// own test expectations, so the app and the page print the same money the same way.
@Suite("Funding")
struct FundingTests {
    static let withFunding = ["J000294", "D000399", "C001056", "C001098"]

    private func money(_ id: String) throws -> MemberFunding {
        try fixture("funding-\(id)", as: MemberFunding.self)
    }

    @Test func decodesEveryCapturedResponse() throws {
        for id in Self.withFunding {
            let body = try money(id)
            #expect(body.member.bioguideId == id)
            #expect(body.funding != nil, "\(id)")
        }
        #expect(try money("A000383").funding == nil)
    }

    @Test func matchesTheLandingPagesJeffriesFigures() throws {
        let f = try #require(try money("J000294").funding)
        #expect(f.period == "2026 campaign · Jan 2025 – Oct 14, 2026")
        #expect(MoneyFormat.total(f.receipts) == "$17.9M")
        #expect(f.cashOnHand.map(MoneyFormat.total) == "$4.23M")
        #expect(f.amount(.pac) == 2_765_400)
        // The mock's legend, to the decimal: 45.5 / 25.4 / 15.5 / 13.6.
        #expect(Funding.Part.allCases.map(f.percent) == ["45.5%", "25.4%", "15.5%", "13.6%"])
    }

    @Test func everyMembersPartsAddUpToWhatTheyRaised() throws {
        for id in Self.withFunding {
            let f = try #require(try money(id).funding)
            let sum = Funding.Part.allCases.map(f.amount).reduce(0, +)
            #expect(abs(sum - f.receipts) < 0.01, "\(id)")
            #expect(f.pacChecks().allSatisfy { $0.direct > 0 }, "\(id)")
        }
    }

    /// Lesson 33: a senator's campaign is for 2030 while the PAC rows are the 2025–26 files, and the
    /// screen must say which is which.
    @Test func datesASenatorsPacListByItsOwnCycle() throws {
        let f = try #require(try money("C001098").funding)
        #expect(f.period == "2030 campaign · Jan 2025 – Sep 30, 2026")
        #expect(f.pacsNote.hasPrefix("Each PAC's own checks, from its 2025–26 filings."))
        let pacs = f.pacChecks()
        #expect(pacs.count == 10)
        #expect(pacs[0].displayName == "Motorola Solutions, Inc. PAC")
        #expect(pacs[0].kind == "Company")
        #expect(MoneyFormat.check(pacs[0].direct) == "$10K")
    }

    @Test func partyMoneyRidesWithTransfers() throws {
        // Cornyn's campaign reports $62,000 from party committees.
        let f = try #require(try money("C001056").funding)
        #expect(f.party == 62000)
        #expect(f.amount(.other) == f.party + f.other)
    }

    @Test func listsOnlyCommitteesWithAPositiveDirectCheck() {
        var f = Funding.sample
        f.committees = [
            PacCheck(committeeId: "C1", name: "A PAC", kind: nil, orgType: nil, connectedOrg: nil, direct: 5000, earmarked: 0),
            PacCheck(committeeId: "C2", name: "VOIDED PAC", kind: nil, orgType: nil, connectedOrg: nil, direct: 0, earmarked: 3000),
            PacCheck(committeeId: "C3", name: "NETTED PAC", kind: nil, orgType: nil, connectedOrg: nil, direct: -500, earmarked: 0),
        ]
        #expect(f.pacChecks().map(\.committeeId) == ["C1"])
        #expect(f.pacChecks(limit: 0).isEmpty)
    }

    @Test func saysWhyThereIsNothingForAnAppointedSenator() throws {
        let body = try money("A000383")
        #expect(body.noFilings.title == "No campaign filings yet")
        #expect(body.noFilings.body.contains("Alan Armstrong has no totals at the FEC for a current campaign"))
    }

    @Test func saysWhenNoCommitteeHasGiven() {
        var f = Funding.sample
        f.committees = []
        #expect(f.pacsNone.title == "No PAC checks on file for 2025–26.")
        f.committeesCycle = nil
        #expect(f.pacsNone.title == "No PAC checks on file.")
        #expect(!f.pacsNote.contains("filings"))
    }

    /// The worker computes "other" as receipts minus the rest, and refunds can push it below zero.
    /// The bar and the legend both draw it as 0, the shares still add to 100%, and a note says why.
    @Test func aNegativeRemainderIsShownAsZeroAndExplained() {
        var f = Funding.sample
        f.receipts = 1_000_000
        f.smallDollar = 500_000
        f.itemized = 400_000
        f.pac = 112_000
        f.party = 0
        f.other = -12_000
        #expect(f.amount(.other) == -12_000)
        #expect(f.shown(.other) == 0)
        #expect(f.shareBase == 1_012_000)
        #expect(f.percent(.other) == "0.0%")
        let shares = Funding.Part.allCases.map { f.shown($0) / f.shareBase }
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        let note = f.adjustmentNote
        #expect(note?.contains("−$12K") == true)
        #expect(note?.contains("includes refunds/adjustments") == true)
        // Nothing to say when the remainder is zero or more.
        #expect(Funding.sample.adjustmentNote == nil)
        #expect(Funding.sample.percent(.smallDollar) == "45.5%")
    }

    @Test func reportsNoShareOfNothing() {
        // Shares are of the parts drawn, so with every part at zero (or below) there is nothing to
        // share out.
        var f = Funding.sample
        (f.receipts, f.smallDollar, f.itemized, f.pac, f.party, f.other) = (0, 0, 0, 0, 0, -50)
        #expect(f.shareBase == 0)
        #expect(f.percent(.smallDollar) == "—")
    }

    /// The response names committees and nothing else: no field could carry a person's name.
    @Test func carriesNoIndividualDonor() throws {
        for id in Self.withFunding {
            let data = try Data(contentsOf: try #require(Bundle.module.url(
                forResource: "Fixtures/funding-\(id)", withExtension: "json"
            )))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let funding = try #require(json["funding"] as? [String: Any])
            for row in try #require(funding["committees"] as? [[String: Any]]) {
                #expect(Set(row.keys) == Set(Mirror(reflecting: PacCheck.sample).children.compactMap(\.label)))
            }
        }
    }

    @Test(arguments: [
        ("MOTOROLA SOLUTIONS, INC. POLITICAL ACTION COMMITTEE", "Motorola Solutions, Inc. PAC"),
        ("EXXON MOBIL CORPORATION POLITICAL ACTION COMMITTEE (EXXONMOBIL PAC)", "Exxon Mobil Corporation PAC"),
        ("AMERICAN FEDERATION OF STATE COUNTY & MUNICIPAL EMPLOYEES  P E O P L E",
         "American Federation of State County & Municipal Employees PEOPLE"),
        ("AMERICAN FEDERATION OF TEACHERS, AFL-CIO COMMITTEE ON POLITICAL EDUCATION",
         "American Federation of Teachers, AFL-CIO Committee on Political Education"),
        ("SOUTHERN GLAZER'S WINE AND SPIRITS PAC", "Southern Glazer's Wine and Spirits PAC"),
        ("TRANSPORTATION INTERMEDIARIES ASSOCIATION'S TIAPAC", "Transportation Intermediaries Association's TIAPAC"),
        ("L3HARRIS TECHNOLOGIES, INC. PAC", "L3HARRIS Technologies, Inc. PAC"),
        ("THE AMERICAN OCCUPATIONAL THERAPY ASSOCIATION, INC. POLITICAL ACTION COMMITTEE (AOTPAC)",
         "The American Occupational Therapy Association, Inc. PAC"),
        ("PERATON CORP. POLITICAL ACTION COMMITTEE (A.K.A. 'PERATON PAC')", "Peraton Corp. PAC"),
        // A capital after a leading O' or D', and Y as a vowel in a word of three letters or more.
        ("FRIENDS OF JOHN O'BRIEN", "Friends of John O'Brien"),
        ("D'AMATO FOR SENATE", "D'Amato for Senate"),
        ("LYNN FOR CONGRESS", "Lynn for Congress"),
    ])
    func titleCasesCommitteeNamesAsTheLandingPageDoes(raw: String, want: String) {
        #expect(CommitteeName.display(raw) == want)
    }

    @Test func formatsMoneyAsTheLandingPageDoes() {
        #expect(MoneyFormat.total(17_893_352) == "$17.9M")
        #expect(MoneyFormat.total(4_234_848) == "$4.23M")
        #expect(MoneyFormat.total(41_884_545) == "$41.9M")
        #expect(MoneyFormat.total(884_398) == "$884K")
        #expect(MoneyFormat.total(1_000_000) == "$1.00M")
        // Rounded before the unit is chosen, and the sign before the dollar sign.
        #expect(MoneyFormat.total(999_500) == "$1.00M")
        #expect(MoneyFormat.total(999_499) == "$999K")
        #expect(MoneyFormat.total(9_996_000) == "$10.0M")
        #expect(MoneyFormat.total(9_960_000) == "$9.96M")
        #expect(MoneyFormat.total(-12_000) == "−$12K")
        #expect(MoneyFormat.total(-1_234_567) == "−$1.23M")
        // Spoken in words, at the precision it is printed at.
        #expect(MoneyFormat.spoken(17_893_352) == "17.9 million dollars")
        #expect(MoneyFormat.spoken(4_234_848) == "4.23 million dollars")
        #expect(MoneyFormat.spoken(884_398) == "884 thousand dollars")
        #expect(MoneyFormat.spoken(-12_000) == "minus 12 thousand dollars")
        #expect(MoneyFormat.check(10000) == "$10K")
        #expect(MoneyFormat.check(7000) == "$7K")
        #expect(MoneyFormat.check(2500) == "$2.5K")
        #expect(MoneyFormat.check(15250) == "$15.3K")
        #expect(MoneyFormat.check(750) == "$750")
    }

    @Test func readsFECDatesWithoutSlidingADayWestOfUTC() {
        #expect(FundingDates.range("2021-01-01", "2026-10-14") == "Jan 2021 – Oct 14, 2026")
        #expect(FundingDates.range(nil, "2026-09-30") == "Sep 30, 2026")
        #expect(FundingDates.range(nil, nil) == "")
        #expect(FundingDates.cycleYears(2026) == "2025–26")
    }

    /// The route answers with `MemberFunding`, so `ContractTests`' field check covers it.
    @Test func theRouteAnswersWithMemberFunding() throws {
        let paths = try #require(try ContractTests.document()["paths"] as? [String: Any])
        let route = try #require(paths["/v1/members/{id}/funding"] as? [String: Any])
        let get = try #require(route["get"] as? [String: Any])
        let ok = try #require((get["responses"] as? [String: Any])?["200"] as? [String: Any])
        let json = try #require((ok["content"] as? [String: Any])?["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])
        #expect(schema["$ref"] as? String == "#/components/schemas/MemberFunding")
    }
}
