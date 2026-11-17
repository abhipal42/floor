import Models
import SwiftUI

/// A story band's small topic mark, one per ``TopicGroup``: shield, bars, columns, cross, leaf,
/// scales, capitol, dot. Drawn as paths on a 24-point grid (the mock's SVGs), not SF Symbols, so
/// Android's vector drawables can match them line for line.
public struct TopicIcon: Shape {
    public let group: TopicGroup

    public init(_ group: TopicGroup) {
        self.group = group
    }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { p.addRect(CGRect(x: x, y: y, width: w, height: h)) }
        func poly(_ points: [(CGFloat, CGFloat)]) {
            p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            p.closeSubpath()
        }
        switch group {
        case .defense:
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 4, y: 5))
            p.addLine(to: CGPoint(x: 4, y: 11))
            p.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 4, y: 16), control2: CGPoint(x: 7.4, y: 20.4))
            p.addCurve(to: CGPoint(x: 20, y: 11), control1: CGPoint(x: 16.6, y: 20.4), control2: CGPoint(x: 20, y: 16))
            p.addLine(to: CGPoint(x: 20, y: 5))
            p.closeSubpath()
        case .money:
            box(4, 20, 16, 2); box(6, 10, 2, 8); box(11, 6, 2, 12); box(16, 13, 2, 5)
        case .courts:
            poly([(12, 3), (3, 8), (21, 8)]); box(5, 10, 2, 8); box(11, 10, 2, 8); box(17, 10, 2, 8); box(3, 20, 18, 2)
        case .health:
            poly([(9, 3), (15, 3), (15, 9), (21, 9), (21, 15), (15, 15), (15, 21), (9, 21), (9, 15), (3, 15), (3, 9), (9, 9)])
        case .land:
            p.move(to: CGPoint(x: 20, y: 3))
            p.addCurve(to: CGPoint(x: 6, y: 18), control1: CGPoint(x: 10, y: 3), control2: CGPoint(x: 4, y: 9))
            p.addLine(to: CGPoint(x: 3.5, y: 20.5))
            p.addLine(to: CGPoint(x: 5, y: 22))
            p.addLine(to: CGPoint(x: 7.5, y: 19.5))
            p.addCurve(to: CGPoint(x: 20, y: 3), control1: CGPoint(x: 16, y: 22), control2: CGPoint(x: 21, y: 13))
            p.closeSubpath()
        case .rights:
            box(11, 3, 2, 16); box(7, 19, 10, 2); box(4, 7, 16, 2)
            poly([(5, 9), (2, 15), (8, 15)]); poly([(19, 9), (16, 15), (22, 15)])
        case .gov:
            p.move(to: CGPoint(x: 7, y: 8))
            p.addArc(center: CGPoint(x: 12, y: 8), radius: 5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.closeSubpath()
            box(6, 9, 12, 2); box(7, 12, 2, 6); box(11, 12, 2, 6); box(15, 12, 2, 6); box(4, 19, 16, 2)
        case .other:
            p.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
        }
        let scale = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
