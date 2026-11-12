import APIClient
import Foundation
import Models

/// One member: who they are, how often they side with their party, and their recent votes.
@MainActor
@Observable
public final class RepScreenModel {
    public struct Record: Equatable, Sendable {
        public var detail: MemberDetail
        public var votes: [MemberVote]
    }

    public enum Phase: Equatable {
        case loading
        case loaded(Record)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading

    private let bioguideId: String
    private let api: FloorAPI
    private let limit: Int

    public init(bioguideId: String, api: FloorAPI, limit: Int = 40) {
        self.bioguideId = bioguideId
        self.api = api
        self.limit = limit
    }

    public func load() async {
        phase = .loading
        do {
            // Two independent requests, so they go together rather than one after the other.
            async let detail = api.member(id: bioguideId)
            async let votes = api.memberVotes(id: bioguideId, limit: limit)
            phase = .loaded(Record(detail: try await detail, votes: try await votes.votes))
        } catch let error as FloorAPIError {
            phase = .failed(error.errorDescription ?? "Couldn't load this member.")
        } catch {
            phase = .failed("Couldn't load this member.")
        }
    }
}

public extension PartyLoyalty {
    /// Party unity as a whole percentage, or nil when there is nothing to report.
    ///
    /// nil for an independent: "their party's majority" is themselves, so the API leaves those
    /// votes uncounted rather than reporting a meaningless 100%. The screen must show nothing.
    var unityPercent: Int? {
        withPartyShare.map { Int(($0 * 100).rounded()) }
    }
}

public extension Member {
    /// "U.S. Representative · D-TX-37", as the canvas writes the eyebrow.
    var roleLine: String {
        let office = chamber == .house ? "U.S. Representative" : "U.S. Senator"
        return "\(office) · \(partyAndSeat)"
    }
}

public extension MemberVote {
    /// How to label this row in a record: the measure where there is one, else the question.
    var rowTitle: String {
        measure?.headline ?? vote.question
    }

    /// Whether the member sided with the outcome. nil when the vote settled nothing to side with,
    /// as a Speaker ballot that elected nobody does.
    var agreedWithOutcome: Bool? {
        guard vote.kind == .question, let leader = vote.leader else { return nil }
        switch position {
        case .yea: return leader == .yea
        case .nay: return leader == .nay
        default: return nil
        }
    }
}
