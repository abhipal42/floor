import Foundation
import SwiftUI

/// The one line a screen adds when it is showing saved data because a refresh failed:
/// "Offline · saved 2 h ago".
///
/// Muted caption text and nothing else, so a screen built to a locked mock gains a line rather than
/// a banner. It re-reads the clock each minute so the age does not freeze while the screen is open.
public struct SavedDataNote: View {
    let savedAt: Date
    let offline: Bool

    /// - Parameter offline: true when the refresh never reached the server; false when the server
    ///   answered with an error, which "Offline" would misdescribe.
    public init(savedAt: Date, offline: Bool) {
        self.savedAt = savedAt
        self.offline = offline
    }

    public var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.text(savedAt: savedAt, offline: offline, now: context.date))
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
        }
    }

    public nonisolated static func text(savedAt: Date, offline: Bool, now: Date) -> String {
        "\(offline ? "Offline" : "Couldn't refresh") · saved \(age(of: savedAt, now: now))"
    }

    /// "just now", "12 min ago", "2 h ago", "3 d ago". Whole units, rounded down, so it never
    /// claims the data is newer than it is.
    nonisolated static func age(of date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case 0: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<(60 * 24): return "\(minutes / 60) h ago"
        default: return "\(minutes / (60 * 24)) d ago"
        }
    }
}
