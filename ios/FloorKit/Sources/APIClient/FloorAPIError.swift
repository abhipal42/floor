import Foundation
import Models

/// What can go wrong talking to the Floor API.
public enum FloorAPIError: Error, Sendable {
    /// The request never completed: offline, DNS, TLS, timeout.
    case transport(any Error)
    /// The server answered, but not with success. `message` is the API's own wording where it sent
    /// one, which is written for people — `/v1/reps` explains how to improve an address.
    case http(status: Int, message: String?)
    /// The body did not match the contract. A bug on one side or the other, not a user error.
    case decoding(any Error)

    /// True when the thing asked for does not exist, so a screen can show "not found" rather than
    /// an error.
    public var isNotFound: Bool {
        if case .http(404, _) = self { return true }
        return false
    }
}

extension FloorAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport:
            "Couldn't reach Floor. Check your connection and try again."
        case let .http(status, message):
            message ?? "Floor returned an unexpected response (HTTP \(status))."
        case .decoding:
            "Floor sent something this version of the app doesn't understand."
        }
    }
}
