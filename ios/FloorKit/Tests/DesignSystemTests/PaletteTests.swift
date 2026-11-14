import Testing
@testable import DesignSystem

@Suite("Palette in light and dark")
struct PaletteTests {
    /// The surfaces text is set on: the page ground, a panel, a card and a home-screen widget.
    private static let surfaces: [(name: String, swatch: Swatch)] = [
        ("ground", Tones.ground), ("panel", Tones.panel), ("card", Tones.card), ("widget", Tones.widget),
    ]

    @Test func contrastMatchesTheWCAGReferencePoints() {
        #expect(abs(Swatch.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(Swatch.contrast(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(Swatch.contrast(0x123456, 0x123456) == 1)
    }

    /// Every token that text is printed in reads at 4.5:1 on every surface, in both appearances.
    @Test func textTokensReadOnEverySurface() {
        for token in Tones.textTokens {
            for surface in Self.surfaces {
                let light = Swatch.contrast(token.swatch.light, surface.swatch.light)
                let dark = Swatch.contrast(token.swatch.dark, surface.swatch.dark)
                #expect(light >= 4.5, "\(token.name) on \(surface.name), light: \(light)")
                #expect(dark >= 4.5, "\(token.name) on \(surface.name), dark: \(dark)")
            }
        }
    }

    /// The Money bar's parts are told apart by colour alone: each must stand off its neighbour at
    /// 1.5:1 and off the empty track at 3:1 (WCAG's non-text minimum), in both appearances.
    @Test func moneyBarPartsStandApart() {
        let bar = Tones.moneyBar
        #expect(bar.count == 4)
        for (a, b) in zip(bar, bar.dropFirst()) {
            let light = Swatch.contrast(a.light, b.light)
            let dark = Swatch.contrast(a.dark, b.dark)
            #expect(light >= 1.5, "neighbours \(a.light) / \(b.light), light: \(light)")
            #expect(dark >= 1.5, "neighbours \(a.dark) / \(b.dark), dark: \(dark)")
        }
        for fill in bar {
            let light = Swatch.contrast(fill.light, Tones.panelBorder.light)
            let dark = Swatch.contrast(fill.dark, Tones.panelBorder.dark)
            #expect(light >= 3, "\(fill.light) on the track, light: \(light)")
            #expect(dark >= 3, "\(fill.dark) on the track, dark: \(dark)")
        }
        // The pair the review caught: the mock's small-dollar green beside its teal, 1.2:1.
        #expect(Swatch.contrast(0x34D399, 0x2DD4BF) < 1.5)
    }

    /// Chips print the ground colour on an outcome or state colour, so those must read in light
    /// mode too. (In dark mode the ground is near-black on a bright fill, which always reads.)
    @Test func groundReadsOnAChip() {
        let chips: [(String, Swatch)] = [
            ("yea", Tones.yea), ("nay", Tones.nay), ("liveText", Tones.liveText),
            ("scheduled", Tones.scheduled), ("threshold", Tones.threshold),
            // The widgets' DNV and PRESENT chips, and a Speaker candidate's chip.
            ("textMuted", Tones.textMuted), ("text", Tones.text),
        ]
        for (name, chip) in chips {
            let light = Swatch.contrast(Tones.ground.light, chip.light)
            #expect(light >= 4.5, "ground on \(name), light: \(light)")
            let dark = Swatch.contrast(Tones.ground.dark, chip.dark)
            #expect(dark >= 4.5, "ground on \(name), dark: \(dark)")
        }
    }

    /// Onboarding's warning banner prints its title in nay, its body in textSecondary and "Open
    /// Settings ›" in yea, on its own panel; the privacy line is textFaint on the ground.
    @Test func warningBannerTextReadsOnItsPanel() {
        let inks: [(String, Swatch)] = [
            ("nay", Tones.nay), ("textSecondary", Tones.textSecondary), ("yea", Tones.yea),
            ("textFaint", Tones.textFaint),
        ]
        for (name, ink) in inks {
            let light = Swatch.contrast(ink.light, Tones.warningPanel.light)
            let dark = Swatch.contrast(ink.dark, Tones.warningPanel.dark)
            #expect(light >= 4.5, "\(name) on warningPanel, light: \(light)")
            #expect(dark >= 4.5, "\(name) on warningPanel, dark: \(dark)")
        }
        // A light surface in light mode, the mock's own values in dark.
        #expect(Swatch.luminance(Tones.warningPanel.light) > 0.7)
        #expect(Tones.warningPanel.dark == 0x1E1610)
        #expect(Tones.warningBorder.dark == 0x5A3A1E)
    }

    /// The losing score is large display type, so it needs the 3:1 large-text minimum.
    @Test func trailingScoreReadsAsLargeText() {
        #expect(Swatch.contrast(Tones.trailing.light, Tones.panel.light) >= 3)
        #expect(Swatch.contrast(Tones.trailing.light, Tones.ground.light) >= 3)
    }

    /// The AI tag and an open citation chip print `aiInk` on an `ai` fill, in both appearances.
    @Test func aiTagTextReadsOnTheAIFill() {
        #expect(Swatch.contrast(Tones.aiInk.light, Tones.ai.light) >= 4.5)
        #expect(Swatch.contrast(Tones.aiInk.dark, Tones.ai.dark) >= 4.5)
    }

    /// The AI card is the ground washed with `ai`. Every text token drawn on it must read at 4.5:1
    /// at the strongest wash, in both appearances — and `textMuted`, which the first build used for
    /// the disclaimer and headings, must be shown not to, so this can fail.
    @Test func aiCardTextReadsOnItsTint() {
        for (name, pick) in [("light", { (s: Swatch) in s.light }), ("dark", { (s: Swatch) in s.dark })] {
            let tint = Swatch.mix(pick(Tones.ai), over: pick(Tones.ground), opacity: Tones.aiCardTint)
            for (token, swatch) in [("text", Tones.text), ("textSecondary", Tones.textSecondary), ("ai", Tones.ai)] {
                #expect(Swatch.contrast(pick(swatch), tint) >= 4.5, "\(token) on the AI card, \(name)")
            }
        }
        let lightTint = Swatch.mix(Tones.ai.light, over: Tones.ground.light, opacity: Tones.aiCardTint)
        #expect(Swatch.contrast(Tones.textMuted.light, lightTint) < 4.5)
    }

    @Test func mixCompositesChannelByChannel() {
        #expect(Swatch.mix(0xFFFFFF, over: 0x000000, opacity: 0.5) == 0x808080)
        #expect(Swatch.mix(0x5B3FB5, over: 0xECEFEE, opacity: 0) == 0xECEFEE)
        #expect(Swatch.mix(0x5B3FB5, over: 0xECEFEE, opacity: 1) == 0x5B3FB5)
    }

    /// Light mode is a real light theme: the ground and panels are light, text is dark.
    @Test func lightValuesAreLightAndDarkValuesAreDark() {
        for surface in Self.surfaces {
            #expect(Swatch.luminance(surface.swatch.light) > 0.7, "\(surface.name) light")
            #expect(Swatch.luminance(surface.swatch.dark) < 0.05, "\(surface.name) dark")
        }
        #expect(Swatch.luminance(Tones.text.light) < 0.02)
    }

    /// Yea and nay never take party colours, in either appearance.
    @Test func outcomesAreNotPartyColours() {
        for party in ["D", "R"] {
            for outcome in [Tones.yea, Tones.nay] {
                #expect(outcome.light != Tones.party(party).light)
                #expect(outcome.dark != Tones.party(party).dark)
            }
        }
    }

    /// The dark palette is the one the locked mocks were drawn in; light mode must not move it.
    @Test func darkValuesAreTheCanvasValues() {
        #expect(Tones.ground.dark == 0x07080A)
        #expect(Tones.panel.dark == 0x14161B)
        #expect(Tones.text.dark == 0xFFFFFF)
        #expect(Tones.yea.dark == 0x34D399)
        #expect(Tones.nay.dark == 0xFB923C)
        #expect(Tones.threshold.dark == 0xFACC15)
        #expect(Tones.accent.dark == 0x34D399)
    }
}
