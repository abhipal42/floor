import Models
import SwiftUI

/// A network's mark in one ink colour, from the round 13 polish mock's 24 × 24 symbols
/// (https://claude.ai/artifact/PZ2XWPfB2E9QXvF89YFEfo). Fill it with a single colour; the YouTube
/// play triangle is cut out, so it shows whatever is behind it. Mastodon's is Floor's own simple
/// bubble-and-"m", drawn in the same style.
public struct NetworkMark: Shape {
    public var network: SocialNetwork

    public init(_ network: SocialNetwork) {
        self.network = network
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        return Self.unit(network).applying(
            CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2).scaledBy(x: scale, y: scale)
        )
    }

    /// The mark in its 24 × 24 box, as one path to fill (strokes already outlined).
    static func unit(_ network: SocialNetwork) -> Path {
        switch network {
        case .x:
            SVGPath.parse("M17.8 3h3.1l-6.8 7.8L22 21h-6.2l-4.9-6.4L5.3 21H2.2l7.3-8.3L2 3h6.4l4.4 5.8L17.8 3zm-1.1 16.2h1.7L7.4 4.7H5.6l11.1 14.5z")
        case .facebook:
            SVGPath.parse("M13.5 21v-7.4h2.5l.4-2.9h-2.9V8.9c0-.8.2-1.4 1.4-1.4h1.5V4.9c-.3 0-1.2-.1-2.2-.1-2.2 0-3.7 1.3-3.7 3.8v2.1H8v2.9h2.5V21h3z")
        case .bluesky:
            SVGPath.parse("M5.9 4.1C8.2 5.8 10.7 9.3 12 11c1.3-1.7 3.8-5.2 6.1-6.9 1.7-1.2 4.4-2.2 4.4.9 0 .6-.4 5.1-.6 5.8-.7 2.6-3.3 3.2-5.6 2.8 4 .7 5 3 2.8 5.2-4.2 4.3-6-1.1-6.5-2.5l-.6-1.6-.6 1.6c-.5 1.4-2.3 6.8-6.5 2.5-2.2-2.2-1.2-4.5 2.8-5.2-2.3.4-4.9-.2-5.6-2.8-.2-.7-.6-5.2-.6-5.8 0-3.1 2.7-2.1 4.4-.9z")
        case .instagram:
            outlined(stroke: 1.9) { path in
                path.addRoundedRect(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17), cornerSize: CGSize(width: 5, height: 5))
                path.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
            } adding: { path in
                path.addEllipse(in: CGRect(x: 16, y: 5.6, width: 2.4, height: 2.4))
            }
        case .youtube:
            Path { path in
                path.addRoundedRect(in: CGRect(x: 2, y: 5, width: 20, height: 14), cornerSize: CGSize(width: 4.5, height: 4.5))
            }
            .subtracting(Path { path in
                path.move(to: CGPoint(x: 10, y: 9))
                path.addLine(to: CGPoint(x: 15.2, y: 12))
                path.addLine(to: CGPoint(x: 10, y: 15))
                path.closeSubpath()
            })
        case .mastodon:
            outlined(stroke: 1.9) { path in
                // The bubble, then the "m": two humps on three legs.
                path.addRoundedRect(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 14), cornerSize: CGSize(width: 5, height: 5))
                path.move(to: CGPoint(x: 8.5, y: 14))
                path.addLine(to: CGPoint(x: 8.5, y: 10.5))
                path.addCurve(to: CGPoint(x: 12, y: 10.5), control1: CGPoint(x: 8.5, y: 8.2), control2: CGPoint(x: 12, y: 8.2))
                path.addLine(to: CGPoint(x: 12, y: 13))
                path.move(to: CGPoint(x: 12, y: 10.5))
                path.addCurve(to: CGPoint(x: 15.5, y: 10.5), control1: CGPoint(x: 12, y: 8.2), control2: CGPoint(x: 15.5, y: 8.2))
                path.addLine(to: CGPoint(x: 15.5, y: 14))
            } adding: { path in
                // The tail, under the bubble's bottom-left.
                path.move(to: CGPoint(x: 6.5, y: 16.5))
                path.addLine(to: CGPoint(x: 6.5, y: 21))
                path.addLine(to: CGPoint(x: 11, y: 17))
                path.closeSubpath()
            }
        }
    }

    private static func outlined(stroke: CGFloat, _ lines: (inout Path) -> Void, adding fills: (inout Path) -> Void) -> Path {
        var stroked = Path()
        lines(&stroked)
        var path = stroked.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        var filled = Path()
        fills(&filled)
        path.addPath(filled)
        return path
    }
}

/// One account on the Posts tab's row: the network's mark in a circle and a green dot when Floor
/// shows its posts. No name under it: the marks are well known, and a caption only cluttered the row
/// (owner, 2026-11-17). The caller makes it a link and labels it, name included.
public struct NetworkBadge: View {
    let network: SocialNetwork

    public static let circle: CGFloat = 46
    public static let mark: CGFloat = 18
    public static let dot: CGFloat = 12

    public init(_ network: SocialNetwork) {
        self.network = network
    }

    public var body: some View {
        VStack(spacing: 0) {
            NetworkMark(network)
                .fill(Palette.text)
                .frame(width: Self.mark, height: Self.mark)
                .frame(width: Self.circle, height: Self.circle)
                .background(Palette.card, in: .circle)
                .overlay(Circle().strokeBorder(Palette.panelBorder, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if network.readable {
                        Circle().fill(Palette.yea)
                            .padding(2)
                            .background(Palette.ground, in: .circle)
                            .frame(width: Self.dot, height: Self.dot)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// Just enough SVG path data for the marks above: M L H V C and Z, absolute and relative, with
/// implicit repeats and the compact number forms (`4.4.9`, `1.4-1.4`).
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func flush() {
            let relative = command.isLowercase
            let step: Int
            switch command.uppercased() {
            case "M", "L": step = 2
            case "H", "V": step = 1
            case "C": step = 6
            default:
                path.closeSubpath()
                current = start
                numbers.removeAll()
                return
            }
            var i = 0
            var first = true
            while i + step <= numbers.count {
                let n = Array(numbers[i ..< i + step])
                let dx = relative ? current.x : 0, dy = relative ? current.y : 0
                switch command.uppercased() {
                case "M":
                    let p = CGPoint(x: n[0] + dx, y: n[1] + dy)
                    if first { path.move(to: p); start = p } else { path.addLine(to: p) }
                    current = p
                case "L":
                    current = CGPoint(x: n[0] + dx, y: n[1] + dy)
                    path.addLine(to: current)
                case "H":
                    current = CGPoint(x: n[0] + dx, y: current.y)
                    path.addLine(to: current)
                case "V":
                    current = CGPoint(x: current.x, y: n[0] + dy)
                    path.addLine(to: current)
                default:
                    let c1 = CGPoint(x: n[0] + dx, y: n[1] + dy), c2 = CGPoint(x: n[2] + dx, y: n[3] + dy)
                    current = CGPoint(x: n[4] + dx, y: n[5] + dy)
                    path.addCurve(to: current, control1: c1, control2: c2)
                }
                first = false
                i += step
            }
            numbers.removeAll()
        }

        var token = ""
        func endNumber() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        for char in data {
            if char.isLetter, char != "e" {
                endNumber()
                flush()
                command = char
            } else if char == "-" {
                endNumber()
                token = "-"
            } else if char == "." {
                if token.contains(".") { endNumber() }
                token.append(char)
            } else if char.isNumber {
                token.append(char)
            } else {
                endNumber()
            }
        }
        endNumber()
        flush()
        return path
    }
}
