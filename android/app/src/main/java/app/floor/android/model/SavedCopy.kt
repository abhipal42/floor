package app.floor.android.model

import java.time.Duration
import java.time.Instant

/** Some of what a screen shows is a saved response rather than a fresh one, and why. */
data class SavedCopy(
    /** When the saved response on screen was fetched. */
    val savedAt: Instant,
    val status: Status,
) {
    enum class Status {
        /** The saved data is on screen and the network pass is still running. */
        REFRESHING,

        /** The refresh never reached the server. */
        OFFLINE,

        /** The server answered, but with an error. */
        REFRESH_FAILED,
    }

    /** "Saved 2 h ago · refreshing…", "Offline · saved 2 h ago", "Couldn't refresh · saved 2 h ago". */
    fun text(now: Instant): String {
        val age = age(savedAt, now)
        return when (status) {
            Status.REFRESHING -> "Saved $age · refreshing…"
            Status.OFFLINE -> "Offline · saved $age"
            Status.REFRESH_FAILED -> "Couldn't refresh · saved $age"
        }
    }

    companion object {
        /** "just now", "12 min ago", "2 h ago", "3 d ago": whole units, rounded down. */
        fun age(date: Instant, now: Instant): String {
            val minutes = maxOf(0L, Duration.between(date, now).toMinutes())
            return when {
                minutes == 0L -> "just now"
                minutes < 60 -> "$minutes min ago"
                minutes < 60 * 24 -> "${minutes / 60} h ago"
                else -> "${minutes / (60 * 24)} d ago"
            }
        }
    }
}
