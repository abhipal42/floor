package app.floor.android.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import app.floor.android.R
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance

/** The iOS tab bar's four tabs, in its order. */
enum class Tab(val title: String, val icon: Int) {
    FINALS("Finals", R.drawable.ic_tab_finals),
    WEEK("Week", R.drawable.ic_tab_week),
    BILLS("Bills", R.drawable.ic_tab_bills),
    FOLLOWING("Following", R.drawable.ic_tab_following),
}

/**
 * The app (iOS `FloorShell`): four tabs — Finals, Week, Bills, Following — under the locked mocks'
 * floating tab bar. Finals keeps its own navigation stack, so switching tabs never loses your place.
 * Week, Bills and Following are placeholders until their phases land.
 *
 * @param finals the Finals tab's root; it gets a callback that opens a vote.
 */
@Composable
fun FloorShell(
    finals: @Composable (onOpenVote: (String) -> Unit) -> Unit,
    initialTab: Tab = Tab.FINALS,
    finalsNav: NavHostController = rememberNavController(),
) {
    var tab by rememberSaveable { mutableStateOf(initialTab) }
    val colors = Palette
    // System back on another tab returns to Finals before it leaves the app.
    BackHandler(enabled = tab != Tab.FINALS) { tab = Tab.FINALS }
    Box(Modifier.fillMaxSize().background(colors.ground)) {
        // Every tab stays composed, so Finals' scroll and stack survive a trip to another tab.
        Box(if (tab == Tab.FINALS) Modifier.fillMaxSize() else Modifier.hidden()) {
            NavHost(finalsNav, startDestination = "finals") {
                composable("finals") { finals { id -> finalsNav.navigate("vote/$id") } }
                composable("vote/{id}") {
                    ComingSoon(
                        title = "VOTE",
                        body = "The vote screen is coming to Android next. It is on iPhone today.",
                        onBack = { finalsNav.popBackStack() },
                    )
                }
            }
        }
        if (tab != Tab.FINALS) {
            ComingSoon(title = tab.title.uppercase(), body = "The ${tab.title} tab is coming to Android. It is on iPhone today.")
        }
        TabBar(tab) { picked ->
            // A second tap on the current tab goes back to its top, as system tab bars do.
            if (picked == tab && picked == Tab.FINALS) finalsNav.popBackStack("finals", inclusive = false)
            tab = picked
        }
    }
}

/** Kept composed (its state survives) but drawn at no size and so out of reach of taps. */
private fun Modifier.hidden(): Modifier = this.size(0.dp)

@Composable
private fun TabBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(22.dp)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 16.dp, end = 16.dp, bottom = 4.dp)
                .fillMaxWidth()
                .clip(shape)
                .background(colors.panel.copy(alpha = 0.94f), shape)
                .border(1.dp, colors.panelBorder, shape)
                .padding(8.dp)
                .semantics { contentDescription = "Tabs" },
        ) {
            Tab.entries.forEach { item ->
                val on = item == selected
                val tint = if (on) colors.yea else colors.textMuted
                Column(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .clickable(role = Role.Tab) { onSelect(item) }
                        .semantics { this.selected = on }
                        .padding(4.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Icon(painterResource(item.icon), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
                    Text(item.title, style = FloorType.text(10f, FontWeight.SemiBold, scales = false), color = tint)
                }
            }
        }
    }
}

/**
 * A tab or screen not built on Android yet: a visible placeholder, never an invented one
 * (CLAUDE.md, "Real data or a visible placeholder").
 */
@Composable
fun ComingSoon(title: String, body: String, onBack: (() -> Unit)? = null) {
    val colors = Palette
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.ground)
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = TabBarClearance),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (onBack != null) {
            Text(
                "‹ Finals",
                style = FloorType.text(15f, FontWeight.SemiBold),
                color = colors.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(7.dp))
                    .clickable(role = Role.Button, onClick = onBack)
                    .padding(vertical = 6.dp),
            )
        }
        Text(title, style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.height(4.dp))
        Column(Modifier.panel(colors)) {
            Text("COMING SOON", style = FloorType.label(16f), color = colors.threshold)
            Spacer(Modifier.height(6.dp))
            Text(body, style = FloorType.body(), color = colors.textSecondary)
        }
    }
}
