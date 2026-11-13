import Foundation
import Models
import SwiftUI

/// The one line a screen adds while any of it is saved data rather than fresh: "Saved 2 h ago ·
/// refreshing…" while the network pass runs, then "Offline · saved 2 h ago" or "Couldn't refresh ·
/// saved 2 h ago" if it fails. Gone once everything on screen is fresh.
///
/// Muted caption text and nothing else, so a screen built to a locked mock gains a line rather than
/// a banner. It re-reads the clock each minute so the age does not freeze while the screen is open.
public struct SavedDataNote: View {
    let saved: SavedCopy

    public init(_ saved: SavedCopy) {
        self.saved = saved
    }

    public var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.text(saved, now: context.date))
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
        }
    }

    public nonisolated static func text(_ saved: SavedCopy, now: Date) -> String {
        let age = age(of: saved.savedAt, now: now)
        return switch saved.status {
        case .refreshing: "Saved \(age) · refreshing…"
        case .offline: "Offline · saved \(age)"
        case .refreshFailed: "Couldn't refresh · saved \(age)"
        }
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
