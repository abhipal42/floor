package app.floor.android.bills

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.floor.android.design.BillRow
import app.floor.android.design.glass
import app.floor.android.design.ChipSwitch
import app.floor.android.design.ElectRow
import app.floor.android.design.FloorType
import app.floor.android.design.FollowButton
import app.floor.android.design.FollowPill
import app.floor.android.design.ListHeading
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Notice
import app.floor.android.design.Palette
import app.floor.android.design.PendingSeatCard
import app.floor.android.design.SeatMemberRow
import app.floor.android.design.TopicRow
import app.floor.android.design.dashedPanel
import app.floor.android.model.BillListItem
import app.floor.android.model.Chamber
import app.floor.android.model.Member
import app.floor.android.model.SeatRow
import app.floor.android.model.SpokenBill
import app.floor.android.model.SpokenMember
import app.floor.android.model.TopicText
import app.floor.android.model.seatCaption
import app.floor.android.store.FollowState

/** Follow toggles on search rows: what you follow now, your reps (who read "Your rep"), and the toggles. */
data class FollowActions(
    val state: FollowState,
    val reps: Set<String>,
    val onMember: (Member) -> Unit,
    val onBill: (BillListItem) -> Unit,
    val onTopic: (String) -> Unit,
)

/** `D · House · TX-37`, `R · Senate · NY`: a member row's caption. */
fun memberCaption(member: Member): String = "${member.party} · ${member.seatCaption}"

/** All · Senate · House, narrowing the members (iOS "+ Add"'s switch). */
@Composable
fun ChamberSwitch(chamber: Chamber?, onSelect: (Chamber?) -> Unit) {
    ChipSwitch(
        listOf(null, Chamber.SENATE, Chamber.HOUSE), chamber, { it?.title?.uppercase() ?: "ALL" }, onSelect,
        spoken = { it?.let { c -> "${c.title} members" } ?: "Members in both chambers" },
    )
}

/**
 * Search results as iOS's "+ Add" draws them: topics, bills, then members by chamber, Senate first,
 * each member-elect under the member whose seat they take and undecided seats as placeholders. A
 * member row opens the member screen; with [follow], each row carries its Follow toggle.
 */
fun LazyListScope.searchResults(
    search: SearchState,
    follow: FollowActions?,
    onOpenBill: (String) -> Unit,
    onOpenTopic: (String) -> Unit,
    onOpenMember: (Member) -> Unit,
    onOpenElect: (String) -> Unit,
) {
    val error = search.error
    val searched = search.searched
    when {
        error != null -> item { Notice("COULDN'T SEARCH", error) }
        search.foundNothing && searched != null -> item {
            Notice(
                "NOTHING MATCHES “${searched.uppercase()}”",
                "Try a last name, a state, a district like TX-37, a topic like Health, or a bill number like hr 1013.",
            )
        }
        searched == null && search.loading -> item { Spinner("Searching") }
    }
    if (error != null) return
    val topics = search.topics
    if (topics.isNotEmpty()) {
        item { ListHeading(if (topics.size == 1) "TOPIC" else "TOPICS · ${topics.size}") }
        items(topics, key = { "result-topic-" + it.name }) { topic ->
            TopicRow(
                topic.name, TopicText.detail(topic), SpokenBill.topicRow(topic), { onOpenTopic(topic.name) },
                trailing = follow?.let { f -> { FollowPill(f.state.isFollowingTopic(topic.name), topic.name) { f.onTopic(topic.name) } } },
            )
        }
    }
    val bills = search.bills
    if (bills.isNotEmpty()) {
        val billNumber = search.results?.billNumber == true
        item { ListHeading(if (billNumber && bills.size == 1) "BILL" else "BILLS · ${bills.size}") }
        items(bills, key = { "result-bill-" + it.id }) { bill ->
            BillRow(
                bill, onOpen = { onOpenBill(bill.id) }, showsLatest = billNumber, showsRoad = false,
                trailing = follow?.let { f -> { FollowPill(f.state.isFollowingBill(bill.id), bill.citation) { f.onBill(bill) } } },
            )
        }
    }
    if (!search.showsMembers) return
    val members = search.results?.members.orEmpty()
    val seats = search.seats
    if (members.isEmpty() && seats.elect.isEmpty() && seats.pending.isEmpty() && searched != null) {
        item { ListHeading(search.chamber?.let { "${it.title.uppercase()} MEMBERS" } ?: "MEMBERS") }
        item {
            val colors = Palette
            Text(
                "No ${search.chamber?.let { "${it.title} " } ?: ""}members match “$searched”.",
                style = FloorType.text(12.5f), color = colors.textSecondary,
                modifier = Modifier.dashedPanel(colors.panelBorder, colors.panel, 14.dp).padding(12.dp),
            )
        }
    }
    for (chamber in listOf(Chamber.SENATE, Chamber.HOUSE)) {
        val these = members.filter { it.chamber == chamber }
        val rows = SeatRow.rows(these, seats.elect.filter { it.chamber == chamber }, seats.pending.filter { it.chamber == chamber })
        if (rows.isEmpty()) continue
        item { ListHeading(if (these.isNotEmpty()) "${chamber.title.uppercase()} · ${these.size}" else chamber.title.uppercase()) }
        items(rows, key = { "result-seat-" + it.key }) { row ->
            when (row) {
                is SeatRow.Sitting -> {
                    val trailing: @Composable () -> Unit = {
                        follow?.let { f ->
                            FollowButton(row.member, f.state.isFollowing(row.member.bioguideId), row.member.bioguideId in f.reps, compact = true, onToggle = { f.onMember(row.member) })
                        }
                    }
                    if (row.leavingOn == null) {
                        MemberRow(row.member, { onOpenMember(row.member) }, trailing)
                    } else {
                        SeatMemberRow(row.member, row.leavingOn, memberCaption(row.member), { onOpenMember(row.member) }, trailing)
                    }
                }
                is SeatRow.Elect -> ElectRow(row.elect) { onOpenElect(row.elect.id) }
                is SeatRow.Pending -> PendingSeatCard(row.seat)
            }
        }
    }
}

/** A member in a list: portrait, surname, party and seat, opening their record. */
@Composable
fun MemberRow(member: Member, onOpen: () -> Unit, trailing: @Composable () -> Unit = {}) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier.fillMaxWidth().glass(colors, shape).padding(end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(
            Modifier
                .weight(1f)
                .clickable(role = Role.Button, onClickLabel = "Open their record", onClick = onOpen)
                .padding(start = 10.dp, top = 8.dp, bottom = 8.dp)
                .clearAndSetSemantics { contentDescription = SpokenMember.member(member) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            MemberPortrait(member, Modifier.size(30.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(member.lastName.uppercase(), style = FloorType.display(17f, FloorType.Face.BLACK_ITALIC), color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(memberCaption(member), style = FloorType.text(10.5f, FontWeight.Medium), color = colors.textMuted)
            }
        }
        trailing()
    }
}
