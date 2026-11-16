package app.floor.android.home

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.floor.android.R
import app.floor.android.design.Appearance
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.design.ScoreboardCard
import app.floor.android.design.panel

/** Room under every screen for the floating tab bar, so the last card scrolls clear of it. */
val TabBarClearance = 76.dp

/**
 * The Finals tab, as the locked Home mock draws it for someone who follows nobody yet (iOS
 * `HomeView`): the header, the latest final on a split-flap board, then the finals by chamber.
 *
 * The delegation strip, the All / Following switch and the catch-up deck need a district or
 * follows, which arrive in a later phase; the screen draws what iOS draws without them.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: HomeState,
    appearance: Appearance,
    onAppearance: (Appearance) -> Unit,
    onFilter: (HomeState.Filter) -> Unit,
    onRetry: () -> Unit,
    onRefresh: () -> Unit,
    onOpenVote: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    PullToRefreshBox(
        isRefreshing = state.refreshing,
        onRefresh = onRefresh,
        modifier = modifier
            .fillMaxSize()
            .background(colors.ground),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(420.dp)
                .background(Brush.verticalGradient(listOf(colors.groundGlow, colors.ground))),
        )
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Header(appearance, onAppearance)
            when (val phase = state.phase) {
                HomeState.Phase.Loading -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        color = colors.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(22.dp).semantics { contentDescription = "Loading recent votes" },
                    )
                }
                is HomeState.Phase.Failed -> Failure(phase.message, onRetry)
                HomeState.Phase.Loaded -> {
                    state.saved?.let { SavedDataNote(it) }
                    state.latestFinal?.let { latest ->
                        SplitFlapBoard(latest, Modifier.clickable(role = Role.Button) { onOpenVote(latest.vote.id) })
                    }
                    FinalsHeader(state.filter, onFilter)
                    val items = state.visibleItems
                    if (items.isEmpty()) {
                        Text(state.emptyFeedMessage, style = FloorType.body(), color = colors.textMuted)
                    } else {
                        items.forEach { item ->
                            ScoreboardCard(
                                vote = item.vote,
                                title = item.measure?.title ?: item.vote.question,
                                citation = item.measure?.citation,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(16.dp))
                                    .clickable(role = Role.Button) { onOpenVote(item.vote.id) },
                            )
                        }
                    }
                }
            }
        }
        // The status bar gets a ground to sit on rather than letting cards scroll under the clock.
        Box(
            Modifier
                .fillMaxWidth()
                .windowInsetsTopHeight(WindowInsets.statusBars)
                .background(colors.groundGlow.copy(alpha = 0.94f)),
        )
    }
}

@Composable
private fun Header(appearance: Appearance, onAppearance: (Appearance) -> Unit) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "FLOOR",
            style = FloorType.headline(34f),
            color = colors.text,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.weight(1f))
        AppearanceMenu(appearance, onAppearance)
    }
}

private fun Appearance.icon(): Int = when (this) {
    Appearance.SYSTEM -> R.drawable.ic_appearance_system
    Appearance.LIGHT -> R.drawable.ic_appearance_light
    Appearance.DARK -> R.drawable.ic_appearance_dark
}

/** The round button at the top right: System, Light or Dark (iOS `AppearanceMenu`). */
@Composable
private fun AppearanceMenu(appearance: Appearance, onAppearance: (Appearance) -> Unit) {
    val colors = Palette
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(colors.text.copy(alpha = 0.08f))
                .clickable(role = Role.Button) { open = true }
                .semantics {
                    contentDescription = "Appearance"
                    stateDescription = appearance.label
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(appearance.icon()), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = colors.panel) {
            Appearance.entries.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            option.label,
                            style = FloorType.text(15f, if (option == appearance) FontWeight.SemiBold else FontWeight.Normal),
                            color = colors.text,
                        )
                    },
                    leadingIcon = { Icon(painterResource(option.icon()), contentDescription = null, tint = colors.textSecondary) },
                    onClick = {
                        open = false
                        onAppearance(option)
                    },
                    modifier = Modifier.semantics { selected = option == appearance },
                )
            }
        }
    }
}

@Composable
private fun FinalsHeader(filter: HomeState.Filter, onFilter: (HomeState.Filter) -> Unit) {
    val colors = Palette
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("FINALS", style = FloorType.headline(26f), color = colors.text, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.weight(1f))
        Row(
            Modifier
                .clip(RoundedCornerShape(9.dp))
                .background(colors.panel)
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            HomeState.Filter.entries.forEach { option ->
                val on = option == filter
                Text(
                    option.label,
                    style = FloorType.text(12f, FontWeight.SemiBold, scales = false),
                    color = if (on) colors.ground else colors.textSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(7.dp))
                        .background(if (on) colors.text else colors.panel)
                        .clickable(role = Role.Tab) { onFilter(option) }
                        .semantics { selected = on }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun Failure(message: String, onRetry: () -> Unit) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, style = FloorType.body(), color = colors.textSecondary)
        Text(
            "Try again",
            style = FloorType.text(15f, FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clickable(role = Role.Button, onClick = onRetry),
        )
    }
}
