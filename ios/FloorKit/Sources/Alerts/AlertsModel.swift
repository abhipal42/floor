import Foundation
import Models
import Observation
import Onboarding

/// The Alerts screen (round 9, section C, "Alerts", of https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre,
/// with round 8's two pushes): a "How they voted" switch per member — on for your reps, off for
/// members you follow — one per followed bill (off), and "A vote opened" (off).
///
/// Every switch is saved in ``Follows`` (the App Group record) at once; ``AlertSync`` sends the
/// result to the API. Turning a switch **on** is the only thing that asks for notification
/// permission — the defaults never do.
@MainActor
@Observable
public final class AlertsModel {
    public struct MemberRow: Identifiable, Hashable {
        public var member: Member
        /// `Your rep`, `Your senator`, `Your delegate`, `Following`.
        public var caption: String
        public var on: Bool
        public var id: String { member.bioguideId }
    }

    public struct BillRow: Identifiable, Hashable {
        public var id: String
        /// `H.R. 1013`.
        public var citation: String
        /// The bill's plain label, when its row is saved.
        public var label: String?
        public var on: Bool
    }

    /// What, if anything, stands between the switches and an alert.
    public enum Notice: Hashable {
        /// Something is on and Floor has never asked.
        case askPermission
        /// Something is on and notifications are off for Floor in Settings.
        case permissionDenied
    }

    public let follows: Follows
    public let reps: [Member]
    public let sync: AlertSync?

    public init(follows: Follows, reps: [Member], sync: AlertSync?) {
        self.follows = follows
        self.reps = reps
        self.sync = sync
    }

    private var state: FollowState { follows.state }

    /// Your reps (not hidden), then everyone you follow: "your members" everywhere.
    public var members: [MemberRow] {
        let repIds = Set(reps.map(\.bioguideId))
        return state.yourMembers(reps: reps).map { member in
            let isRep = repIds.contains(member.bioguideId)
            return MemberRow(
                member: member, caption: isRep ? Self.repCaption(member) : "Following",
                on: state.alertsOn(member: member.bioguideId, isRep: isRep)
            )
        }
    }

    public var bills: [BillRow] {
        state.entries(.bill).map { entry in
            BillRow(
                id: entry.id, citation: entry.bill?.citation ?? Self.citation(billId: entry.id),
                label: entry.bill?.label, on: state.alertsOn(bill: entry.id)
            )
        }
    }

    public var voteOpened: Bool { state.voteOpened }

    /// Topics are followed but never alerted on; the screen says so when you follow any.
    public var followsTopics: Bool { !state.followedTopics.isEmpty }

    public var isEmpty: Bool { members.isEmpty && bills.isEmpty }

    public var notice: Notice? {
        guard let sync, state.anyAlertOn(members: state.yourMembers(reps: reps), reps: reps) else { return nil }
        switch sync.permission {
        case .notDetermined: return .askPermission
        case .denied: return .permissionDenied
        case .allowed: return nil
        }
    }

    /// `Your rep`, `Your senator`, `Your delegate`, `Your resident commissioner`.
    nonisolated static func repCaption(_ member: Member) -> String {
        member.chamber == .house && !member.isDelegate ? "Your rep" : "Your \(member.title.lowercased())"
    }

    /// `119-hr-1013` → `H.R. 1013`, for a followed bill with no saved row.
    nonisolated static func citation(billId: String) -> String {
        let parts = billId.split(separator: "-")
        guard parts.count == 3, let number = Int(parts[2]) else { return billId }
        let labels = [
            "hr": "H.R.", "s": "S.", "hres": "H.Res.", "sres": "S.Res.", "hjres": "H.J.Res.", "sjres": "S.J.Res.",
            "hconres": "H.Con.Res.", "sconres": "S.Con.Res.",
        ]
        return "\(labels[String(parts[1])] ?? parts[1].uppercased()) \(number)"
    }

    public func setMember(_ id: String, _ on: Bool) async {
        follows.update { $0.setAlerts(member: id, on) }
        await changed(on)
    }

    public func setBill(_ id: String, _ on: Bool) async {
        follows.update { $0.setAlerts(bill: id, on) }
        await changed(on)
    }

    public func setVoteOpened(_ on: Bool) async {
        follows.update { $0.setVoteOpened(on) }
        await changed(on)
    }

    /// The notice's button: ask now.
    public func allow() async {
        await sync?.askIfNeeded()
    }

    /// Reads the permission again: on appear, and coming back from Settings.
    public func refresh() async {
        await sync?.refreshPermission()
        sync?.schedule()
    }

    private func changed(_ turnedOn: Bool) async {
        if turnedOn { await sync?.askIfNeeded() } else { sync?.schedule() }
    }
}
