import SwiftUI

/// The colours from the v2 design canvas ("Live Vote Tracker – UI Options").
///
/// The app is dark-only for now, as the canvas is; every artboard is drawn on the same near-black
/// ground. Values are the canvas's own hexes rather than system colours so the app matches the
/// designs exactly.
public enum Palette {
    // Ground and surfaces
    /// Page background, under the green gradient on Home.
    public static let ground = Color(hex: 0x07080A)
    /// Card background. The canvas draws it at 94% over the ground.
    public static let card = Color(hex: 0x1E2128)
    /// A darker card used for nested panels.
    public static let cardSunken = Color(hex: 0x15171C)
    /// Chips and pills.
    public static let chip = Color(hex: 0x23262E)
    /// Progress and divider tracks.
    public static let track = Color(hex: 0x2A2E37)
    /// Hairline border on cards.
    public static let cardBorder = Color.white.opacity(0.06)

    // Text
    public static let text = Color.white
    /// Body text that is not the headline.
    public static let textSecondary = Color(hex: 0xC9CED6)
    /// Labels, metadata, captions.
    public static let textMuted = Color(hex: 0x9BA1AD)
    /// The losing side's score.
    public static let trailing = Color(hex: 0x7E8592)

    // Vote outcomes
    public static let yea = Color(hex: 0x34D399)
    public static let yeaBright = Color(hex: 0x6EE7B7)
    public static let nay = Color(hex: 0xFB923C)
    public static let nayBright = Color(hex: 0xFDBA74)

    // State
    /// A vote that is open right now.
    public static let live = Color(hex: 0xFF453A)
    /// The same, softened for text.
    public static let liveText = Color(hex: 0xFF6B61)
    /// Something scheduled but not yet open.
    public static let scheduled = Color(hex: 0xFDE047)
    /// The accent used for links and the selected tab.
    public static let accent = Color(hex: 0x34D399)
    /// Mint text on the Home header.
    public static let accentSoft = Color(hex: 0xA7F3D0)

    // Party
    public static func party(_ party: String) -> Color {
        switch party {
        case "D": Color(hex: 0x6EA8FE)
        case "R": Color(hex: 0xF87171)
        default: Color(hex: 0x9BA1AD)
        }
    }

    /// The deeper fill behind a member's initials.
    public static func partyTint(_ party: String) -> Color {
        switch party {
        case "D": Color(hex: 0x1E3A8A)
        case "R": Color(hex: 0x7F1D1D)
        default: Color(hex: 0x3F3F46)
        }
    }
}

/// Type from the canvas. Scores are set in Barlow Condensed there; until that font is bundled,
/// ``score`` falls back to the system's condensed rounded face at the same sizes.
public enum Typography {
    /// The big scoreboard numbers: 50pt on a live card, 44pt on a final one.
    public static func score(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).width(.condensed)
    }

    /// Section headings: "Live on the Floor", "Your delegation".
    public static let sectionTitle = Font.system(size: 17, weight: .bold)
    /// A card's measure title.
    public static let cardTitle = Font.system(size: 14, weight: .semibold)
    /// The all-caps chamber label above a card, tracked out.
    public static let eyebrow = Font.system(size: 11, weight: .bold)
    public static let body = Font.system(size: 13)
    public static let caption = Font.system(size: 12)
}

public extension Color {
    /// `Color(hex: 0x34D399)`, so the canvas's values can be pasted in as written.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
