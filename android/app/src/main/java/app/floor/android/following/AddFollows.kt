package app.floor.android.following

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.floor.android.bills.ChamberSwitch
import app.floor.android.bills.FollowActions
import app.floor.android.bills.SearchField
import app.floor.android.bills.SearchState
import app.floor.android.bills.searchResults
import app.floor.android.design.FloorType
import app.floor.android.design.Palette
import app.floor.android.model.Chamber
import app.floor.android.model.Member

/**
 * "+ Add" (iOS `AddFollowsView`, Round 10 section C): one search over members, bills and topics,
 * results grouped Topics, Bills, Members, each with its Follow toggle. Tapping a row closes the
 * sheet and opens it on the Following tab.
 */
@Composable
fun AddFollows(
    search: SearchState,
    follow: FollowActions,
    onQuery: (String) -> Unit,
    onSubmit: () -> Unit,
    onChamber: (Chamber?) -> Unit,
    onDone: () -> Unit,
    onOpenBill: (String) -> Unit,
    onOpenTopic: (String) -> Unit,
    onOpenMember: (Member) -> Unit,
    onOpenElect: (String) -> Unit,
) {
    val colors = Palette
    LazyColumn(
        Modifier.fillMaxSize().background(colors.ground),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("ADD", style = FloorType.headline(28f), color = colors.text, modifier = Modifier.semantics { heading() })
                Spacer(Modifier.weight(1f))
                Text("DONE", style = FloorType.label(15f), color = colors.threshold,
                    modifier = Modifier.clickable(role = Role.Button, onClick = onDone).padding(4.dp))
            }
        }
        item { SearchField(search, onQuery, onSubmit) }
        item { ChamberSwitch(search.chamber, onChamber) }
        if (search.searched == null && !search.loading && search.error == null) {
            item {
                Text(
                    "Search sitting members by name, state or district; bills by words or number (“hr 1013”, “S. 2”); and the 32 topics CRS sorts every bill into.",
                    style = FloorType.text(13f), color = colors.textMuted, modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
        searchResults(search, follow, onOpenBill, onOpenTopic, onOpenMember, onOpenElect)
    }
}
