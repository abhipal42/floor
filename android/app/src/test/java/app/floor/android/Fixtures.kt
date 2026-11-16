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

    fun text(name: String): String = File(dir, "$name.json").readText()

    fun <T> decode(name: String, strategy: DeserializationStrategy<T>): T =
        FloorApi.json.decodeFromString(strategy, text(name))
}
