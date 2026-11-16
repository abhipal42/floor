#if os(iOS)
import Alerts
import APIClient
import BillScreen
import DesignSystem
import Home
import Models
import Onboarding
import RepScreen
import SnapshotTesting
import SwiftUI
import Testing
import VoteScreen

/// Round 11, <https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r>: the Week tab (A), vote explainers
/// (B), Contact and Speak up (C), the bill screen's banner and Share (C, D), the Alerts screen's bill
/// steps and iCloud row (E, F), and Money's Disclosures (G). Every screen is drawn from responses
/// captured on 2026-11-14: the House's real list for the week of Nov 16, H.R. 5267, the Austin
/// members' office contacts from congress-legislators, and Doggett's disclosures as the API serves
/// them with DISCLOSURES_ENABLED on.
@MainActor
@Suite("Round 11 snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct Round11SnapshotTests {
    init() { _ = NoPortraits.installed }

    private var delegation: Delegation {
        get throws { Delegation(reps: try austin(), resolvedAt: Date(timeIntervalSince1970: 0)) }
    }

    /// Monday, Nov 16, 2026, 9 a.m. in Washington.
    private static let monday = Formats.instant("2026-11-16T14:00:00.000Z")!

    // MARK: - A · Week

    /// You follow H.R. 9640 and the Labor and Employment topic (which takes in both bills under a rule).
    private func week(chamber: Chamber = .house, now: Date = monday) async -> some View {
        var state = FollowState()
        state.follow(.bill, "119-hr-9640")
        state.follow(topic: "Labor and Employment")
        let model = WeekModel(api: FixtureServer.api, follows: Follows(store: InMemoryFollowStore(state)), now: { now })
        model.chamber = chamber
        await model.load()
        return WeekView(model: model, onOpenBill: { _ in })
    }

    @Test func weekHouse() async throws {
        assertScreen(await week(), height: 1400)
    }

    @Test func weekSenate() async throws {
        assertScreen(await week(chamber: .senate), height: 900, [.light, .dark])
    }

    /// The week of Nov 23: no list posted, no Senate meeting named. Says why, never "recess".
    @Test func weekNothingPosted() async throws {
        let later = Formats.instant("2026-11-23T14:00:00.000Z")!
        assertScreen(await week(now: later), height: 600, [.light])
        assertScreen(await week(chamber: .senate, now: later), height: 500, [.dark], testName: "weekNothingPostedSenate")
    }

    // MARK: - B · Vote explainers

    @Test func voteExplainer() async throws {
        let senators = try delegation.senators
        let model = VoteScreenModel(voteId: "senate-119-2-253", memberIds: senators.map(\.bioguideId), api: FixtureServer.api, delegation: senators)
        await model.load()
        assertScreen(NavigationStack { VoteScreenView(model: model) }, height: 900)
    }

    @Test func voteKinds() throws {
        let kinds: VoteKindList = try fixture("vote-kinds")
        assertScreen(NavigationStack { VoteKindsView(kinds: kinds.kinds) }, height: 1400, [.light, .dark])
    }

    // MARK: - C · Contact and Speak up

    /// Doggett lists no form, so Write goes to the House-wide one.
    @Test func memberContact() async throws {
        let model = RepScreenModel(bioguideId: "D000399", api: FixtureServer.api)
        await model.load()
        assertScreen(NavigationStack { RepScreenView(model: model, section: .contact) }, height: 700)
    }

    /// H.R. 5267: the banner, and Speak up and Share under the summary.
    @Test func billOnTheFloor() async throws {
        let model = BillScreenModel(billId: "119-hr-5267", api: FixtureServer.api, members: try delegation.members, delegation: try delegation)
        await model.load()
        let view = NavigationStack {
            BillScreenView(model: model, follows: Follows(store: InMemoryFollowStore()), onOpenVote: { _ in })
        }
        assertScreen(view, height: 2500, [.light, .dark])
    }

    private func facts() throws -> BillFacts {
        let bill: Bill = try fixture("bill-hr5267")
        let schedule: Schedule = try fixture("schedule-2026-11-16")
        return BillFacts(bill: bill, listing: FloorListing(schedule: schedule, billId: bill.id))
    }

    private func contacts() throws -> [String: MemberContact] {
        var found: [String: MemberContact] = [:]
        for name in ["member-detail-doggett", "member-detail-cornyn", "member-detail-cruz"] {
            let detail: MemberDetail = try fixture(name)
            found[detail.member.bioguideId] = detail.contact
        }
        return found
    }

    /// As it opens: no view chosen, so no message yet.
    @Test func speakUpNothingChosen() throws {
        let sheet = SpeakUpSheet(facts: try facts(), delegation: try delegation, contact: { _ in nil }, onSetDistrict: nil, contacts: try contacts())
        assertScreen(sheet, height: 700, [.light, .dark])
    }

    /// The mock's state: Rep. Doggett, "How will you vote?".
    @Test func speakUpChosen() throws {
        let sheet = SpeakUpSheet(
            facts: try facts(), delegation: try delegation, contact: { _ in nil }, onSetDistrict: nil,
            initialStance: .howWillYouVote, contacts: try contacts()
        )
        assertScreen(sheet, height: 900)
    }

    @Test func speakUpNoDistrict() throws {
        let sheet = SpeakUpSheet(facts: try facts(), delegation: nil, contact: { _ in nil }, onSetDistrict: {})
        assertScreen(sheet, height: 500, [.light])
    }

    @Test func speakUpCallScript() throws {
        let sheet = SpeakUpSheet(
            facts: try facts(), delegation: try delegation, contact: { _ in nil }, onSetDistrict: nil,
            recipientId: "C001056", startCalling: true, contacts: try contacts()
        )
        assertScreen(sheet, height: 700, [.light, .dark])
    }

    // MARK: - E, F · Alerts and iCloud

    private func alerts(cloud: CloudSync?) throws -> some View {
        var state = FollowState()
        state.follow(bill: try #require((try fixture("search-hr1013", as: SearchResults.self)).bills.first))
        state.follow(topic: "Labor and Employment")
        state.follow(topic: "Health")
        let follows = Follows(store: InMemoryFollowStore(state))
        let reps = try austin().members
        return NavigationStack {
            AlertsView(model: AlertsModel(follows: follows, reps: reps, sync: nil, cloud: cloud))
        }
    }

    @Test func alertsBillSteps() throws {
        assertScreen(try alerts(cloud: nil), height: 1500)
    }

    /// This build has no iCloud entitlement: the visible placeholder.
    @Test func alertsICloudUnavailable() throws {
        let cloud = CloudSync(follows: Follows(store: InMemoryFollowStore()), delegations: InMemoryDelegationStore(), cloud: nil)
        assertScreen(try alerts(cloud: cloud).defaultScrollAnchor(.bottom), height: 600, [.light])
    }

    // MARK: - G · Disclosures

    @Test func disclosuresOn() async throws {
        let model = RepScreenModel(bioguideId: "D000399", api: FixtureServer.api)
        model.moneySegment = .disclosures
        await model.load()
        await model.disclosures.load()
        assertScreen(NavigationStack { RepScreenView(model: model, section: .money) }, height: 1700)
    }

    /// A handwritten report Floor's AI transcribed: the AI tag above the rows, the link below.
    @Test func disclosuresTranscribed() async throws {
        let model = RepScreenModel(bioguideId: "N000002", api: FixtureServer.api)
        model.moneySegment = .disclosures
        await model.load()
        await model.disclosures.load()
        assertScreen(NavigationStack { RepScreenView(model: model, section: .money) }, height: 800, [.light, .dark])
    }

    /// Off, as production serves it: the placeholder with the API's own reason.
    @Test func disclosuresOff() async throws {
        let model = RepScreenModel(bioguideId: "C001056", api: FixtureServer.api)
        model.moneySegment = .disclosures
        await model.load()
        await model.disclosures.load()
        assertScreen(NavigationStack { RepScreenView(model: model, section: .money) }, height: 700, [.light, .dark])
    }
}
#endif
