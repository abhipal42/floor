import SwiftUI
import Testing
@testable import DesignSystem

/// Which text style each of the mocks' point sizes grows with.
@Suite("Scaled fonts")
struct ScaledFontTests {
    @Test func eachMockSizeFollowsTheNearestTextStyle() {
        let expected: [(CGFloat, Font.TextStyle)] = [
            (9, .caption2), (10, .caption2), (11, .caption2), (12, .caption), (13, .footnote),
            (14, .subheadline), (15, .subheadline), (16, .callout), (17, .body), (20, .title3),
            (22, .title2), (28, .title), (34, .largeTitle),
        ]
        for (size, style) in expected {
            #expect(Typography.textStyle(forPointSize: size) == style, "\(size)pt")
        }
    }

    @Test func arrivalAnimationsPlayUnlessTurnedOff() {
        #expect(EnvironmentValues().playsArrivalAnimations)
    }
}
