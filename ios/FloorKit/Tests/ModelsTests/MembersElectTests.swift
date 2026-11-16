import Foundation
import Testing
@testable import Models

/// Members-elect (round 12): the contract's shapes, read leniently, and the words and rows built from
/// them. El-Sayed's facts are the contract's (real); the undecided seats are a layout sample.
@Suite("Members-elect")
struct MembersElectTests {
    private let us = Locale(identifier: "en_US")

    @Test func readsTheProfile() throws {
        let profile = try fixture("member-elect-mi-sen", as: ElectProfile.self)
        #expect(profile.elect == .sample)
        #expect(profile.elect.title == "Senator-elect")
        #expect(profile.elect.call.on == "2026-11-04")
        #expect(profile.funding?.receipts == 53_830_872)
        #expect(profile.funding?.disbursements == 51_096_843)
        #expect(profile.funding?.coverageEnd == "2026-10-14")
        #expect(profile.disclosure == nil)
    }

    /// An older API sends no `leavingOn`, `elect` or `pending`; it all still decodes, as nothing.
    @Test func olderResponsesStillDecode() throws {
        let reps = try fixture("reps-location-austin", as: Reps.self)
        #expect(reps.elect.isEmpty && reps.pending.isEmpty)
        #expect(reps.members.allSatisfy { $0.leavingOn == nil })
        let search = try fixture("members-search-new-york", as: MemberSearch.self)
        #expect(!search.members.isEmpty && search.elect.isEmpty)
        let none = try JSONDecoder().decode(MembersElect.self, from: Data("{}".utf8))
        #expect(none == MembersElect())
    }

    /// A row the build can't read is dropped, not the list; an unknown status is still no winner.
    @Test func lenientWhereTheShapeMoves() throws {
        let odd = Data(#"""
        {"elect":[{"id":"x"},{"id":"e","firstName":"A","lastName":"B","party":"D","state":"MI","chamber":"senate",
          "takesOffice":"2027-01-03","call":{"by":"AP","on":7},"district":"no","replaces":{"nope":1}}],
         "pending":[{"id":"p","state":"LA","chamber":"house","district":5,"status":"recount"},{"state":"LA"}]}
        """#.utf8)
        let read = try JSONDecoder().decode(MembersElect.self, from: odd)
        #expect(read.elect.map(\.id) == ["e"])
        #expect(read.elect[0].call.on == nil)
        #expect(read.elect[0].district == nil)
        #expect(read.elect[0].replaces == nil)
        #expect(read.pending.map(\.id) == ["p"])
        #expect(read.pending[0].status == .uncalled)
        #expect(read.pending[0].seatBadge == "LA-5")
    }

    @Test func leavingOnIsReadWhenSent() throws {
        let search = try fixture("members-search-michigan-senate", as: MemberSearch.self)
        #expect(search.members.first { $0.lastName == "Peters" }?.leavingOn == "2027-01-03")
        #expect(search.members.first { $0.lastName == "Slotkin" }?.leavingOn == nil)
        #expect(search.elect.map(\.id) == ["elect-2026-mi-sen"])
    }

    /// Only an address's own seats: the state's Senate seats and its House district.
    @Test func seatsKeepsOnlyYourSeats() {
        let house = MemberElect(
            id: "elect-2026-mi-12", bioguideId: nil, firstName: "A", lastName: "B", party: "D", state: "MI", district: 12,
            chamber: .house, takesOffice: "2027-01-03", replaces: nil, call: ElectCall(by: "House Clerk", on: nil, sourceUrl: nil),
            fecCandidateId: nil
        )
        var other = house
        other.id = "elect-2026-mi-13"
        other.district = 13
        var texas = MemberElect.sample
        texas.id = "elect-2026-tx-sen"
        texas.state = "TX"
        let all = MembersElect(elect: [.sample, house, other, texas], pending: [.sample])
        #expect(all.seats(state: "MI", district: 12).elect.map(\.id) == ["elect-2026-mi-sen", "elect-2026-mi-12"])
        #expect(all.seats(state: "MI", district: 12).pending.isEmpty)
        #expect(all.seats(state: "LA", district: 5).pending == [.sample])
    }

    // MARK: Rows

    private let peters = Member(bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D", state: "MI", district: nil, chamber: .senate)
    private let slotkin = Member(bioguideId: "S001208", firstName: "Elissa", lastName: "Slotkin", party: "D", state: "MI", district: nil, chamber: .senate)

    /// The elect sits directly under the member they replace, who is LEAVING on the day they take
    /// office even when the member row itself (a stored delegation) has no `leavingOn`.
    @Test func theElectSitsUnderTheMemberLeaving() {
        let rows = SeatRow.rows(members: [peters, slotkin], elect: [.sample], pending: [])
        #expect(rows == [.member(peters, leavingOn: "2027-01-03"), .elect(.sample), .member(slotkin, leavingOn: nil)])
        #expect(SeatRow.changing(rows))
        #expect(!SeatRow.changing(SeatRow.rows(members: [peters, slotkin], elect: [], pending: [])))
    }

    @Test func unplacedSeatsGoLastAndAPendingSeatUnderItsIncumbent() {
        var held = PendingSeat.sample
        held.incumbent = SeatHolder(bioguideId: "S001208", firstName: "Elissa", lastName: "Slotkin", party: "D")
        var loose = PendingSeat.sample
        loose.id = "elect-2026-la-6"
        let rows = SeatRow.rows(members: [slotkin, peters], elect: [], pending: [loose, held])
        #expect(rows.map(\.id) == ["member-S001208", "pending-elect-2026-la-5", "member-P000595", "pending-elect-2026-la-6"])
        // An incumbent in an undecided race is not LEAVING: nobody replaces them yet.
        #expect(rows.first == .member(slotkin, leavingOn: nil))
    }

    /// Ohio 2026: Sherrod Brown won the special for the seat appointed Sen. Jon Husted holds, and is
    /// sworn in once Ohio certifies, on no known date. No date anywhere, and Husted is not LEAVING.
    /// (`TEST-HUSTED` stands in for an id this test does not need to be real.)
    @Test func aSpecialElectionsWinnerTakesOfficeOnCertification() throws {
        let json = Data(#"""
        {"id":"elect-2026-oh-sen","bioguideId":"B000944","firstName":"Sherrod","lastName":"Brown","party":"D","state":"OH",
         "district":null,"chamber":"senate","takesOffice":"2026-12-01","takesOfficeOnCertification":true,
         "replaces":{"bioguideId":"TEST-HUSTED","firstName":"Jon","lastName":"Husted","party":"R"},
         "call":{"by":"AP","on":"2026-11-04","sourceUrl":"https://example.com/call"},"fecCandidateId":null}
        """#.utf8)
        let brown = try JSONDecoder().decode(MemberElect.self, from: json)
        #expect(brown.takesOfficeOnCertification)
        #expect(!MemberElect.sample.takesOfficeOnCertification) // absent: false
        #expect(ElectText.takesOffice(brown, locale: us) == "when Ohio certifies")
        #expect(ElectText.takesOffice(.sample, locale: us) == "Jan 3")
        #expect(ElectText.electionDay(brown) == "2026-11-03")
        #expect(ElectText.congress(brown) == 119)
        #expect(ElectText.congress(.sample) == 120)
        let husted = Member(bioguideId: "TEST-HUSTED", firstName: "Jon", lastName: "Husted", party: "R", state: "OH", district: nil, chamber: .senate)
        #expect(SeatRow.rows(members: [husted], elect: [brown], pending: []) == [.member(husted, leavingOn: nil), .elect(brown)])
    }

    // MARK: Words

    @Test func calendarDaysDoNotShiftWithTheZone() {
        #expect(ElectText.day("2027-01-03", locale: us) == "Jan 3, 2027")
        #expect(ElectText.monthDay("2027-01-03", locale: us) == "Jan 3")
        #expect(ElectText.day("2027-01-03", locale: Locale(identifier: "en_GB")) == "3 Jan 2027")
        #expect(ElectText.day("not a day", locale: us) == nil)
    }

    /// Election day is the law's, not the call's: Nov 3, 2026 though the AP called it on Nov 4.
    @Test func electionDayAndCongress() {
        #expect(ElectText.electionDay(takesOffice: "2027-01-03") == "2026-11-03")
        #expect(ElectText.electionDay(takesOffice: "2025-01-03") == "2024-11-05")
        #expect(ElectText.electionDay(takesOffice: "2023-01-03") == "2022-11-08")
        #expect(ElectText.congress(takesOffice: "2027-01-03") == 120)
        #expect(ElectText.congress(takesOffice: "2025-01-03") == 119)
    }

    @Test func whoCalledIt() {
        #expect(ElectText.calledBy(MemberElect.sample.call) == "Race called by AP")
        #expect(ElectText.callLine(MemberElect.sample.call, locale: us)
            == "Race called by AP on Nov 4. Floor shows the call, it doesn't make one.")
        let clerk = ElectCall(by: "House Clerk", on: nil, sourceUrl: nil)
        #expect(ElectText.calledBy(clerk) == "Listed by the House Clerk")
        #expect(ElectText.callLine(clerk, locale: us) == "Listed by the House Clerk. Floor shows the list, it doesn't make one.")
    }

    /// A pending seat names the seat and never a person.
    @Test func pendingWords() {
        let runoff = ElectText.pending(.sample, locale: us)
        #expect(runoff.title == "Runoff Dec 12")
        #expect(runoff.body == "Louisiana's 5th District: no winner yet. This seat fills in when the race is decided.")
        var uncalled = PendingSeat.sample
        uncalled.status = .uncalled
        uncalled.chamber = .senate
        uncalled.district = nil
        #expect(ElectText.pending(uncalled, locale: us).title == "Race not called yet")
        #expect(ElectText.pending(uncalled, locale: us).body.hasPrefix("Louisiana's Senate seat: Floor waits for the call."))
    }
}
