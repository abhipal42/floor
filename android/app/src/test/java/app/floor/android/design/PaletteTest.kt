package app.floor.android.design

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same contrast floor the iOS `PaletteTests` hold the tokens to. */
class PaletteTest {
    private val surfaces = listOf(
        "ground" to Tones.ground, "panel" to Tones.panel, "card" to Tones.card, "widget" to Tones.widget,
    )

    @Test
    fun contrastMatchesTheWcagReferencePoints() {
        assertEquals(21.0, Swatch.contrast(0x000000, 0xFFFFFF), 0.01)
        assertEquals(4.48, Swatch.contrast(0x777777, 0xFFFFFF), 0.01)
        assertEquals(1.0, Swatch.contrast(0x123456, 0x123456), 0.0)
    }

    @Test
    fun textTokensReadOnEverySurface() {
        for ((name, token) in Tones.textTokens) {
            for ((surfaceName, surface) in surfaces) {
                val light = Swatch.contrast(token.light, surface.light)
                val dark = Swatch.contrast(token.dark, surface.dark)
                assertTrue("$name on $surfaceName, light: $light", light >= 4.5)
                assertTrue("$name on $surfaceName, dark: $dark", dark >= 4.5)
            }
        }
    }

    /** A story band's text is white in both appearances, so every topic colour must carry it. */
    @Test
    fun whiteReadsOnEveryTopicBand() {
        for (group in app.floor.android.model.TopicGroup.entries) {
            val band = Tones.topic(group)
            val light = Swatch.contrast(Tones.BAND_INK, band.light)
            val dark = Swatch.contrast(Tones.BAND_INK, band.dark)
            assertTrue("white on $group, light: $light", light >= 4.5)
            assertTrue("white on $group, dark: $dark", dark >= 4.5)
        }
    }

    /** The member hero's text is white in both appearances, over both ends of its party gradient. */
    @Test
    fun whiteReadsOnEveryHero() {
        for (party in listOf("D", "R", "I")) {
            for ((end, swatch) in listOf("top" to Tones.heroTop(party), "bottom" to Tones.heroBottom(party))) {
                val light = Swatch.contrast(0xFFFFFF, swatch.light)
                val dark = Swatch.contrast(0xFFFFFF, swatch.dark)
                assertTrue("white on hero $party $end, light: $light", light >= 4.5)
                assertTrue("white on hero $party $end, dark: $dark", dark >= 4.5)
            }
        }
    }

    /** A post's party chip, "D-NY", prints the party ink on the party tint. */
    @Test
    fun partyInkReadsOnItsTint() {
        for (party in listOf("D", "R", "I")) {
            val ink = Tones.partyInk(party)
            val tint = Tones.partyTint(party)
            assertTrue("party ink $party, light", Swatch.contrast(ink.light, tint.light) >= 4.5)
            assertTrue("party ink $party, dark", Swatch.contrast(ink.dark, tint.dark) >= 4.5)
        }
    }

    /** The call button prints its ink on the yea fill. */
    @Test
    fun callInkReadsOnYea() {
        assertTrue(Swatch.contrast(Tones.callInk.light, Tones.yea.light) >= 4.5)
        assertTrue(Swatch.contrast(Tones.callInk.dark, Tones.yea.dark) >= 4.5)
    }

    /** Chips print the ground colour on an outcome or state colour, so those must read in light. */
    @Test
    fun groundReadsOnAChip() {
        for ((name, chip) in listOf(
            "yea" to Tones.yea, "nay" to Tones.nay, "liveText" to Tones.liveText,
            "scheduled" to Tones.scheduled, "threshold" to Tones.threshold, "text" to Tones.text,
        )) {
            val light = Swatch.contrast(Tones.ground.light, chip.light)
            assertTrue("ground on $name, light: $light", light >= 4.5)
        }
    }
}
