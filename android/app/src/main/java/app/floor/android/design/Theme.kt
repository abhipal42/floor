package app.floor.android.design

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.core.content.edit

/** The reader's choice of light or dark, or the system's (iOS `Appearance`). */
enum class Appearance(val label: String) {
    SYSTEM("System"),
    LIGHT("Light"),
    DARK("Dark");

    companion object {
        private const val PREFS = "floor"
        const val STORAGE_KEY = "appearance"

        /** An unknown or missing stored value means the system's. */
        fun stored(value: String?): Appearance = entries.firstOrNull { it.name.lowercase() == value } ?: SYSTEM

        fun load(context: Context): Appearance =
            stored(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(STORAGE_KEY, null))

        fun save(context: Context, appearance: Appearance) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
                putString(STORAGE_KEY, appearance.name.lowercase())
            }
        }
    }
}

/**
 * False draws every arrival animation (the split-flap scramble) already settled, as the system's
 * "Remove animations" does: how a screenshot test asks for the settled frame.
 */
val LocalPlaysArrivalAnimations = compositionLocalOf { true }

/**
 * Floor's colours for [appearance], with Material 3 underneath themed by the same tokens so its
 * pieces (the spinner, the pull-to-refresh indicator, menus) never fall back to Material's purple.
 */
@Composable
fun FloorTheme(appearance: Appearance = Appearance.SYSTEM, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        Appearance.SYSTEM -> isSystemInDarkTheme()
        Appearance.LIGHT -> false
        Appearance.DARK -> true
    }
    val colors = if (dark) FloorColors.Dark else FloorColors.Light
    val scheme = if (dark) {
        darkColorScheme(
            primary = colors.accent, background = colors.ground, surface = colors.panel,
            onBackground = colors.text, onSurface = colors.text, surfaceContainer = colors.panel,
        )
    } else {
        lightColorScheme(
            primary = colors.accent, background = colors.ground, surface = colors.panel,
            onBackground = colors.text, onSurface = colors.text, surfaceContainer = colors.panel,
        )
    }
    CompositionLocalProvider(LocalFloorColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
