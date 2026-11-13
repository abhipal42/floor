import APIClient
import BillScreen
import Foundation
import Models

/// Loads one vote with its breakdown and your delegation's own positions, then the bill it was on.
@MainActor
@Observable
public final class VoteScreenModel {
    public enum Phase: Equatable {
        case loading
        case loaded(VoteDetail)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// The bill this vote was on, loaded after the vote so the screen never waits on it. nil for a
    /// nomination, a procedural vote, or a bill that failed to load — the card then shows no level.
    public private(set) var bill: Bill?
    /// Set while any of the vote on screen (or its bill) is saved rather than fresh; see `revalidate`.
    public private(set) var saved: SavedCopy?
    /// Bumped by each load, so a load that has been overtaken drops its results.
    private var generation = 0
    /// Which party's squares the full roll shows.
    public var rollParty: String?

    private let voteId: String
    private let memberIds: [String]
    /// Your whole delegation, so the screen can say which of them this chamber leaves out.
    public let delegation: [Member]
    private let api: FloorAPI

    /// - Parameters:
    ///   - memberIds: your delegation, asked for in the same request so the screen loads in one
    ///     round trip rather than one per member.
    ///   - delegation: the same members in full, for the note about who sits in the other chamber.
    public init(voteId: String, memberIds: [String], api: FloorAPI, delegation: [Member] = []) {
        self.voteId = voteId
        self.memberIds = memberIds
        self.api = api
        self.delegation = delegation
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
        // A vote already on screen stays there while it refreshes, rather than flashing a spinner.
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        do {
            // Saved vote and bill first, then the network; see `revalidate`.
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [voteId, memberIds] pass in
                // The API caps ?members= at ten; a delegation is three, but a caller could hold more.
                let detail = try await pass.api.vote(id: voteId, members: Array(memberIds.prefix(10)))
                guard mine == generation else { throw CancellationError() }
                phase = .loaded(detail)
                if rollParty == nil { rollParty = detail.rollParties.first?.party }
                // A bill that fails to refresh falls back to the saved one, and the note says so.
                if let measure = detail.measure, measure.kind == .bill {
                    let billId = measure.id
                    if let found = await pass.bestEffort({ try await $0.bill(id: billId) }) {
                        guard mine == generation else { throw CancellationError() }
                        bill = found
                    }
                }
            }
        } catch is CancellationError {
            // Overtaken or cancelled: nothing to say, and `needsRefresh` still holds.
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load this vote.")
        }
    }
}

public extension VoteDetail {
    /// Party rows worth drawing: a party that cast no vote at all on this roll call is noise.
    var significantParties: [PartyTotals] {
        partyTotals.filter { $0.voting + $0.notVoting > 0 }
    }

    /// "D 201 · R 11" for one side of the scoreboard, as the canvas writes it.
    func partySplit(_ side: VotePositionSide) -> String {
        significantParties
            .map { "\($0.party) \(side == .yea ? $0.yea : $0.nay)" }
            .joined(separator: " · ")
    }

    /// How many more votes the winning side needed, or nil once the threshold is met.
    var votesShortOfThreshold: Int? {
        let needed = vote.votesNeeded
        let ahead = max(vote.totals.yea, vote.totals.nay)
        return ahead >= needed ? nil : needed - ahead
    }

    /// Candidate totals grouped by candidate, strongest first, for a Speaker election.
    var candidatesByStrength: [(candidate: String, total: Int, parties: [CandidateTotal])] {
        Dictionary(grouping: candidateTotals, by: \.candidate)
            .map { (candidate: $0.key, total: $0.value.reduce(0) { $0 + $1.total }, parties: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// The box score's rows, majority party first: the larger party on this roll call leads.
    var boxScore: [PartyTotals] {
        significantParties.sorted { ($0.voting + $0.notVoting, $0.party) > ($1.voting + $1.notVoting, $1.party) }
    }

    /// Whether the box score needs a PRES column. Most roll calls have nobody voting present.
    var anyPresent: Bool { partyTotals.contains { $0.present > 0 } }

    /// Parties for the full roll's tabs, Democrats first as the mock has it.
    var rollParties: [PartyTotals] {
        let order = ["D": 0, "R": 1, "I": 2]
        return significantParties.sorted { (order[$0.party] ?? 9, $0.party) < (order[$1.party] ?? 9, $1.party) }
    }

    /// Everyone on the roll, the sum of every party row.
    var rollCount: Int { significantParties.reduce(0) { $0 + $1.voting + $1.notVoting } }

    /// One sentence under the box score about who crossed party lines, computed from the counts.
    ///
    /// Only the two major parties are read: an independent's "party" is themselves (lesson 15), so
    /// they can neither cross it nor be crossed. nil for a Speaker election, or when a party split
    /// evenly and has no side to cross from.
    var crossoverSentence: String? {
        guard vote.kind == .question,
              let dems = partyTotals.first(where: { $0.party == "D" && $0.yea + $0.nay > 0 }),
              let reps = partyTotals.first(where: { $0.party == "R" && $0.yea + $0.nay > 0 }),
              dems.yea != dems.nay, reps.yea != reps.nay
        else { return nil }
        let demSide: VotePositionSide = dems.yea > dems.nay ? .yea : .nay
        let repSide: VotePositionSide = reps.yea > reps.nay ? .yea : .nay
        let demCross = demSide == .yea ? dems.nay : dems.yea
        let repCross = repSide == .yea ? reps.nay : reps.yea

        if demSide == repSide {
            if demCross == 0 && repCross == 0 { return "Every Democrat and every Republican voting voted \(demSide.rawValue)." }
            return "Most of both parties voted \(demSide.rawValue): Democrats \(dems.yea)–\(dems.nay), Republicans \(reps.yea)–\(reps.nay)."
        }
        switch (demCross, repCross) {
        case (0, 0):
            return "A party-line vote: no Democrat or Republican crossed."
        case let (0, n):
            return "\(n) \(PartyName.of("R", count: n)) crossed to join a unanimous Democratic side."
        case let (n, 0):
            return "\(n) \(PartyName.of("D", count: n)) crossed to join a unanimous Republican side."
        case let (d, r):
            return "\(d) \(PartyName.of("D", count: d)) and \(r) \(PartyName.of("R", count: r)) crossed party lines."
        }
    }

    /// "with 128 of 211 Democrats": how many of the member's own party took the same side, out of
    /// those in it who voted yea or nay. nil when they did not vote yea or nay, or for a party with
    /// no row.
    func withParty(_ position: MemberPosition) -> String? {
        guard position.position == .yea || position.position == .nay,
              let party = partyTotals.first(where: { $0.party == position.member.party })
        else { return nil }
        let same = position.position == .yea ? party.yea : party.nay
        let sided = party.yea + party.nay
        guard sided > 1 else { return nil }
        return "with \(same) of \(sided) \(PartyName.plural(party.party))"
    }

    /// Your members who are not on this roll call because they sit in the other chamber, and the
    /// sentence that says so: "Cornyn and Cruz vote in the Senate — this was a House vote."
    func otherChamberNote(delegation: [Member]) -> (members: [Member], text: String)? {
        let absent = delegation.filter { $0.chamber != vote.chamber }
        guard !absent.isEmpty, let chamber = absent.first?.chamber else { return nil }
        let names = absent.map(\.lastName)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let verb = absent.count == 1 ? "votes" : "vote"
        return (absent, "\(list) \(verb) in the \(chamber.name) — this was a \(vote.chamber.name) vote.")
    }
}

public extension PartyTotals {
    /// One square per member on the roll: yea, then nay, present, did not vote.
    var squares: [Position] {
        Array(repeating: .yea, count: yea) + Array(repeating: .nay, count: nay)
            + Array(repeating: .present, count: present) + Array(repeating: .notVoting, count: notVoting)
    }
}
