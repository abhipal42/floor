import APIClient
import Foundation
import Models

/// Loads one vote with its breakdown and your delegation's own positions.
@MainActor
@Observable
public final class VoteScreenModel {
    public enum Phase: Equatable {
        case loading
        case loaded(VoteDetail)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading

    private let voteId: String
    private let memberIds: [String]
    private let api: FloorAPI

    /// - Parameter memberIds: your delegation, asked for in the same request so the screen loads in
    ///   one round trip rather than one per member.
    public init(voteId: String, memberIds: [String], api: FloorAPI) {
        self.voteId = voteId
        self.memberIds = memberIds
        self.api = api
    }

    public func load() async {
        phase = .loading
        do {
            // The API caps ?members= at ten; a delegation is three, but a caller could hold more.
            phase = .loaded(try await api.vote(id: voteId, members: Array(memberIds.prefix(10))))
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load this vote.")
        } catch {
            phase = .failed("Couldn't load this vote.")
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
}
