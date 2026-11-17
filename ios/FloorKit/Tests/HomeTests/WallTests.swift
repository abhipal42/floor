import Foundation
@testable import Home
import Models
import Testing

/// Following's Posts wall: who gets a dashed note, and why.
@Suite("Posts wall")
struct WallTests {
    private let schumer = Member(bioguideId: "S000148", firstName: "Chuck", lastName: "Schumer", party: "D", state: "NY",
                                 district: nil, chamber: .senate)
    private let nadler = Member(bioguideId: "N000002", firstName: "Jerrold", lastName: "Nadler", party: "D", state: "NY",
                                district: 12, chamber: .house)

    private func wall() throws -> PostsWall {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        let data = try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/posts-wall-schumer-nadler.json"))
        return try JSONDecoder().decode(PostsWall.self, from: data)
    }

    /// Nadler is readable (he has a YouTube channel) with nothing lately: "no recent posts", not
    /// "only on X". Schumer posted, so he gets no note.
    @Test func aReadableMemberWithNothingLatelyGetsTheRecentNote() throws {
        let notes = WallText.notes(members: [schumer, nadler], wall: try wall())
        #expect(notes.map(\.member.lastName) == ["Nadler"])
        #expect(notes.first?.title == "No recent posts from Nadler")
    }

    @Test func anUnreadableMemberIsSaidPlainly() {
        let notes = WallText.notes(members: [nadler], wall: PostsWall(posts: [], unreadable: ["N000002"]))
        #expect(notes.first?.title == "Nadler posts only on X, Facebook or Instagram")
        #expect(notes.first?.body.contains("Contact tab") == true)
    }

    @Test func notesKeepYourOrder() {
        let notes = WallText.notes(members: [nadler, schumer], wall: .none)
        #expect(notes.map(\.member.lastName) == ["Nadler", "Schumer"])
    }
}
