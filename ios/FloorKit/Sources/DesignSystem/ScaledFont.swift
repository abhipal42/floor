import SwiftUI

public extension View {
    /// The system font at the mocks' point size, scaled with Dynamic Type.
    ///
    /// `.font(.system(size: 13))` is a fixed size: it ignores the reader's text-size setting
    /// entirely, which is how every screen shipped before v0.2.25. This draws the same 13pt at the
    /// default size (so the locked mocks are unchanged) and grows with the setting from there, in
    /// step with the text style nearest that size.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight))
    }
}

public extension Typography {
    /// The text style whose default size is nearest `size`, which is what a scaled font follows: a
    /// 9pt caption grows as `.caption2` does, not as `.body`, so small print does not overtake the
    /// headline it sits under.
    static func textStyle(forPointSize size: CGFloat) -> Font.TextStyle {
        // iOS's default (Large) sizes: caption2 11, caption 12, footnote 13, subheadline 15,
        // callout 16, body 17, title3 20, title2 22, title 28, largeTitle 34.
        switch size {
        case ..<11.5: .caption2
        case ..<12.5: .caption
        case ..<14: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<18.5: .body
        case ..<21: .title3
        case ..<25: .title2
        case ..<31: .title
        default: .largeTitle
        }
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Typography.textStyle(forPointSize: size))
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}
