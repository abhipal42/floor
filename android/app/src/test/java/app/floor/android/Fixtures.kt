package app.floor.android

import app.floor.android.api.FloorApi
import kotlinx.serialization.DeserializationStrategy
import java.io.File

/**
 * The recorded API responses in `ios/FloorKit/Tests/ModelsTests/Fixtures`, read where they live so
 * both apps decode the same bytes. Gradle passes the directory as `floor.fixtures`.
 */
object Fixtures {
    private val dir: File by lazy {
        val path = System.getProperty("floor.fixtures") ?: error("floor.fixtures is not set; run the tests through Gradle")
        File(path).also { check(it.isDirectory) { "No fixtures at $it" } }
    }

    /**
     * A shared fixture, else one under `src/test/resources/fixtures`: round 13's promises and posts,
     * hand-built from real content until the API that records them lands (each says so in `_note`).
     */
    fun text(name: String): String {
        val shared = File(dir, "$name.json")
        if (shared.isFile) return shared.readText()
        val local = Fixtures::class.java.getResource("/fixtures/$name.json") ?: error("No fixture $name")
        return local.readText()
    }

    fun <T> decode(name: String, strategy: DeserializationStrategy<T>): T =
        FloorApi.json.decodeFromString(strategy, text(name))
}
