import Foundation
import Testing
@testable import DesignSystem

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Suite("Saved data note")
struct SavedDataNoteTests {
    @Test func saysOfflineAndHowOld() {
        let text = SavedDataNote.text(
            savedAt: date("2026-11-12T10:00:00Z"), offline: true, now: date("2026-11-12T12:00:00Z")
        )
        #expect(text == "Offline · saved 2 h ago")
    }

    @Test func saysCouldNotRefreshWhenTheServerAnswered() {
        let text = SavedDataNote.text(
            savedAt: date("2026-11-12T11:48:00Z"), offline: false, now: date("2026-11-12T12:00:00Z")
        )
        #expect(text == "Couldn't refresh · saved 12 min ago")
    }

    /// Rounded down, so it never claims the data is newer than it is: 1 h 59 min is "1 h".
    @Test func roundsAgesDown() {
        let now = date("2026-11-12T12:00:00Z")
        #expect(SavedDataNote.age(of: date("2026-11-12T11:59:30Z"), now: now) == "just now")
        #expect(SavedDataNote.age(of: date("2026-11-12T10:01:00Z"), now: now) == "1 h ago")
        #expect(SavedDataNote.age(of: date("2026-11-09T11:00:00Z"), now: now) == "3 d ago")
    }
}
