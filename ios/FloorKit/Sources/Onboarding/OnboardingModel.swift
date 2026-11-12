import APIClient
import Foundation
import Models

/// Drives the address lookup: type an address, see who it resolves to, confirm or try again.
///
/// The address lives only in ``address`` for as long as the screen is open. It is sent to
/// `/v1/reps` and nowhere else — not stored, not logged, not part of ``Delegation``.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Phase: Equatable {
        case editing
        case looking
        /// Resolved, waiting for the person to confirm it is right.
        case found(Reps)
        /// Something went wrong; the text is safe to show.
        case failed(String)
    }

    public var address: String = ""
    public private(set) var phase: Phase = .editing

    private let api: FloorAPI
    private let store: any DelegationStore
    private let now: @Sendable () -> Date

    public init(api: FloorAPI, store: any DelegationStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.store = store
        self.now = now
    }

    /// Enough to be worth sending. The API itself requires five characters and explains what it
    /// wants, so this only stops obviously-empty submissions.
    public var canLookUp: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 && phase != .looking
    }

    public func lookUp() async {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 5 else {
            phase = .failed("Enter a street address, city and state.")
            return
        }
        phase = .looking
        do {
            let reps = try await api.reps(address: query)
            guard !reps.members.isEmpty else {
                // A district with nobody in it means our member data is behind, not a bad address.
                phase = .failed("We found your district but not your representatives. Please try again shortly.")
                return
            }
            phase = .found(reps)
        } catch let error as FloorAPIError {
            // The API phrases its 4xx for people — a 404 here explains how to improve the address —
            // so show its wording and fall back to ours only for transport and decoding failures.
            phase = .failed(error.errorDescription ?? "Something went wrong. Please try again.")
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }

    /// Accepts the resolved delegation and stores it. Returns what was saved, or nil if there is
    /// nothing to confirm yet.
    @discardableResult
    public func confirm() -> Delegation? {
        guard case let .found(reps) = phase else { return nil }
        let delegation = Delegation(reps: reps, resolvedAt: now())
        store.save(delegation)
        return delegation
    }

    /// Go back to the field to correct the address, keeping what was typed.
    public func edit() {
        phase = .editing
    }
}
