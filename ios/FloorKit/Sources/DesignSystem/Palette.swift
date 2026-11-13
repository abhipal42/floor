import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One colour token with a value for each appearance.
///
/// The dark values are the v2 design canvas's own hexes ("Live Vote Tracker – UI Options") and the
/// locked app mocks'. The light values are direction D, "Marble & Patina", from the re-theme
/// proposal (https://claude.ai/artifact/AinA8SbyMWgrsC2rsB5U9h): a cool marble ground, white panels,
/// and outcome colours darkened until text in them reads at 4.5:1 or better on both.
public struct Swatch: Sendable, Equatable {
    public let light: UInt32
    public let dark: UInt32
    public let lightOpacity: Double
    public let darkOpacity: Double

    public init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.light = light
        self.dark = dark
        self.lightOpacity = lightOpacity
        self.darkOpacity = darkOpacity
    }

    /// WCAG 2 relative luminance of an sRGB hex.
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// WCAG 2 contrast ratio between two opaque colours, 1…21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// Every adaptive token, as data, so the tests can check contrast without drawing anything.
public enum Tones {
    // Ground and surfaces
    public static let ground = Swatch(light: 0xECEFEE, dark: 0x07080A)
    public static let card = Swatch(light: 0xFFFFFF, dark: 0x1E2128)
    public static let cardSunken = Swatch(light: 0xF1F4F3, dark: 0x15171C)
    public static let chip = Swatch(light: 0xE1E6E4, dark: 0x23262E)
    public static let track = Swatch(light: 0xD7DDDA, dark: 0x2A2E37)
    public static let cardBorder = Swatch(light: 0x111816, dark: 0xFFFFFF, lightOpacity: 0.08, darkOpacity: 0.06)

    // Text
    public static let text = Swatch(light: 0x111816, dark: 0xFFFFFF)
    public static let textSecondary = Swatch(light: 0x38433F, dark: 0xC9CED6)
    public static let textMuted = Swatch(light: 0x616D68, dark: 0x9BA1AD)
    public static let trailing = Swatch(light: 0x76817D, dark: 0x7E8592)

    // Vote outcomes
    public static let yea = Swatch(light: 0x0B7A57, dark: 0x34D399)
    public static let yeaBright = Swatch(light: 0x086146, dark: 0x6EE7B7)
    public static let nay = Swatch(light: 0xA8481A, dark: 0xFB923C)
    public static let nayBright = Swatch(light: 0x8C3B14, dark: 0xFDBA74)

    // State
    public static let live = Swatch(light: 0xC8281C, dark: 0xFF453A)
    public static let liveText = Swatch(light: 0xB42318, dark: 0xFF6B61)
    public static let scheduled = Swatch(light: 0x7D5800, dark: 0xFDE047)
    public static let accent = Swatch(light: 0x1C6F5B, dark: 0x34D399)
    public static let accentSoft = Swatch(light: 0x2E7D68, dark: 0xA7F3D0)

    // From the app-matches-landing round
    public static let threshold = Swatch(light: 0x8A6500, dark: 0xFACC15)
    public static let panel = Swatch(light: 0xFFFFFF, dark: 0x14161B)
    public static let panelBorder = Swatch(light: 0xD5DBD8, dark: 0x2A2E36)
    public static let raised = Swatch(light: 0xC3CAC7, dark: 0x3A3F49)
    public static let groundGlow = Swatch(light: 0xD3E3DD, dark: 0x0F2A20)
    public static let shadow = Swatch(light: 0x111816, dark: 0x000000, lightOpacity: 0.14, darkOpacity: 0.45)

    // Party
    public static func party(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0x2F5FD0, dark: 0x6EA8FE)
        case "R": Swatch(light: 0xB43636, dark: 0xF87171)
        default: Swatch(light: 0x616D68, dark: 0x9BA1AD)
        }
    }

    public static func partyTint(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0xDCE6FB, dark: 0x1E3A8A)
        case "R": Swatch(light: 0xFBE1DE, dark: 0x7F1D1D)
        default: Swatch(light: 0xE1E6E4, dark: 0x3F3F46)
        }
    }

    /// Text tokens that must read at 4.5:1 on the ground and on a panel, in both appearances.
    public static let textTokens: [(name: String, swatch: Swatch)] = [
        ("text", text), ("textSecondary", textSecondary), ("textMuted", textMuted),
        ("yea", yea), ("nay", nay), ("liveText", liveText), ("scheduled", scheduled),
        ("accent", accent), ("threshold", threshold),
        ("party D", party("D")), ("party R", party("R")), ("party I", party("I")),
    ]
}

/// The app's colours. Each one follows the system appearance: light is "Marble & Patina", dark is
/// the original canvas.
///
/// Two things are dark in both appearances because they are lit displays, not surfaces: the
/// split-flap board on Home and the turf scoreboard on a vote. They pin themselves with
/// `litObject()`, so every token inside them resolves to its dark value.
public enum Palette {
    // Ground and surfaces
    /// Page background, under the glow at the top of Home.
    public static let ground = Color(Tones.ground)
    /// Card background.
    public static let card = Color(Tones.card)
    /// A darker card used for nested panels.
    public static let cardSunken = Color(Tones.cardSunken)
    /// Chips and pills.
    public static let chip = Color(Tones.chip)
    /// Progress and divider tracks.
    public static let track = Color(Tones.track)
    /// Hairline border on cards.
    public static let cardBorder = Color(Tones.cardBorder)

    // Text
    public static let text = Color(Tones.text)
    /// Body text that is not the headline.
    public static let textSecondary = Color(Tones.textSecondary)
    /// Labels, metadata, captions.
    public static let textMuted = Color(Tones.textMuted)
    /// The losing side's score.
    public static let trailing = Color(Tones.trailing)

    // Vote outcomes
    public static let yea = Color(Tones.yea)
    public static let yeaBright = Color(Tones.yeaBright)
    public static let nay = Color(Tones.nay)
    public static let nayBright = Color(Tones.nayBright)

    // State
    /// A vote that is open right now.
    public static let live = Color(Tones.live)
    /// The same, for text.
    public static let liveText = Color(Tones.liveText)
    /// Something scheduled but not yet open.
    public static let scheduled = Color(Tones.scheduled)
    /// The accent used for links and the selected tab.
    public static let accent = Color(Tones.accent)
    /// Accent text on the Home header.
    public static let accentSoft = Color(Tones.accentSoft)

    /// The line a vote had to cross, and the BOSS chip on a supermajority level.
    public static let threshold = Color(Tones.threshold)
    /// Panels on the app screens: feed cards, box score, the deck's cards.
    public static let panel = Color(Tones.panel)
    /// Hairline border on those panels, and the empty part of a bar or ring.
    public static let panelBorder = Color(Tones.panelBorder)
    /// A raised grey: "did not vote" squares, the back cards of a stack, a level not reached.
    public static let raised = Color(Tones.raised)
    /// The tint the top of Home and Onboarding fades from: green in dark, patina in light.
    public static let groundGlow = Color(Tones.groundGlow)
    /// The drop shadow under the catch-up deck's front card.
    public static let shadow = Color(Tones.shadow)

    // Lit displays: the same in both appearances.
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
    /// Text on silver, which is light in both appearances.
    public static let silverInk = Color(hex: 0x07080A)

    // Party
    public static func party(_ party: String) -> Color { Color(Tones.party(party)) }

    /// The fill behind a member's initials.
    public static func partyTint(_ party: String) -> Color { Color(Tones.partyTint(party)) }
}

public extension View {
    /// Draws this view in the dark palette whatever the system appearance: for the split-flap
    /// board and the turf scoreboard, which are lit displays rather than surfaces.
    func litObject() -> some View {
        environment(\.colorScheme, .dark)
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
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A colour that resolves to the swatch's light or dark value from the current appearance,
    /// including an appearance pinned with `.environment(\.colorScheme, …)`.
    init(_ swatch: Swatch) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .floorSRGB(swatch.dark, swatch.darkOpacity)
                : .floorSRGB(swatch.light, swatch.lightOpacity)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .floorSRGB(swatch.dark, swatch.darkOpacity)
                : .floorSRGB(swatch.light, swatch.lightOpacity)
        })
        #else
        self.init(hex: swatch.dark, opacity: swatch.darkOpacity)
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    static func floorSRGB(_ hex: UInt32, _ alpha: Double) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    static func floorSRGB(_ hex: UInt32, _ alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif
