import SwiftUI

/// The Capitol mark from the design's `#cham` symbol (viewBox 100 × 92): two roof sweeps, five
/// columns, and the steps. Drawn by the widgets, the Live Activity and the Dynamic Island; it was
/// the widget extension's own until the Live Activity needed it too (v0.2.30).
public struct ChamberGlyph: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100, sy = rect.height / 92
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        // Each sweep: a curve one way, a short edge, a curve back.
        let sweeps: [[CGFloat]] = [
            [8, 6, 50, 18, 92, 9, 95, 17, 50, 27, 5, 15],
            [3, 20, 50, 31, 97, 22, 98, 28, 50, 38, 2, 26],
            [3, 64, 50, 52, 98, 60, 98, 66, 50, 58, 3, 71],
            [8, 77, 50, 64, 92, 71, 92, 77, 50, 70, 12, 84],
            [26, 89, 55, 76, 92, 82, 92, 87, 58, 82, 32, 92],
        ]
        for s in sweeps {
            path.move(to: p(s[0], s[1]))
            path.addQuadCurve(to: p(s[4], s[5]), control: p(s[2], s[3]))
            path.addLine(to: p(s[6], s[7]))
            path.addQuadCurve(to: p(s[10], s[11]), control: p(s[8], s[9]))
            path.closeSubpath()
        }
        for (x, y, h) in [(8.0, 33.0, 26.0), (28, 35, 24), (47, 36, 23), (66, 35, 24), (85, 33, 26)] {
            path.addRect(CGRect(x: rect.minX + x * sx, y: rect.minY + y * sy, width: 8 * sx, height: h * sy))
        }
        return path
    }
}

/// The glyph on its dark tile, as the widgets and the Live Activity head themselves.
public struct ChamberTile: View {
    var size: CGFloat

    public init(size: CGFloat = 16) {
        self.size = size
    }

    public var body: some View {
        ChamberGlyph()
            .fill(Color.white)
            .frame(width: size * 0.75, height: size * 0.69)
            .frame(width: size, height: size)
            .background(Palette.flapBoard, in: .rect(cornerRadius: size * 0.26))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
