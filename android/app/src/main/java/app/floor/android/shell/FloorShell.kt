package app.floor.android.shell

import androidx.activity.OnBackPressedDispatcher
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
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
import android.net.Uri
import androidx.navigation.NavBackStackEntry
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
 * Every screen a tab's stack can push, as the app builds them (with their models) and the tests
 * stub them. Each gets the label of the screen beneath it for its back link, and callbacks that
 * push the next screen onto the same tab's stack.
 */
class FloorScreens(
    /** The Finals tab's root; it gets a callback that opens a vote. */
    val finals: @Composable (onOpenVote: (String) -> Unit) -> Unit = {},
    /** The Bills tab's root: topics and search. */
    val bills: @Composable (onOpenBill: (String) -> Unit, onOpenTopic: (String) -> Unit) -> Unit = { _, _ -> },
    val vote: @Composable (id: String, back: String, onOpenKinds: () -> Unit, onOpenBill: (String) -> Unit, onBack: () -> Unit) -> Unit =
        { _, _, _, _, _ -> },
    val voteKinds: @Composable (onBack: () -> Unit) -> Unit = {},
    val bill: @Composable (id: String, back: String, onOpenVote: (String) -> Unit, onOpenTopic: (String) -> Unit, onBack: () -> Unit) -> Unit =
        { _, _, _, _, _ -> },
    val topic: @Composable (name: String, back: String, onOpenBill: (String) -> Unit, onBack: () -> Unit) -> Unit =
        { _, _, _, _ -> },
)

/**
 * The app (iOS `FloorShell`): four tabs — Finals, Week, Bills, Following — under the locked mocks'
 * floating tab bar. Finals and Bills each keep their own navigation stack, so switching tabs never
 * loses your place; a vote, a bill and a topic can be pushed on either. Week and Following are
 * placeholders until their phases land.
 */
@Composable
fun FloorShell(
    screens: FloorScreens,
    initialTab: Tab = Tab.FINALS,
    finalsNav: NavHostController = rememberNavController(),
    billsNav: NavHostController = rememberNavController(),
) {
    var tab by rememberSaveable { mutableStateOf(initialTab) }
    val colors = Palette
    // System back on another tab returns to Finals before it leaves the app (once that tab's own
    // stack is at its root: NavHost handles back first while it has somewhere to go).
    BackHandler(enabled = tab != Tab.FINALS) { tab = Tab.FINALS }
    Box(Modifier.fillMaxSize().background(colors.ground)) {
        // Every tab stays composed, so each stack and its scroll survive a trip to another tab.
        Box(if (tab == Tab.FINALS) Modifier.fillMaxSize() else Modifier.hidden()) {
            TabStack(finalsNav, "finals", screens, active = tab == Tab.FINALS) { screens.finals { id -> finalsNav.navigate("vote/$id") } }
        }
        Box(if (tab == Tab.BILLS) Modifier.fillMaxSize() else Modifier.hidden()) {
            TabStack(billsNav, "bills", screens, active = tab == Tab.BILLS) {
                screens.bills({ id -> billsNav.navigate("bill/$id") }, { name -> billsNav.navigate("topic/${Uri.encode(name)}") })
            }
        }
        if (tab == Tab.WEEK || tab == Tab.FOLLOWING) {
            ComingSoon(title = tab.title.uppercase(), body = "The ${tab.title} tab is coming to Android. It is on iPhone today.")
        }
        TabBar(tab) { picked ->
            // A second tap on the current tab goes back to its top, as system tab bars do.
            if (picked == tab && picked == Tab.FINALS) finalsNav.popBackStack("finals", inclusive = false)
            if (picked == tab && picked == Tab.BILLS) billsNav.popBackStack("bills", inclusive = false)
            tab = picked
        }
    }
}

/** One tab's stack: its root, then any vote, kinds-of-vote list, bill or topic pushed on it. */
@Composable
private fun TabStack(
    nav: NavHostController,
    root: String,
    screens: FloorScreens,
    active: Boolean,
    rootScreen: @Composable () -> Unit,
) {
    // The back link names the screen beneath, as the iOS navigation bar does.
    fun back(): String = backLabel(nav.previousBackStackEntry)
    // A hidden tab's stack must not take system back: it listens on a dispatcher nothing feeds.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val inert = remember(lifecycle) {
        object : OnBackPressedDispatcherOwner {
            override val onBackPressedDispatcher = OnBackPressedDispatcher()
            override val lifecycle: Lifecycle = lifecycle
        }
    }
    val real = LocalOnBackPressedDispatcherOwner.current
    CompositionLocalProvider(LocalOnBackPressedDispatcherOwner provides if (active && real != null) real else inert) {
        Stack(nav, root, screens, ::back, rootScreen)
    }
}

@Composable
private fun Stack(
    nav: NavHostController,
    root: String,
    screens: FloorScreens,
    back: () -> String,
    rootScreen: @Composable () -> Unit,
) {
    NavHost(nav, startDestination = root) {
        composable(root) { rootScreen() }
        composable("vote/{id}") { entry ->
            screens.vote(
                entry.arguments?.getString("id").orEmpty(),
                back(),
                { nav.navigate("vote-kinds") },
                { billId -> nav.navigate("bill/$billId") },
                { nav.popBackStack() },
            )
        }
        composable("vote-kinds") { screens.voteKinds { nav.popBackStack() } }
        composable("bill/{id}") { entry ->
            screens.bill(
                entry.arguments?.getString("id").orEmpty(),
                back(),
                { voteId -> nav.navigate("vote/$voteId") },
                { name -> nav.navigate("topic/${Uri.encode(name)}") },
                { nav.popBackStack() },
            )
        }
        composable("topic/{name}") { entry ->
            screens.topic(
                entry.arguments?.getString("name").orEmpty(),
                back(),
                { billId -> nav.navigate("bill/$billId") },
                { nav.popBackStack() },
            )
        }
    }
}

/** `Finals`, `Bills`, `Vote`, `Bill`, or a topic's name when it is short enough for a back link. */
private fun backLabel(entry: NavBackStackEntry?): String {
    val route = entry?.destination?.route ?: return "Back"
    return when {
        route == "finals" -> "Finals"
        route == "bills" -> "Bills"
        route.startsWith("vote/") -> "Vote"
        route.startsWith("bill/") -> "Bill"
        route.startsWith("topic/") -> entry.arguments?.getString("name")?.takeIf { it.length <= 14 } ?: "Topic"
        else -> "Back"
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
fun ComingSoon(title: String, body: String, back: String = "Finals", onBack: (() -> Unit)? = null) {
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
                "‹ $back",
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
