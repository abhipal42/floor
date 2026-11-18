package app.floor.android.local

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.floor.android.design.FloorColors
import app.floor.android.design.FloorType
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.sp
import app.floor.android.design.Palette
import app.floor.android.home.TabBarClearance
import app.floor.android.member.Load
import app.floor.android.member.Spinner
import app.floor.android.member.TryAgain
import app.floor.android.model.Jurisdiction
import app.floor.android.model.LocalHubs
import app.floor.android.vote.TopBar

/**
 * The Cities screen, from Local's "Cities ›": every registry city with what Floor can read for it
 * (Ready, Coming soon, News only) and an add/remove toggle. States aren't listed: the user's state
 * is their hub already.
 */
@Composable
fun CitiesScreen(state: LocalState, back: String, onBack: () -> Unit, onToggle: (String) -> Unit, onRetry: () -> Unit) {
    val colors = Palette
    Column(Modifier.fillMaxSize().background(colors.ground).windowInsetsPadding(WindowInsets.statusBars)) {
        TopBar(back = back, onBack = onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 32.dp + TabBarClearance),
        ) {
            Text("CITIES", style = FloorType.headline(36f), color = colors.text, modifier = Modifier.semantics { heading() })
            when (val registry = state.registry) {
                Load.Loading -> Spinner("Loading the cities")
                is Load.Failed -> Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(registry.message, style = FloorType.text(13f), color = colors.textSecondary)
                    TryAgain(onRetry)
                }
                is Load.Loaded -> {
                    val added = state.cityIds.toSet()
                    Column(Modifier.padding(top = 8.dp)) {
                        registry.value.cities.forEach { city -> CityRow(city, city.id in added) { onToggle(city.id) } }
                    }
                }
            }
        }
    }
}

@Composable
private fun CityRow(city: Jurisdiction, added: Boolean, onToggle: () -> Unit) {
    val colors = Palette
    Column {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(city.name, style = FloorType.text(14.5f, FontWeight.Bold), color = colors.text, modifier = Modifier.weight(1f))
            Badge(city)
            AddToggle(added, city.name, onToggle)
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.cardBorder))
    }
}

/** Add / Added, in the Follow pill's style: a switch for TalkBack, "Show New York City on Local". */
@Composable
private fun AddToggle(on: Boolean, name: String, onToggle: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(8.dp)
    Text(
        if (on) "ADDED" else "ADD",
        style = FloorType.label(12f).copy(letterSpacing = 0.6.sp),
        color = if (on) colors.text else colors.ground,
        maxLines = 1,
        modifier = Modifier
            .clip(shape)
            .background(if (on) Color.Transparent else colors.threshold, shape)
            .then(if (on) Modifier.border(1.dp, colors.raised, shape) else Modifier)
            .clickable(role = Role.Switch, onClick = onToggle)
            .semantics {
                contentDescription = "Show $name on Local"
                stateDescription = if (on) "On" else "Off"
            }
            .padding(horizontal = 10.dp, vertical = 7.dp),
    )
}

/** The mock's `.badge`: Ready in a yea tint, Coming soon in gold, News only in grey. */
@Composable
private fun Badge(city: Jurisdiction) {
    val colors = Palette
    val (ink, fill) = badgeColors(colors, city.coverageValue)
    Text(
        LocalHubs.badge(city),
        style = FloorType.text(10.5f, FontWeight.Bold),
        color = ink,
        maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(fill).padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

private fun badgeColors(colors: FloorColors, coverage: Jurisdiction.Coverage) = when (coverage) {
    Jurisdiction.Coverage.RECORDS -> colors.yea to colors.yea.copy(alpha = 0.14f)
    Jurisdiction.Coverage.PENDING -> colors.threshold to colors.threshold.copy(alpha = 0.13f)
    Jurisdiction.Coverage.NEWS_ONLY -> colors.textMuted to colors.track
}
