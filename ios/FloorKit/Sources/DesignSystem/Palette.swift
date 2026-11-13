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

    // Added for the app-matches-landing round (2026-11-12). The colours above are unchanged; these
    // are the values the locked mocks use that the palette did not yet have.
    /// The line a vote had to cross, and the BOSS chip on a supermajority level.
    public static let threshold = Color(hex: 0xFACC15)
    /// Panels on the app screens: feed cards, box score, the deck's cards.
    public static let panel = Color(hex: 0x14161B)
    /// Hairline border on those panels.
    public static let panelBorder = Color(hex: 0x2A2E36)
    /// A raised grey: "did not vote" squares, the back cards of a stack, a level not reached.
    public static let raised = Color(hex: 0x3A3F49)
    /// The green the top of Home and Onboarding fades from.
    public static let groundGlow = Color(hex: 0x0F2A20)
    /// The split-flap board: its frame, and the top and bottom halves of each cell.
    public static let flapBoard = Color(hex: 0x0B0C0F)
    public static let flapTop = Color(hex: 0x1C1F25)
    public static let flapBottom = Color(hex: 0x121418)
    /// The broadcast scoreboard on the vote screen: alternating turf stripes and its border.
    public static let turf = Color(hex: 0x0E1A14)
    public static let turfAlt = Color(hex: 0x0B1611)
    public static let turfBorder = Color(hex: 0x1E2A23)
    /// The silver frame around a player card.
    public static let silver = [Color(hex: 0xE5E7EB), Color(hex: 0x6B7280), Color(hex: 0xC4C9D2)]
    // From the LocApp mock (onboarding with location, 2026-11-12).
    /// A warning banner — location off, outside the U.S., approximate — and its border. The title
    /// is set in ``nay``.
    public static let warningPanel = Color(hex: 0x1E1610)
    public static let warningBorder = Color(hex: 0x5A3A1E)
    /// The faintest text: the privacy line under onboarding's button.
    public static let textFaint = Color(hex: 0x6B7280)

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

/// Type from the canvas and the locked app mocks.
///
/// Scores, labels and headlines are Barlow Condensed, bundled in `Fonts/` and registered by
/// ``FloorFonts``. If registration fails, every display style falls back to the system's condensed
/// face at the same size and weight, so a missing font degrades the look but never the layout.
public enum Typography {
    /// The big scoreboard numbers. Fixed size, as before: a score scales down to fit its column
    /// with `minimumScaleFactor` rather than up with Dynamic Type.
    public static func score(_ size: CGFloat) -> Font {
        display(size, weight: .extraBold, scales: false)
    }

    /// Barlow Condensed at one of the bundled weights. `scales` ties it to Dynamic Type, relative
    /// to the body style; numbers that must fit a fixed column pass `false`.
    public static func display(_ size: CGFloat, weight: FloorFonts.Face = .extraBold, scales: Bool = true) -> Font {
        if FloorFonts.register() {
            return scales
                ? .custom(weight.postScriptName, size: size, relativeTo: .body)
                : .custom(weight.postScriptName, fixedSize: size)
        }
        var font = Font.system(size: size, weight: weight.fallbackWeight).width(.condensed)
        if weight.isItalic { font = font.italic() }
        return font
    }

    /// The italic 900 headlines: "PULL YOUR THREE.", "YOUR FINALS", a bill's title.
    public static func headline(_ size: CGFloat) -> Font { display(size, weight: .blackItalic) }

    /// 800 labels: "BOX SCORE", "YEA", a member's surname on a card.
    public static func label(_ size: CGFloat) -> Font { display(size, weight: .extraBold) }

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
