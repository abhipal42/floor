import Foundation

/// Some of what a screen shows is a saved response rather than a fresh one, and why.
///
/// Here rather than in `APIClient` so the design system can draw it without depending on
/// networking: it is a plain value, set by `revalidate` and read by `SavedDataNote`.
public struct SavedCopy: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The saved data is on screen and the network pass is still running.
        case refreshing
        /// The refresh never reached the server.
        case offline
        /// The server answered, but with an error.
        case refreshFailed
    }

    /// When the oldest saved response on screen was fetched.
    public var savedAt: Date
    public var status: Status

    public init(savedAt: Date, status: Status) {
        self.savedAt = savedAt
        self.status = status
    }
}
