package app.floor.android.api

import java.io.File
import java.security.MessageDigest
import java.time.Instant

/** Where API responses are saved so a screen can open on its last-seen data (iOS `ResponseCache`). */
interface ResponseCache {
    data class Entry(val body: String, val fetchedAt: Instant)

    fun load(key: String): Entry?

    fun save(key: String, body: String, at: Instant)

    /** Forgets every saved response. */
    fun clear()
}

/**
 * One file per request URL under [dir], named by the URL's SHA-256 so the URL itself is never a
 * file name. The first line is when it was fetched (epoch milliseconds), the rest the body.
 *
 * In the app's cache directory: the system may clear it under storage pressure, which costs only
 * the offline copy.
 */
class FileResponseCache(private val dir: File) : ResponseCache {
    override fun load(key: String): ResponseCache.Entry? {
        val file = file(key)
        if (!file.isFile) return null
        return try {
            val text = file.readText()
            val newline = text.indexOf('\n')
            if (newline < 0) return null
            ResponseCache.Entry(text.substring(newline + 1), Instant.ofEpochMilli(text.substring(0, newline).toLong()))
        } catch (_: Exception) {
            null
        }
    }

    override fun save(key: String, body: String, at: Instant) {
        try {
            dir.mkdirs()
            // Written beside, then renamed, so a reader never sees half a response.
            val tmp = File(dir, file(key).name + ".tmp")
            tmp.writeText("${at.toEpochMilli()}\n$body")
            tmp.renameTo(file(key))
        } catch (_: Exception) {
            // A full disk loses the offline copy, not the response on screen.
        }
    }

    override fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }

    private fun file(key: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(dir, "$hash.json")
    }
}
