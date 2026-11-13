import Testing
@testable import DesignSystem

@Suite("Palette in light and dark")
struct PaletteTests {
    /// The surfaces text is set on: the page ground, a panel and a card.
    private static let surfaces: [(name: String, swatch: Swatch)] = [
        ("ground", Tones.ground), ("panel", Tones.panel), ("card", Tones.card),
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

    /// Chips print the ground colour on an outcome or state colour, so those must read in light
    /// mode too. (In dark mode the ground is near-black on a bright fill, which always reads.)
    @Test func groundReadsOnAChip() {
        let chips: [(String, Swatch)] = [
            ("yea", Tones.yea), ("nay", Tones.nay), ("liveText", Tones.liveText),
            ("scheduled", Tones.scheduled), ("threshold", Tones.threshold),
        ]
        for (name, chip) in chips {
            let light = Swatch.contrast(Tones.ground.light, chip.light)
            #expect(light >= 4.5, "ground on \(name), light: \(light)")
        }
    }

    /// The losing score is large display type, so it needs the 3:1 large-text minimum.
    @Test func trailingScoreReadsAsLargeText() {
        #expect(Swatch.contrast(Tones.trailing.light, Tones.panel.light) >= 3)
        #expect(Swatch.contrast(Tones.trailing.light, Tones.ground.light) >= 3)
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
