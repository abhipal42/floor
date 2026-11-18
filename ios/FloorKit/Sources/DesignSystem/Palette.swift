import Models
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

    /// `top` drawn at `opacity` over an opaque `bottom`, channel by channel: the colour a tinted
    /// surface actually is, so text on it can be contrast-tested.
    public static func mix(_ top: UInt32, over bottom: UInt32, opacity: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let a = Double((top >> shift) & 0xFF), b = Double((bottom >> shift) & 0xFF)
            out |= UInt32((a * opacity + b * (1 - opacity)).rounded()) << shift
        }
        return out
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

    // From the LocApp mock (onboarding with location). The dark panel and border are the mock's;
    // light mode gets a warm cream panel under the same amber edge. `textFaint` is lighter than
    // the mock's #6B7280, which reads at only 4.1:1 on the dark ground.
    public static let warningPanel = Swatch(light: 0xFBF0E6, dark: 0x1E1610)
    public static let warningBorder = Swatch(light: 0xE2B48E, dark: 0x5A3A1E)
    public static let textFaint = Swatch(light: 0x636E69, dark: 0x858B95)

    // From the AppRepMoney mock (the member's Money segment). `teal` and `dim` are bar fills, not
    // text. They are darker than the mock's #2DD4BF and #6B7280: the mock's teal sat at 1.2:1
    // against the small-dollar green beside it, and its grey under 3:1 on the empty track, so
    // neighbouring parts blurred into one. `PaletteTests` holds every pair in ``moneyBar``.
    // `ai` is the label colour of anything Floor writes with a model, and is text, so it is
    // contrast-tested.
    public static let teal = Swatch(light: 0x0B4A45, dark: 0x0F9488)
    public static let dim = Swatch(light: 0x3F4945, dark: 0x858B95)
    public static let ai = Swatch(light: 0x5B3FB5, dark: 0xC4B5FD)
    /// Text on an `ai` fill: the AI tag, an open citation chip. The live/AI mock's #1A1033 on the
    /// dark violet; white on the light one, which the dark ink would not read on.
    public static let aiInk = Swatch(light: 0xFFFFFF, dark: 0x1A1033)
    /// How strongly the AI card is washed with `ai` at its top, over the ground (the mock's
    /// `rgba(196,181,253,.08)`, fading to .02). Its text is tested against this, the strongest point:
    /// `textMuted` reads only 4.1:1 there in light, so the card uses `textSecondary`.
    public static let aiCardTint = 0.08

    /// The Money bar's four fills, left to right: small-dollar, larger gifts, PACs, transfers and
    /// other. Each must read at 1.5:1 against its neighbour and 3:1 against the empty track
    /// (`panelBorder`), in both appearances.
    public static let moneyBar: [Swatch] = [yea, teal, threshold, dim]

    // From the members-elect mock (round 12): anything about a member-elect. Dark is the mock's
    // #7DD3FC; light a deep sky blue that reads at 4.5:1 on the marble ground and on a panel. It is
    // text (the ELECT tag's outline variant, the banner title), so it is contrast-tested.
    public static let elect = Swatch(light: 0x0369A1, dark: 0x7DD3FC)
    /// Text on an `elect` fill: the ELECT tag. The mock's #07263A on the dark blue; white on the light.
    public static let electInk = Swatch(light: 0xFFFFFF, dark: 0x07263A)
    /// How strongly the takes-office banner is washed with `elect` (the mock's `rgba(125,211,252,.08)`).
    public static let electTint = 0.08

    // From the round 13 mock (campaign promises). `deckGlow` is the top of the promise deck's front
    // card, fading to `panel` (the mock's #23304A → #14161B); light is a pale steel blue that keeps
    // the eyebrow (`threshold`) and `textMuted` at 4.5:1. The browser frame around an archived
    // campaign page is a lit page, so it stays paper-coloured in both appearances, a shade warmer
    // in dark as the mock draws it; its stamp is the Wayback red.
    public static let deckGlow = Swatch(light: 0xEEF2F9, dark: 0x23304A)
    public static let paper = Swatch(light: 0xFBFAF6, dark: 0xF4F2EC)
    public static let paperInk = Swatch(light: 0x14161B, dark: 0x14161B)
    public static let paperText = Swatch(light: 0x3B3F47, dark: 0x3B3F47)
    public static let browserBar = Swatch(light: 0xD9DEDC, dark: 0x22252C)
    public static let browserField = Swatch(light: 0xF1F4F3, dark: 0x14161B)
    public static let browserText = Swatch(light: 0x38433F, dark: 0xC4C9D2)
    public static let wayback = Swatch(light: 0xB4232A, dark: 0xB4232A)

    // The home-screen widgets' ground: the widget mock's #0B0C0F in dark, a white panel in light.
    public static let widget = Swatch(light: 0xFFFFFF, dark: 0x0B0C0F)

    // The Finals feed's story cards (v0.2.57, locked option B, styled "Arena"). A story's band is
    // its topic family's colour (`TopicGroup`) with white text in both appearances, so every topic
    // colour holds 4.5:1 against white in both; `PaletteTests` checks it. Dark values are Arena's
    // (armed forces #2D5F86, money #8A6512, courts #5E3FA0, other #4A5560) and four more in the same
    // depth; light keeps the B mock's bands. The same values as Android's `Tones.topic*`.
    public static let topicDefense = Swatch(light: 0x3B6E8F, dark: 0x2D5F86)
    public static let topicMoney = Swatch(light: 0x7A5A12, dark: 0x8A6512)
    public static let topicCourts = Swatch(light: 0x6A4C9C, dark: 0x5E3FA0)
    public static let topicHealth = Swatch(light: 0xB0304A, dark: 0x962840)
    public static let topicLand = Swatch(light: 0x2F6B3A, dark: 0x285C32)
    public static let topicRights = Swatch(light: 0x1F6E73, dark: 0x1A5C60)
    public static let topicGov = Swatch(light: 0x8C3F5D, dark: 0x783550)
    public static let topicOther = Swatch(light: 0x5E6A66, dark: 0x4A5560)

    public static func topic(_ group: TopicGroup) -> Swatch {
        switch group {
        case .defense: topicDefense
        case .money: topicMoney
        case .courts: topicCourts
        case .health: topicHealth
        case .land: topicLand
        case .rights: topicRights
        case .gov: topicGov
        case .other: topicOther
        }
    }

    /// A topic family's colour as text on the ground: the Bills tab's section headers and the Week
    /// tab's fast-track numerals (v0.2.59). Light keeps the band colour; dark lifts it to 55% over
    /// white, which gives the mock's #8FB8DB-like defense and #E0B85A-like money, every family
    /// above 4.5:1 on the dark ground (`PaletteTests`). Android's `Tones.topicText` is the same rule.
    public static func topicText(_ group: TopicGroup) -> Swatch {
        let band = topic(group)
        return Swatch(light: band.light, dark: Swatch.mix(band.dark, over: 0xFFFFFF, opacity: 0.55))
    }

    /// The Week tab's chamber labels on a headliner (v0.2.59): `SENATE · IN DEBATE` in the mock's
    /// blue (the D party values), `HOUSE · FULL DEBATE` in the threshold gold.
    public static let chamberSenate = Swatch(light: 0x2F5FD0, dark: 0x6EA8FE)
    public static let chamberHouse = threshold

    /// The text on a band: white in both appearances, as Arena draws it.
    public static let bandText = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// The band's soft highlight at its top right, and its shade along the bottom.
    public static let bandHighlight = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.25, darkOpacity: 0.25)
    public static let bandShade = Swatch(light: 0x000000, dark: 0x000000, lightOpacity: 0.3, darkOpacity: 0.3)
    /// The verdict chip at the band's top right: near-white with near-black ink.
    public static let verdict = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.95, darkOpacity: 0.95)
    public static let verdictInk = Swatch(light: 0x0B0C0F, dark: 0x0B0C0F)
    /// A story card's hairline: brighter at the top left, fading out by 40% (Arena's
    /// `linear-gradient(160deg, white 18%, white 2% at 40%)`); in light, the hairline ink.
    public static let storyEdge = Swatch(light: 0x111816, dark: 0xFFFFFF, lightOpacity: 0.14, darkOpacity: 0.18)
    public static let storyEdgeFaint = Swatch(light: 0x111816, dark: 0xFFFFFF, lightOpacity: 0.06, darkOpacity: 0.02)
    /// The 1pt light along a story card's top edge, inside it.
    public static let storyInnerHighlight = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.06, darkOpacity: 0.06)
    /// A story card's soft drop shadow (Arena's `0 22px 40px -22px`).
    public static let storyShadow = Swatch(light: 0x111816, dark: 0x000000, lightOpacity: 0.22, darkOpacity: 0.9)

    // Arena app-wide (v0.2.58, https://claude.ai/artifact/HP3nZFoQ4jUppnjKsC1MfV, direction 1). Dark
    // values are the mock's `.d1` block; light keeps the same structure on the Marble palette:
    // white glass cards, the hairlines darkened, the same bands. The same values as Android's
    // `Tones` of the same names.
    /// A glass card's 1pt light inside its top edge (Arena's `inset 0 1px 0 rgba(255,255,255,.05)`).
    public static let cardHighlight = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0, darkOpacity: 0.05)
    /// A glass card's soft long drop shadow (Arena's `0 10px 20px -16px rgba(0,0,0,.8)`).
    public static let cardShadow = Swatch(light: 0x111816, dark: 0x000000, lightOpacity: 0.14, darkOpacity: 0.8)
    /// A post card's fill, top to bottom (Arena's `#181B22 → #13161B`).
    public static let postTop = Swatch(light: 0xFFFFFF, dark: 0x181B22)
    public static let postBottom = Swatch(light: 0xF4F7F6, dark: 0x13161B)
    /// The floating tab bar's panel, over a blur (Arena's `rgba(21,24,30,.82)`).
    public static let tabBar = Swatch(light: 0xFFFFFF, dark: 0x15181E, lightOpacity: 0.82, darkOpacity: 0.82)
    /// A promise card on the member page's rail, top to bottom (Arena's `#1F2530 → #14171D`).
    public static let promiseTop = Swatch(light: 0xE2E8F2, dark: 0x1F2530)
    public static let promiseBottom = Swatch(light: 0xFFFFFF, dark: 0x14171D)
    /// Text on a ``yea`` fill: the member page's call button (Arena's `#06231A` on the green).
    public static let callInk = Swatch(light: 0xFFFFFF, dark: 0x06231A)

    /// The member page's hero: a deep party gradient, top to bottom, with white text in both
    /// appearances (``bandText``), so both ends hold 4.5:1 against white; `PaletteTests` checks it.
    /// Dark is Arena's (`#1E3A8A → #0B1430` for a Democrat); light is a brighter blue of the same depth.
    public static func heroTop(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0x2F5FD0, dark: 0x1E3A8A)
        case "R": Swatch(light: 0xB43636, dark: 0x7F1D1D)
        default: Swatch(light: 0x5E6A66, dark: 0x3F4652)
        }
    }

    public static func heroBottom(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0x1A2F6E, dark: 0x0B1430)
        case "R": Swatch(light: 0x5C1616, dark: 0x2A0B0B)
        default: Swatch(light: 0x2B3230, dark: 0x14171C)
        }
    }

    /// The hero's radial light at its top right, in the party's colour.
    public static func heroLight(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0x8DB8FF, dark: 0x6EA8FE, lightOpacity: 0.5, darkOpacity: 0.5)
        case "R": Swatch(light: 0xFCA5A5, dark: 0xF87171, lightOpacity: 0.45, darkOpacity: 0.45)
        default: Swatch(light: 0xD1D5DB, dark: 0xC9CED6, lightOpacity: 0.35, darkOpacity: 0.3)
        }
    }

    /// The faint green light in the hero's bottom left.
    public static let heroGreen = Swatch(light: 0x34D399, dark: 0x34D399, lightOpacity: 0.18, darkOpacity: 0.18)
    /// A glass stat tile on the hero, and the hairline round it and the back button.
    public static let heroTile = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.12, darkOpacity: 0.12)
    public static let heroTileBorder = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.16, darkOpacity: 0.16)
    /// The ring round the portrait, and the portrait's drop shadow.
    public static let heroRing = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.2, darkOpacity: 0.2)
    public static let heroShadow = Swatch(light: 0x000000, dark: 0x000000, lightOpacity: 0.6, darkOpacity: 0.6)
    /// The streak strip's bars: Arena's own green and orange on the hero in both appearances, and
    /// translucent white for a call with no yea or nay.
    public static let streakYea = Swatch(light: 0x34D399, dark: 0x34D399)
    public static let streakNay = Swatch(light: 0xFB923C, dark: 0xFB923C)
    public static let streakOther = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.25, darkOpacity: 0.25)
    /// The play button over a video's thumbnail.
    public static let playScrim = Swatch(light: 0x000000, dark: 0x000000, lightOpacity: 0.55, darkOpacity: 0.55)
    public static let playRing = Swatch(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.7, darkOpacity: 0.7)

    /// The three networks Floor reads, in their own brand colours (the only brand colours allowed):
    /// the badge on a post's portrait.
    public static let bluesky = Swatch(light: 0x1185FE, dark: 0x1185FE)
    public static let youtube = Swatch(light: 0xFF0033, dark: 0xFF0033)
    public static let mastodon = Swatch(light: 0x6364FF, dark: 0x6364FF)

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

    /// Text on a ``partyTint`` fill: the "D-NY" chip on a post (Arena's `#BFD6FF` on `#1E3A8A`).
    public static func partyInk(_ party: String) -> Swatch {
        switch party {
        case "D": Swatch(light: 0x1E4AB0, dark: 0xBFD6FF)
        case "R": Swatch(light: 0x9B2C2C, dark: 0xFECACA)
        default: Swatch(light: 0x38433F, dark: 0xE4E4E7)
        }
    }

    /// Text tokens that must read at 4.5:1 on the ground and on a panel, in both appearances.
    public static let textTokens: [(name: String, swatch: Swatch)] = [
        ("text", text), ("textSecondary", textSecondary), ("textMuted", textMuted), ("textFaint", textFaint),
        ("yea", yea), ("nay", nay), ("liveText", liveText), ("scheduled", scheduled),
        ("accent", accent), ("threshold", threshold), ("ai", ai), ("elect", elect),
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
    /// A warning banner on onboarding — location off, outside the U.S., approximate — and its
    /// border. The title is set in ``nay``, the body in ``textSecondary``, a link in ``yea``.
    public static let warningPanel = Color(Tones.warningPanel)
    public static let warningBorder = Color(Tones.warningBorder)
    /// The faintest text: the privacy line under onboarding's button.
    public static let textFaint = Color(Tones.textFaint)
    /// The home-screen widgets' background.
    public static let widget = Color(Tones.widget)

    // The Finals feed's story cards: see `Tones.topic`.
    public static func topic(_ group: TopicGroup) -> Color { Color(Tones.topic(group)) }
    public static func topicText(_ group: TopicGroup) -> Color { Color(Tones.topicText(group)) }
    public static let chamberSenate = Color(Tones.chamberSenate)
    public static let chamberHouse = Color(Tones.chamberHouse)
    public static let bandText = Color(Tones.bandText)
    public static let bandHighlight = Color(Tones.bandHighlight)
    public static let bandShade = Color(Tones.bandShade)
    public static let verdict = Color(Tones.verdict)
    public static let verdictInk = Color(Tones.verdictInk)
    public static let storyEdge = Color(Tones.storyEdge)
    public static let storyEdgeFaint = Color(Tones.storyEdgeFaint)
    public static let storyInnerHighlight = Color(Tones.storyInnerHighlight)
    public static let storyShadow = Color(Tones.storyShadow)
    // Arena app-wide: see `Tones.cardHighlight` and after.
    public static let cardHighlight = Color(Tones.cardHighlight)
    public static let cardShadow = Color(Tones.cardShadow)
    public static let postTop = Color(Tones.postTop)
    public static let postBottom = Color(Tones.postBottom)
    public static let tabBar = Color(Tones.tabBar)
    public static let promiseTop = Color(Tones.promiseTop)
    public static let promiseBottom = Color(Tones.promiseBottom)
    public static let callInk = Color(Tones.callInk)
    public static func heroTop(_ party: String) -> Color { Color(Tones.heroTop(party)) }
    public static func heroBottom(_ party: String) -> Color { Color(Tones.heroBottom(party)) }
    public static func heroLight(_ party: String) -> Color { Color(Tones.heroLight(party)) }
    public static let heroGreen = Color(Tones.heroGreen)
    public static let heroTile = Color(Tones.heroTile)
    public static let heroTileBorder = Color(Tones.heroTileBorder)
    public static let heroRing = Color(Tones.heroRing)
    public static let heroShadow = Color(Tones.heroShadow)
    public static let streakYea = Color(Tones.streakYea)
    public static let streakNay = Color(Tones.streakNay)
    public static let streakOther = Color(Tones.streakOther)
    public static let playScrim = Color(Tones.playScrim)
    public static let playRing = Color(Tones.playRing)
    public static let bluesky = Color(Tones.bluesky)
    public static let youtube = Color(Tones.youtube)
    public static let mastodon = Color(Tones.mastodon)
    /// The top of the promise deck's front card; it fades to ``panel``.
    public static let deckGlow = Color(Tones.deckGlow)
    /// An archived campaign page inside its browser frame: the page, its headings, its text.
    public static let paper = Color(Tones.paper)
    public static let paperInk = Color(Tones.paperInk)
    public static let paperText = Color(Tones.paperText)
    /// The browser frame's bar, its address field and the address.
    public static let browserBar = Color(Tones.browserBar)
    public static let browserField = Color(Tones.browserField)
    public static let browserText = Color(Tones.browserText)
    /// The "Wayback" stamp on an archived page.
    public static let wayback = Color(Tones.wayback)

    // The Money segment's bar: small-dollar is ``yea``, PACs ``threshold``, and these two the rest.
    /// Larger, itemized individual gifts.
    public static let teal = Color(Tones.teal)
    /// Transfers, party money and other receipts.
    public static let dim = Color(Tones.dim)
    /// The "✦ FLOOR EXPLAINS · AI" label and the border of a card a model wrote.
    public static let ai = Color(Tones.ai)
    /// Text on an ``ai`` fill.
    public static let aiInk = Color(Tones.aiInk)
    /// A member-elect: the ring round their portrait, the ELECT tag, the takes-office banner.
    public static let elect = Color(Tones.elect)
    /// Text on an ``elect`` fill.
    public static let electInk = Color(Tones.electInk)

    // Lit displays: the same in both appearances.
    /// The split-flap board: its frame, and the top and bottom halves of each cell.
    public static let flapBoard = Color(hex: 0x0B0C0F)
    /// The broadcast scoreboard on the vote screen: alternating turf stripes and its border.
    public static let turf = Color(hex: 0x0E1A14)
    public static let turfAlt = Color(hex: 0x0B1611)
    public static let turfBorder = Color(hex: 0x1E2A23)
    /// The Live Activity's lock-screen panel (round 8's `rgba(10,11,14,.82)`), drawn at
    /// ``liveActivityOpacity`` over the wallpaper; and the Dynamic Island's black.
    public static let liveActivity = Color(hex: 0x0A0B0E)
    public static let liveActivityOpacity = 0.82
    public static let island = Color(hex: 0x000000)
    /// The silver frame around a player card.
    public static let silver = [Color(hex: 0xE5E7EB), Color(hex: 0x6B7280), Color(hex: 0xC4C9D2)]
    /// Text on silver, which is light in both appearances.
    public static let silverInk = Color(hex: 0x07080A)

    // Party
    public static func party(_ party: String) -> Color { Color(Tones.party(party)) }

    /// The fill behind a member's initials.
    public static func partyTint(_ party: String) -> Color { Color(Tones.partyTint(party)) }

    /// Text on ``partyTint(_:)``.
    public static func partyInk(_ party: String) -> Color { Color(Tones.partyInk(party)) }
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

    // The Finals feed's story cards (Arena): Barlow Condensed for the title, the verdict and the
    // scores, which scale with Dynamic Type.
    public static let storyTitle = display(26, weight: .extraBold)
    public static let verdict = display(12, weight: .blackItalic)
    public static let stepScore = display(17, weight: .blackItalic)
    public static let mainScore = display(25, weight: .blackItalic)
    public static let miniScore = display(19, weight: .blackItalic)
    public static let weekTitle = display(23, weight: .blackItalic)

    // Arena app-wide (v0.2.58): BlackItalic for headline numerals and screen titles, ExtraBold
    // uppercase for card titles. All scale with Dynamic Type.
    /// A screen's big title: "Posts" on Following.
    public static let pageTitle = display(36, weight: .blackItalic)
    /// The member page's name on the hero.
    public static let heroName = display(40, weight: .blackItalic)
    /// A section's title on the member page: "Votes", "Said", "Money".
    public static let blockTitle = display(23, weight: .blackItalic)
    /// A promise card's headline.
    public static let promiseTitle = display(19, weight: .extraBold)
    /// A money tile's figure.
    public static let tileNumber = display(30, weight: .blackItalic)
    /// The call button's phone number.
    public static let callNumber = display(22, weight: .blackItalic)

    /// The member page's and post card's system-font sizes, scaled with ``View/scaledFont(_:weight:)``.
    public enum Member {
        public static let eyebrow: CGFloat = 10
        public static let heroLine: CGFloat = 12.5
        public static let statLabel: CGFloat = 10.5
        public static let streakLabel: CGFloat = 10
        public static let chip: CGFloat = 12.5
        public static let link: CGFloat = 12.5
        public static let rowTitle: CGFloat = 13.5
        public static let rowLine: CGFloat = 11.5
        public static let rowSide: CGFloat = 10.5
        public static let promiseTopic: CGFloat = 9.5
        public static let promiseQuote: CGFloat = 12.5
        public static let tileLabel: CGFloat = 9.5
        public static let legend: CGFloat = 11.5
        public static let callLine: CGFloat = 12
        public static let note: CGFloat = 10.5
    }

    public enum Post {
        public static let name: CGFloat = 14.5
        public static let party: CGFloat = 10
        public static let handle: CGFloat = 12
        public static let body: CGFloat = 15
        public static let linkSite: CGFloat = 11
        public static let linkTitle: CGFloat = 13
        public static let thread: CGFloat = 11.5
        public static let dayRule: CGFloat = 10.5
        public static let filter: CGFloat = 12.5
    }

    /// The story card's system-font sizes, scaled with ``View/scaledFont(_:weight:)``.
    public enum Story {
        public static let topic: CGFloat = 10.5
        public static let citation: CGFloat = 12
        public static let what: CGFloat = 13.5
        public static let whatLabel: CGFloat = 9.5
        public static let step: CGFloat = 12.5
        public static let member: CGFloat = 12
        public static let miniTitle: CGFloat = 13.5
        public static let miniLine: CGFloat = 11.5
        public static let weekRange: CGFloat = 12
    }
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
