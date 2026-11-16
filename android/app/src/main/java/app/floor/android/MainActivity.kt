package app.floor.android

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.home.HomeModel
import app.floor.android.home.HomeScreen
import app.floor.android.shell.FloorShell
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Every response a screen reads is saved, so the app opens on what it last showed when
        // offline or slow, then refreshes.
        val api = FloorApi(BuildConfig.API_BASE_URL, cache = FileResponseCache(File(cacheDir, "responses")))
        setContent {
            var appearance by remember { mutableStateOf(Appearance.load(this)) }
            val dark = when (appearance) {
                Appearance.SYSTEM -> isSystemInDarkTheme()
                Appearance.LIGHT -> false
                Appearance.DARK -> true
            }
            // Edge to edge, with the status and navigation bar icons following Floor's appearance
            // rather than only the system's.
            LaunchedEffect(dark) {
                val style = if (dark) {
                    SystemBarStyle.dark(Color.TRANSPARENT)
                } else {
                    SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                }
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            FloorTheme(appearance) {
                FloorShell(finals = { onOpenVote ->
                    val model: HomeModel = viewModel { HomeModel(api) }
                    LaunchedEffect(Unit) { model.appear() }
                    HomeScreen(
                        state = model.state,
                        appearance = appearance,
                        onAppearance = {
                            appearance = it
                            Appearance.save(this, it)
                        },
                        onFilter = model::select,
                        onRetry = model::reload,
                        onRefresh = model::refresh,
                        onOpenVote = onOpenVote,
                    )
                })
            }
        }
    }
}
