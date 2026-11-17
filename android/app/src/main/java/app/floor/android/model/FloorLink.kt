package app.floor.android.model

import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URISyntaxException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * The links the app opens on (iOS `FloorLink`): the share link
 * `https://floor-web-seven.vercel.app/bill/119/hr/5267`, verified as an Android App Link (the
 * manifest's `autoVerify` intent filter, the API's `/.well-known/assetlinks.json`), and the
 * `floor://` links the home-screen widget opens the app with.
 *
 * One type builds them (the widget) and parses them (`MainActivity`), so the two can't disagree
 * about the shape. A link is input, not trust: a vote id must be exactly the shape the API issues,
 * `house-119-2-321`, and a bill id `119-hr-1013`, in ASCII. Anything else is refused before it
 * reaches a screen or a request.
 */
sealed interface FloorLink {
    /** The vote screen for one roll call: `floor://vote/house-119-2-321`. */
    data class Vote(val id: String) : FloorLink

    /** The bill screen: `floor://bill/119-hr-1013`, or the share link. */
    data class Bill(val id: String) : FloorLink

    /** Just the app, wherever it was: `floor://open`. The widget's empty and error states. */
    data object Open : FloorLink

    val url: String
        get() = when (this) {
            // A valid id needs no escaping; an invalid one is escaped so it can't change the link's
            // shape, and `parse` refuses it anyway.
            is Vote -> "$SCHEME://vote/${escape(id)}"
            is Bill -> "$SCHEME://bill/${escape(id)}"
            Open -> "$SCHEME://open"
        }

    companion object {
        const val SCHEME = "floor"

        /**
         * The host whose `/bill/{congress}/{type}/{number}` pages are share links (the API serves
         * them). Change this, the manifest's intent filter and the API's `DEFAULT_SHARE_BASE` together.
         */
        const val SHARE_HOST = "floor-web-seven.vercel.app"

        /** A link read back, or null for anything that isn't one of ours. */
        fun parse(url: String): FloorLink? {
            val uri = try {
                URI(url)
            } catch (_: URISyntaxException) {
                return null
            }
            val scheme = uri.scheme?.lowercase() ?: return null
            val host = uri.host?.lowercase()
            // The encoded path, so an escaped `/` inside an id is not read as a separator; then the
            // id must still match its shape once decoded.
            val parts = (uri.rawPath ?: "").split("/").drop(1).map(::unescape)
            if (scheme == "https" && host == SHARE_HOST) {
                // https://floor-web-seven.vercel.app/bill/119/hr/1013
                if (parts.size != 4 || parts[0] != "bill") return null
                val (congress, type, number) = Triple(parts[1] ?: return null, parts[2] ?: return null, parts[3] ?: return null)
                val id = "$congress-$type-$number"
                return if (isBillId(id)) Bill(id) else null
            }
            if (scheme != SCHEME) return null
            return when (host) {
                "vote" -> parts.singleOrNull()?.takeIf(::isVoteId)?.let(::Vote)
                "bill" -> parts.singleOrNull()?.takeIf(::isBillId)?.let(::Bill)
                "open" -> Open
                else -> null
            }
        }

        /** `^(house|senate)-\d+-\d+-\d+$`, ASCII digits only: chamber, congress, session, roll. */
        fun isVoteId(id: String): Boolean {
            val parts = id.split("-")
            if (parts.size != 4 || (parts[0] != "house" && parts[0] != "senate")) return false
            return parts.drop(1).all { it.isNotEmpty() && it.length <= 6 && it.all { c -> c in '0'..'9' } }
        }

        /** `^\d{2,3}-(hr|s|hres|sres|hjres|sjres|hconres|sconres)-\d{1,5}$`, ASCII digits only. */
        fun isBillId(id: String): Boolean {
            val parts = id.split("-")
            fun digits(part: String, range: IntRange) = part.length in range && part.all { it in '0'..'9' }
            return parts.size == 3 && digits(parts[0], 2..3) && parts[1] in billTypes && digits(parts[2], 1..5) &&
                !parts[2].startsWith("0")
        }

        private val billTypes = setOf("hr", "s", "hres", "sres", "hjres", "sjres", "hconres", "sconres")

        private fun escape(id: String): String = buildString {
            for (byte in id.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt().toChar()
                if (c in 'a'..'z' || c in '0'..'9' || c == '-') append(c) else append("%%%02X".format(byte.toInt() and 0xFF))
            }
        }

        /** Percent-decoded as UTF-8; null for a malformed escape or bytes that aren't UTF-8 (as Swift's). */
        private fun unescape(text: String): String? {
            val bytes = ByteArrayOutputStream()
            var i = 0
            while (i < text.length) {
                val c = text[i]
                if (c == '%') {
                    val hex = text.substring(i + 1, minOf(i + 3, text.length))
                    if (hex.length != 2 || !hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                    bytes.write(hex.toInt(16))
                    i += 3
                } else {
                    bytes.write(c.toString().toByteArray(Charsets.UTF_8))
                    i += 1
                }
            }
            return try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes.toByteArray()))
                    .toString()
            } catch (_: CharacterCodingException) {
                null
            }
        }
    }
}
