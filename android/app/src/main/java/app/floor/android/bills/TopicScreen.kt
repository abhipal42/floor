package app.floor.android.bills

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.floor.android.design.BillRow
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.design.SavedDataNote
import app.floor.android.home.TabBarClearance
import app.floor.android.model.TopicFilter
import app.floor.android.model.TopicText
import app.floor.android.vote.TopBar

/**
 * A topic's page (Round 10, section B; iOS `TopicPageView`): its name, its counts, the filter, and
 * its bills, each opening the bill screen; the next page loads as the list reaches its end. The
 * Follow pill beside the name arrives with follows (phase 4).
 */
@Composable
fun TopicScreen(
    state: TopicState,
    back: String,
    onBack: () -> Unit,
    onSelect: (TopicFilter) -> Unit,
    onRetry: () -> Unit,
    onLoadMore: () -> Unit,
    onOpenBill: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Palette
    Column(modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = back, onBack = onBack)
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.saved?.let { item { SavedDataNote(it) } }
            item {
                Text(state.name.uppercase(), style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() })
            }
            state.topic?.let { item { Text(TopicText.detail(it), style = FloorType.text(12f), color = colors.textMuted) } }
            item { FilterSwitch(state.filter, onSelect) }
            when (val phase = state.phase) {
                TopicState.Phase.Loading -> item { Spinner("Loading ${state.name}") }
                is TopicState.Phase.Failed -> item { Failed(phase.message, onRetry) }
                TopicState.Phase.Loaded -> {
                    if (state.bills.isEmpty()) {
                        item {
                            Text(
                                TopicState.emptyMessage(state.name, state.filter),
                                style = FloorType.text(13f),
                                color = colors.textMuted,
                                modifier = Modifier.padding(top = 6.dp),
                            )
                        }
                    }
                    itemsIndexed(state.bills, key = { _, bill -> bill.id }) { index, bill ->
                        BillRow(bill, onOpen = { onOpenBill(bill.id) }, showsRoad = false)
                        if (index == state.bills.lastIndex) LaunchedEffect(bill.id, state.nextCursor) { onLoadMore() }
                    }
                    if (state.loadingMore) {
                        item {
                            Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = colors.accent, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                            }
                        }
                    } else {
                        state.moreError?.let { error ->
                            item {
                                Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(error, style = FloorType.text(12f), color = colors.textSecondary)
                                    Text(
                                        "Try again",
                                        style = FloorType.text(15f, FontWeight.SemiBold),
                                        color = colors.accent,
                                        modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onLoadMore),
                                    )
                                }
                            }
                        }
                    }
                    if (state.bills.isNotEmpty()) {
                        item {
                            Text(
                                "“Stalled” means no action in 90 days. It describes; it doesn't predict.",
                                style = FloorType.text(11f),
                                color = colors.textMuted,
                                modifier = Modifier.padding(top = 6.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterSwitch(selected: TopicFilter, onSelect: (TopicFilter) -> Unit) {
    val colors = Palette
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(9.dp))
            .background(colors.panel)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        TopicFilter.entries.forEach { option ->
            val on = option == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (on) colors.chip else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(option) }
                    .semantics {
                        this.selected = on
                        contentDescription = if (option == TopicFilter.LAW) "Became law" else option.label
                    }
                    .padding(vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    option.label.uppercase(),
                    style = FloorType.label(12f).copy(letterSpacing = 0.6.sp),
                    color = if (on) colors.text else colors.textMuted,
                    maxLines = 1,
                )
            }
        }
    }
}
