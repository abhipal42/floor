package app.floor.android.vote

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.time.ZoneId
import java.util.Locale

/**
 * The vote's time is printed in the zone and locale passed in, never a default one (HANDOFF lesson
 * 69). Robolectric, because the formatter is the platform's ICU.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class WhenLabelTest {
    // H.R. 7008's cloture vote closed at 15:58 UTC.
    private val closed = Instant.parse("2026-09-30T15:58:00Z")

    /** ICU puts a narrow no-break space before AM/PM; compare as plain spaces. */
    private fun label(zone: String, locale: Locale) =
        whenLabel(closed, ZoneId.of(zone), locale).replace(' ', ' ').replace(' ', ' ')

    @Test
    fun printsInTheZoneItIsGiven() {
        assertEquals("Sep 30, 11:58 AM", label("America/New_York", Locale.US))
        assertEquals("Sep 30, 8:58 AM", label("America/Los_Angeles", Locale.US))
        assertEquals("Sep 30, 3:58 PM", label("UTC", Locale.US))
    }

    @Test
    fun followsTheReadersLocale() {
        // Day first and a 24-hour clock in Britain.
        assertEquals("30 Sept, 16:58", label("Europe/London", Locale.UK))
    }
}
