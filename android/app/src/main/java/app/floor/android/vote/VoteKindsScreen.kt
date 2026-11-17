package app.floor.android.vote

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.home.TabBarClearance
import app.floor.android.model.VoteKindInfo

/**
 * "Kinds of vote" (round 11, section B; iOS `VoteKindsView`): every kind Floor explains, its line
 * and its rule, in the table's order. Reached from the "?" on any vote.
 *
 * iOS presents it as a sheet over the vote; Android pushes it as a screen, so system back closes it.
 */
@Composable
fun VoteKindsScreen(state: VoteKindsState, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Palette
    Column(
        modifier
            .fillMaxSize()
            .background(colors.ground)
            .windowInsetsPadding(WindowInsets.statusBars),
    ) {
        TopBar(back = "Vote", onBack = onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp + TabBarClearance),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(
                "KINDS OF VOTE",
                style = FloorType.headline(28f),
                color = colors.text,
                modifier = Modifier.padding(bottom = 4.dp).semantics { heading() },
            )
            when (state) {
                is VoteKindsState.Loaded -> {
                    state.kinds.forEach { KindRow(it) }
                    Text(
                        "Written by Floor from House and Senate rules, not by AI. A kind of vote not listed here gets no explanation rather than a guess.",
                        style = FloorType.text(10.5f, FontWeight.Medium),
                        color = colors.textMuted,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
                VoteKindsState.Failed -> Text(
                    "Couldn't load the kinds of vote. Check your connection and try again.",
                    style = FloorType.body(),
                    color = colors.textSecondary,
                )
                VoteKindsState.Loading -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        color = colors.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(22.dp).semantics { contentDescription = "Loading the kinds of vote" },
                    )
                }
            }
        }
    }
}

@Composable
private fun KindRow(kind: VoteKindInfo) {
    val colors = Palette
    val shape = RoundedCornerShape(10.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.panel, shape)
            .border(1.dp, colors.panelBorder, shape)
            .padding(horizontal = 10.dp, vertical = 7.dp)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(kind.title.uppercase(), style = FloorType.display(14f, FloorType.Face.BLACK_ITALIC), color = colors.text)
        Text(kind.text, style = FloorType.text(10.5f), color = colors.textSecondary)
        Text(kind.footnote, style = FloorType.mono(9.5f), color = colors.textMuted)
    }
}
