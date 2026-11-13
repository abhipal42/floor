import Models
import SwiftUI

// The small pieces every app screen in the locked mocks shares: the skewed chip, the threshold bar,
// the ring, member portraits and the panel surface.

public extension View {
    /// The mocks' card: #14161B, a 1pt #2A2E36 hairline, 16pt corners.
    func panel(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Palette.panelBorder, lineWidth: 1))
    }
}

public extension Palette {
    /// The colour a position is printed in.
    static func position(_ position: Position) -> Color {
        switch position {
        case .yea: yea
        case .nay: nay
        case .present, .notVoting: textMuted
        case .candidate: text
        }
    }

    /// Green when the question carried, orange when it did not, grey when it settled nothing.
    static func outcome(_ outcome: Vote.Outcome?) -> Color {
        switch outcome {
        case .carried: yea
        case .failed: nay
        case nil: textSecondary
        }
    }
}

/// The skewed label: a chamber tag, a result, FINAL, BOSS.
public struct SkewChip: View {
    let text: String
    let foreground: Color
    let background: Color
    let size: CGFloat

    public init(_ text: String, foreground: Color = Palette.ground, background: Color = Palette.text, size: CGFloat = 12) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.size = size
    }

    public var body: some View {
        Text(text)
            .font(Typography.display(size, weight: .extraBold, scales: false))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.1)
            .background(background)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.176, d: 1, tx: size * 0.1, ty: 0))
    }
}

/// The yea fill with the yellow line it had to cross.
public struct ThresholdBar: View {
    let line: ThresholdLine
    let height: CGFloat
    /// 0…1 of the yea fill to draw, so the deck can grow it as its numbers count up.
    let progress: Double

    public init(line: ThresholdLine, height: CGFloat = 6, progress: Double = 1) {
        self.line = line
        self.height = height
        self.progress = progress
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.panelBorder)
                UnevenRoundedRectangle(topLeadingRadius: height / 2, bottomLeadingRadius: height / 2)
                    .fill(Palette.yea)
                    .frame(width: width * line.yeaShare * progress)
                Rectangle()
                    .fill(Palette.threshold)
                    .frame(width: 2, height: height + 8)
                    .offset(x: min(width - 2, width * line.lineShare))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(line.yea) yea of \(line.cast) cast; the line is \(line.needed)")
    }
}

/// A progress ring; nil draws only the track, for a figure that does not exist.
public struct Ring<Content: View>: View {
    let share: Double?
    let color: Color
    let lineWidth: CGFloat
    let content: Content

    public init(share: Double?, color: Color = Palette.yea, lineWidth: CGFloat = 3, @ViewBuilder content: () -> Content) {
        self.share = share
        self.color = color
        self.lineWidth = lineWidth
        self.content = content()
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Palette.panelBorder, lineWidth: lineWidth)
            if let share {
                Circle()
                    .trim(from: 0, to: max(0, min(1, share)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            content
        }
    }
}

/// A member's official portrait, falling back to their initials on a party-tinted ground.
///
/// Portraits come from the `unitedstates/images` project, keyed by Bioguide ID. Its documented host
/// `theunitedstates.io` failed its TLS handshake when this was built (2026-11-12), so this reads the
/// same files from the project's GitHub Pages origin.
public struct MemberPortrait: View {
    let member: Member
    let cornerRadius: CGFloat?

    /// - Parameter cornerRadius: nil for a circle.
    public init(_ member: Member, cornerRadius: CGFloat? = nil) {
        self.member = member
        self.cornerRadius = cornerRadius
    }

    public static func url(_ bioguideId: String) -> URL? {
        URL(string: "https://unitedstates.github.io/images/congress/225x275/\(bioguideId).jpg")
    }

    public var body: some View {
        GeometryReader { geo in
            AsyncImage(url: Self.url(member.bioguideId)) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else {
                    initials(geo.size)
                }
            }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0)) } ?? AnyShape(Circle())
    }

    private func initials(_ size: CGSize) -> some View {
        let first = member.firstName.first.map(String.init) ?? ""
        let last = member.lastName.first.map(String.init) ?? ""
        return Text((first + last).uppercased())
            .font(.system(size: max(10, min(size.width, size.height) * 0.36), weight: .bold))
            .foregroundStyle(Palette.text)
            .frame(width: size.width, height: size.height)
            .background(Palette.partyTint(member.party))
    }
}

/// A number that counts up from zero when it appears, unless Reduce Motion is on.
public struct CountingNumber: View, Animatable {
    var value: Double

    public init(_ value: Double) { self.value = value }

    nonisolated public var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    public var body: some View {
        Text("\(Int(value.rounded()))")
    }
}
