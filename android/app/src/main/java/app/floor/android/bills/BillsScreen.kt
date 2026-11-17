package app.floor.android.bills

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import app.floor.android.R
import app.floor.android.design.BillRow
import app.floor.android.design.glass
import app.floor.android.design.FloorType
import app.floor.android.design.ListHeading
import app.floor.android.design.Notice
import app.floor.android.design.Palette
import app.floor.android.design.arenaGround
import app.floor.android.design.SavedDataNote
import app.floor.android.design.TopicRow
import app.floor.android.design.panel
import app.floor.android.home.TabBarClearance
import app.floor.android.model.SpokenBill
import app.floor.android.model.TopicText

/**
 * The Bills tab: a search over members, bills by number or words, and the 32 topics, then — with
 * nothing typed — the 32 topics, each opening its page (see [BillsModel] for why these live here on
 * Android). Search results are drawn as iOS's "+ Add" sheet draws them: topics, bills, members.
 */
@Composable
fun BillsScreen(
    state: BillsState,
    onQuery: (String) -> Unit,
    onSubmit: () -> Unit,
    onRetry: () -> Unit,
    onOpenBill: (String) -> Unit,
    onOpenTopic: (String) -> Unit,
    modifier: Modifier = Modifier,
    onChamber: (app.floor.android.model.Chamber?) -> Unit = {},
    onOpenMember: (app.floor.android.model.Member) -> Unit = {},
    onOpenElect: (String) -> Unit = {},
    follow: FollowActions? = null,
) {
    val colors = Palette
    val search = state.search
    val searching = SearchState.normalized(search.query) != null
    LazyColumn(
        modifier
            .fillMaxSize()
            .arenaGround(colors)
            .windowInsetsPadding(WindowInsets.statusBars),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp + TabBarClearance,
        ),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Text("BILLS", style = FloorType.headline(34f), color = colors.text, modifier = Modifier.semantics { heading() })
        }
        item { SearchField(search, onQuery, onSubmit) }
        if (searching || search.searched != null) {
            item { ChamberSwitch(search.chamber, onChamber) }
            searchResults(search, follow, onOpenBill, onOpenTopic, onOpenMember, onOpenElect)
        } else {
            item {
                Text(
                    "Search sitting members by name, state or district; bills by words or number (“hr 1013”, “S. 2”); or open one of the 32 topics CRS sorts every bill into.",
                    style = FloorType.text(13f),
                    color = colors.textMuted,
                    modifier = Modifier.padding(top = 2.dp, bottom = 4.dp),
                )
            }
            state.saved?.let { item { SavedDataNote(it) } }
            when (val phase = state.topics) {
                BillsState.Phase.Loading -> item { Spinner("Loading the topics") }
                is BillsState.Phase.Failed -> item { Failed(phase.message, onRetry) }
                is BillsState.Phase.Loaded -> {
                    item { ListHeading("TOPICS · ${phase.topics.size}") }
                    items(phase.topics, key = { "topic-" + it.name }) { topic ->
                        TopicRow(topic.name, TopicText.detail(topic), SpokenBill.topicRow(topic), onOpen = { onOpenTopic(topic.name) })
                    }
                }
            }
        }
    }
}

@Composable
internal fun SearchField(search: SearchState, onQuery: (String) -> Unit, onSubmit: () -> Unit) {
    val colors = Palette
    val focus = LocalFocusManager.current
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .glass(colors, shape)
            .padding(horizontal = 11.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(painterResource(R.drawable.ic_search), contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f)) {
            val style = FloorType.text(15f, FontWeight.Medium)
            if (search.query.isEmpty()) {
                Text("Members, bills, topics, or a bill number", style = style, color = colors.textMuted, maxLines = 1)
            }
            BasicTextField(
                value = search.query,
                onValueChange = onQuery,
                singleLine = true,
                textStyle = style.copy(color = colors.text),
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search,
                ),
                keyboardActions = KeyboardActions(onSearch = {
                    focus.clearFocus()
                    onSubmit()
                }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search members, bills and topics" },
            )
        }
        if (search.loading) {
            CircularProgressIndicator(color = colors.accent, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        }
        if (search.query.isNotEmpty()) {
            Icon(
                painterResource(R.drawable.ic_clear),
                contentDescription = "Clear search",
                tint = colors.textMuted,
                modifier = Modifier
                    .size(20.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(role = Role.Button) { onQuery("") },
            )
        }
    }
}

@Composable
internal fun Spinner(description: String) {
    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = Palette.accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp).semantics { contentDescription = description },
        )
    }
}

/** A failed load in a panel, with Try again (iOS's topic page and Bills tab). */
@Composable
internal fun Failed(message: String, onRetry: () -> Unit) {
    val colors = Palette
    Column(Modifier.panel(colors), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, style = FloorType.body(), color = colors.textSecondary)
        Text(
            "Try again",
            style = FloorType.text(15f, FontWeight.SemiBold),
            color = colors.accent,
            modifier = Modifier.clip(RoundedCornerShape(7.dp)).clickable(role = Role.Button, onClick = onRetry).padding(vertical = 4.dp),
        )
    }
}
