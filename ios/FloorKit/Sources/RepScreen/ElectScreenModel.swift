import APIClient
import Foundation
import Models

/// One member-elect's profile: `/v1/members-elect/{id}`, saved for offline like a member's record.
@MainActor
@Observable
public final class ElectScreenModel {
    public enum Phase: Equatable {
        case loading
        case loaded(ElectProfile)
        /// The API's 404: unknown, or they have taken office and are an ordinary member now.
        case noLongerListed
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var saved: SavedCopy?
    /// Money's Funding · Disclosures switch, kept here so leaving the tab keeps your place.
    public var moneySegment: MoneySegment = .funding
    private var generation = 0

    public let id: String
    private let api: FloorAPI

    public init(id: String, api: FloorAPI) {
        self.id = id
        self.api = api
    }

    public var needsRefresh: Bool {
        switch phase {
        case .loaded, .noLongerListed: saved != nil
        default: true
        }
    }

    public func load() async {
        generation += 1
        let mine = generation
        switch phase {
        case .loaded, .noLongerListed: break
        default:
            phase = .loading
            saved = nil
        }
        do {
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [id] pass in
                let found = try await pass.api.memberElect(id: id)
                guard mine == generation else { throw CancellationError() }
                phase = found.map(Phase.loaded) ?? .noLongerListed
            }
        } catch is CancellationError {
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load this member-elect.")
        }
    }
}
