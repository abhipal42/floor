import Models
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("Network marks")
struct NetworkMarkTests {
    /// Every mark draws something inside its 24 × 24 box, filling it one way (Facebook's "f" is narrow).
    @Test(arguments: SocialNetwork.allCases)
    func everyMarkFillsItsBox(_ network: SocialNetwork) {
        let box = NetworkMark.unit(network).boundingRect
        #expect(box.minX >= 1 && box.minY >= 1 && box.maxX <= 23 && box.maxY <= 23)
        #expect(max(box.width, box.height) >= 14 && min(box.width, box.height) >= 8)
    }

    /// The compact number forms the mock's paths use: `4.4.9` is two numbers, `1.4-1.4` two.
    @Test func parsesCompactNumbers() {
        let path = SVGPath.parse("M1 1h2.4.6v1.4-1.4z")
        let box = path.boundingRect
        #expect(abs(box.maxX - 4) < 0.001 && abs(box.maxY - 2.4) < 0.001 && box.minX == 1 && box.minY == 1)
    }

    /// Scaled into any rect, a mark stays square and centred.
    @Test func scalesIntoTheRect() {
        let box = NetworkMark(.youtube).path(in: CGRect(x: 0, y: 0, width: 48, height: 96)).boundingRect
        #expect(abs(box.midY - 48) < 0.5)
        #expect(abs(box.width - 40) < 0.5)
    }
}
