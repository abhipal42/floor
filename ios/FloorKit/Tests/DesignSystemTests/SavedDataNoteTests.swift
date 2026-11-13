import Foundation
import Models
import Testing
@testable import DesignSystem

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private let noon = date("2026-11-12T12:00:00Z")

@Suite("Saved data note")
struct SavedDataNoteTests {
    /// While the network pass runs, saved data must not pass for fresh.
    @Test func saysItIsRefreshing() {
        let saved = SavedCopy(savedAt: date("2026-11-12T10:00:00Z"), status: .refreshing)
        #expect(SavedDataNote.text(saved, now: noon) == "Saved 2 h ago · refreshing…")
    }

    @Test func saysOfflineAndHowOld() {
        let saved = SavedCopy(savedAt: date("2026-11-12T10:00:00Z"), status: .offline)
        #expect(SavedDataNote.text(saved, now: noon) == "Offline · saved 2 h ago")
    }

    @Test func saysCouldNotRefreshWhenTheServerAnswered() {
        let saved = SavedCopy(savedAt: date("2026-11-12T11:48:00Z"), status: .refreshFailed)
        #expect(SavedDataNote.text(saved, now: noon) == "Couldn't refresh · saved 12 min ago")
    }

    /// Rounded down, so it never claims the data is newer than it is: 1 h 59 min is "1 h".
    @Test func roundsAgesDown() {
        #expect(SavedDataNote.age(of: date("2026-11-12T11:59:30Z"), now: noon) == "just now")
        #expect(SavedDataNote.age(of: date("2026-11-12T10:01:00Z"), now: noon) == "1 h ago")
        #expect(SavedDataNote.age(of: date("2026-11-09T11:00:00Z"), now: noon) == "3 d ago")
    }
}
