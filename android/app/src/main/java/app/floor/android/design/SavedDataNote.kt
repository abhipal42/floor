package app.floor.android.design

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import app.floor.android.model.SavedCopy
import kotlinx.coroutines.delay
import java.time.Instant

/**
 * The one line a screen adds while any of it is saved data rather than fresh: "Saved 2 h ago ·
 * refreshing…", then "Offline · saved 2 h ago" or "Couldn't refresh · saved 2 h ago" if the
 * refresh fails. Muted caption text and nothing else; it re-reads the clock each minute.
 */
@Composable
fun SavedDataNote(saved: SavedCopy, now: () -> Instant = Instant::now) {
    var at by remember { mutableStateOf(now()) }
    LaunchedEffect(saved) {
        while (true) {
            at = now()
            delay(60_000)
        }
    }
    Text(saved.text(at), style = FloorType.caption(), color = Palette.textMuted)
}
