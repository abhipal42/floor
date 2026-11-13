import APIClient
import Foundation
import Models

/// Loads one bill, then how your own members voted on it.
@MainActor
@Observable
public final class BillScreenModel {
    public enum Phase: Equatable {
        case loading
        case loaded(Bill)
        case failed(String)
    }

    /// One of your members against this bill: their position on its latest vote in their chamber,
    /// or no vote at all when that chamber has not voted on it.
    public struct MemberOnBill: Equatable, Sendable, Identifiable {
        public var member: Member
        public var vote: Vote?
        public var position: Position?
        public var choice: String?
        public var id: String { member.bioguideId }
    }

    public private(set) var phase: Phase = .loading
    public private(set) var yourMembers: [MemberOnBill] = []

    private let billId: String
    private let members: [Member]
    private let api: FloorAPI

    /// - Parameter members: your delegation, for "Your three on this bill". Empty skips it.
    public init(billId: String, api: FloorAPI, members: [Member] = []) {
        self.billId = billId
        self.api = api
        self.members = members
    }

    public func load() async {
        phase = .loading
        do {
            let bill = try await api.bill(id: billId)
            phase = .loaded(bill)
            await loadYourMembers(bill)
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load this bill.")
        } catch {
            phase = .failed("Couldn't load this bill.")
        }
    }

    /// At most one request per chamber: the latest vote there, asking for your members' positions.
    private func loadYourMembers(_ bill: Bill) async {
        guard !members.isEmpty else { return }
        let latest = Self.latestVotes(bill)
        var positions: [String: MemberPosition] = [:]
        for vote in latest.values {
            let ids = members.filter { $0.chamber == vote.chamber }.map(\.bioguideId)
            guard !ids.isEmpty, let detail = try? await api.vote(id: vote.id, members: ids) else { continue }
            for position in detail.positions { positions[position.member.bioguideId] = position }
        }
        yourMembers = members.map { member in
            let found = positions[member.bioguideId]
            return MemberOnBill(
                member: member, vote: latest[member.chamber], position: found?.position, choice: found?.choice
            )
        }
    }

    /// The most recent vote in each chamber. The API lists a bill's votes newest first.
    nonisolated static func latestVotes(_ bill: Bill) -> [Chamber: Vote] {
        var latest: [Chamber: Vote] = [:]
        for vote in bill.votes where latest[vote.chamber] == nil { latest[vote.chamber] = vote }
        return latest
    }
}

public extension Vote {
    /// A key play, as the Bill screen lists it: `Senate cloture, 60 needed — 3 short`.
    var playDescription: String {
        let need: String = switch threshold {
        case .majority: "majority needed"
        case .twoThirds: "two-thirds needed"
        case .threeFifthsSworn: "60 needed"
        }
        var text = "\(chamber.name) \(questionKind.lowercased()), \(need)"
        if outcome == .failed, let short = line?.short { text += " — \(short) short" }
        return text
    }
}

public extension Member {
    /// `Rep. Gabe Evans (R-CO-8)`, `Sen. Ted Cruz (R-TX)`, `Del. Eleanor Norton (D-DC)`.
    var sponsorLine: String {
        let prefix = switch title {
        case "Senator": "Sen."
        case "Delegate": "Del."
        case "Resident Commissioner": "Res. Comm."
        default: "Rep."
        }
        return "\(prefix) \(fullName) (\(partyAndSeat))"
    }
}
