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
    /// Set while any of the bill on screen (or your members' positions) is saved rather than fresh;
    /// see `revalidate`.
    public private(set) var saved: SavedCopy?
    /// Bumped by each load, so a load that has been overtaken drops its results.
    private var generation = 0

    private let billId: String
    private let members: [Member]
    private let api: FloorAPI

    /// - Parameter members: your delegation, for "Your three on this bill". Empty skips it.
    public init(billId: String, api: FloorAPI, members: [Member] = []) {
        self.billId = billId
        self.api = api
        self.members = members
    }

    /// True until a load has finished with everything fresh — including one that was cancelled
    /// part-way — so a screen that reappears runs the refresh again.
    public var needsRefresh: Bool {
        if case .loaded = phase { return saved != nil }
        return true
    }

    public func load() async {
        generation += 1
        let mine = generation
        // A bill already on screen stays there while it refreshes, rather than flashing a spinner.
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        do {
            // Saved bill and positions first, then the network; see `revalidate`.
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [billId] pass in
                let bill = try await pass.api.bill(id: billId)
                guard mine == generation else { throw CancellationError() }
                phase = .loaded(bill)
                try await loadYourMembers(bill, pass: pass, generation: mine)
            }
        } catch is CancellationError {
            // Overtaken or cancelled: nothing to say, and `needsRefresh` still holds.
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load this bill.")
        }
    }

    /// At most one request per chamber: the latest vote there, asking for your members' positions.
    ///
    /// Best-effort: a chamber whose vote fails to refresh falls back to its saved positions, and the
    /// screen's note says part of it is saved.
    private func loadYourMembers(_ bill: Bill, pass: Pass, generation mine: Int) async throws {
        guard !members.isEmpty else { return }
        let latest = Self.latestVotes(bill)
        var positions: [String: MemberPosition] = [:]
        for vote in latest.values {
            let ids = members.filter { $0.chamber == vote.chamber }.map(\.bioguideId)
            guard !ids.isEmpty else { continue }
            let voteId = vote.id
            if let detail = await pass.bestEffort({ try await $0.vote(id: voteId, members: ids) }) {
                for position in detail.positions { positions[position.member.bioguideId] = position }
            }
        }
        guard mine == generation else { throw CancellationError() }
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
    /// `Rep. Gabe Evans (R-CO-8)`, `Sen. Ted Cruz (R-TX)`.
    var sponsorLine: String {
        "\(chamber == .house ? "Rep." : "Sen.") \(fullName) (\(partyAndSeat))"
    }
}
