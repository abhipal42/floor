package app.floor.android.member

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.floor.android.design.BlockHeader
import app.floor.android.design.FloorType
import app.floor.android.design.HeadlineRow
import app.floor.android.design.NeedNote
import app.floor.android.design.NewsSummaryLine
import app.floor.android.design.Palette
import app.floor.android.design.PollCard
import app.floor.android.design.SavedDataNote
import app.floor.android.design.SectTitle
import app.floor.android.design.ToneBar
import app.floor.android.design.glass
import app.floor.android.design.heroEdge
import app.floor.android.home.TabBarClearance
import app.floor.android.model.Member
import app.floor.android.model.MemberNews
import app.floor.android.model.News
import app.floor.android.model.NewsFilter
import app.floor.android.model.NewsStory
import app.floor.android.model.fullName
import java.time.ZoneId
import java.util.Locale

/** How many of a story's headlines its card shows before "N more ›". */
internal const val STORY_ROWS = 3

/**
 * The member page's News section (v0.2.60, option B): the week's count and the AI's read of its
 * tone, the biggest story as one glass row with its tone bar, then "News ›" to the News page.
 */
@Composable
internal fun NewsBlock(load: Load<MemberNews>, member: Member, onRetry: () -> Unit, onOpen: () -> Unit) {
    val colors = Palette
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        BlockHeader("News")
        when (load) {
            Load.Loading -> Spinner("Loading the news about ${member.fullName}", top = 8)
            is Load.Failed -> FailedLine(load.message, onRetry)
            is Load.Loaded -> {
                val news = load.value
                if (news.headlines.isEmpty()) Text(News.NO_HEADLINES, style = FloorType.text(12.5f), color = colors.textSecondary)
                else NewsSummaryLine(news.countLine, news.tone, news.spokenSummary, size = 12.5f)
                news.shownStories.firstOrNull()?.let { story -> TopStoryRow(news, story, onOpen) }
                Text(
                    "News ›",
                    style = FloorType.text(12.5f, FontWeight.Bold),
                    color = colors.accent,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(role = Role.Button, onClick = onOpen)
                        .semantics { contentDescription = "All of the news about ${member.fullName}" }
                        .padding(vertical = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun TopStoryRow(news: MemberNews, story: NewsStory, onOpen: () -> Unit) {
    val colors = Palette
    val count = news.storyHeadlines(story).size
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClickLabel = "Open the news", onClick = onOpen)
            .clearAndSetSemantics { contentDescription = "Top story, $count headlines: ${story.title}. ${story.tone.spoken}." }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(story.title, style = FloorType.text(14.5f, FontWeight.Bold), color = colors.text)
        ToneBar(story.tone, height = 10.dp)
    }
}

/**
 * The News page (v0.2.60, option B): the member's name small over NEWS, the summary, a filter chip
 * per story and Other, the story cards (each its 3 newest headlines and "N more ›"), the other
 * headlines, then the polls that name the member. Not AI-read: only All, no bars, a plain list.
 */
@Composable
fun NewsPage(load: Load<MemberNews>, member: Member?, zone: ZoneId, locale: Locale, onBack: () -> Unit, onRetry: () -> Unit) {
    val colors = Palette
    val name = member?.fullName ?: "this member"
    var filterKey by rememberSaveable { mutableStateOf("all") }
    var expanded by rememberSaveable { mutableStateOf(listOf<String>()) }
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.ground)
            .windowInsetsPadding(WindowInsets.statusBars)
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp + TabBarClearance),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(34.dp)
                    .dropShadow(CircleShape, Shadow(radius = 10.dp, color = colors.cardShadow, spread = (-8).dp, offset = DpOffset(0.dp, 8.dp)))
                    .clip(CircleShape)
                    .background(colors.chip)
                    .clickable(role = Role.Button, onClick = onBack)
                    .clearAndSetSemantics { contentDescription = "Back to ${member?.lastName ?: "the member"}" },
                contentAlignment = Alignment.Center,
            ) {
                Text("‹", style = FloorType.text(18f, FontWeight.SemiBold, scales = false), color = colors.textSecondary)
            }
            Text(
                name.uppercase(),
                style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp),
                color = colors.textMuted,
                textAlign = TextAlign.Center,
                maxLines = 1,
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
            )
            Spacer(Modifier.size(34.dp))
        }
        Text("NEWS", style = FloorType.headline(36f), color = colors.text, modifier = Modifier.padding(top = 10.dp, bottom = 4.dp).semantics { heading() })
        when (load) {
            Load.Loading -> Spinner("Loading the news about $name")
            is Load.Failed -> Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(load.message, style = FloorType.text(13f), color = colors.textSecondary)
                TryAgain(onRetry)
            }
            is Load.Loaded -> {
                val news = load.value
                load.saved?.let { Box(Modifier.padding(vertical = 6.dp)) { SavedDataNote(it) } }
                if (news.headlines.isNotEmpty()) NewsSummaryLine(news.countLine, news.tone, news.spokenSummary)
                val filters = news.filters
                val filter = filters.firstOrNull { key(it) == filterKey } ?: NewsFilter.All
                FilterChips(filters, filter) { filterKey = key(it) }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (news.headlines.isEmpty()) NeedNote(News.NO_HEADLINES)
                    val stories = news.shownStories.filter { filter == NewsFilter.All || (filter is NewsFilter.Story && filter.id == it.id) }
                    stories.forEach { story ->
                        val all = filter is NewsFilter.Story || story.id in expanded
                        StoryCard(news, story, all, zone, locale) { expanded = expanded + story.id }
                    }
                    if (filter == NewsFilter.All || filter is NewsFilter.Other) {
                        val other = news.otherHeadlines
                        if (other.isNotEmpty()) {
                            if (news.shownStories.isNotEmpty()) SectTitle("Other headlines")
                            Column { other.forEach { HeadlineRow(it, zone, locale) } }
                        }
                    }
                }
                SectTitle("Polls", Modifier.padding(top = 10.dp, bottom = 10.dp))
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (news.polls.isEmpty()) NeedNote(News.noPolls(name))
                    news.polls.forEach { PollCard(it, locale) }
                    if (news.polls.isNotEmpty()) {
                        Text(News.pollsFootnote(name), style = FloorType.text(11.5f), color = colors.textMuted, modifier = Modifier.padding(horizontal = 2.dp))
                    }
                }
            }
        }
    }
}

private fun key(filter: NewsFilter): String = when (filter) {
    NewsFilter.All -> "all"
    is NewsFilter.Story -> "story:${filter.id}"
    is NewsFilter.Other -> "other"
}

/** The mock's `.chips`: All, one per story, Other; the chosen one white. */
@Composable
private fun FilterChips(filters: List<NewsFilter>, selected: NewsFilter, onSelect: (NewsFilter) -> Unit) {
    val colors = Palette
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        filters.forEach { filter ->
            val on = filter == selected
            val pill = RoundedCornerShape(50)
            Text(
                filter.label,
                style = FloorType.text(12.5f, FontWeight.SemiBold),
                color = if (on) colors.ground else colors.textSecondary,
                maxLines = 1,
                modifier = Modifier
                    .clip(pill)
                    .background(if (on) colors.text else colors.chip, pill)
                    .border(1.dp, if (on) colors.text else colors.cardBorder, pill)
                    .clickable(role = Role.Tab) { onSelect(filter) }
                    .semantics { this.selected = on }
                    .padding(horizontal = 11.dp, vertical = 6.dp),
            )
        }
    }
}

/**
 * A story card (hero glass): the gold eyebrow, the AI's title in display type, the tone bar, the
 * newest [STORY_ROWS] headlines and "N more ›", which opens the rest in place.
 */
@Composable
private fun StoryCard(news: MemberNews, story: NewsStory, all: Boolean, zone: ZoneId, locale: Locale, onMore: () -> Unit) {
    val colors = Palette
    val rows = news.storyHeadlines(story)
    val shown = if (all) rows else rows.take(STORY_ROWS)
    Column(
        Modifier
            .fillMaxWidth()
            .glass(colors, RoundedCornerShape(22.dp), edge = colors.heroEdge())
            .padding(start = 15.dp, end = 15.dp, top = 14.dp, bottom = 12.dp),
    ) {
        Column(Modifier.semantics(mergeDescendants = true) { heading() }) {
            Text(
                "STORY · ${rows.size} HEADLINES",
                style = FloorType.text(11f, FontWeight.Bold).copy(letterSpacing = 1.sp),
                color = colors.threshold,
            )
            Text(
                story.title.uppercase(),
                style = FloorType.display(24f, FloorType.Face.BLACK_ITALIC).copy(lineHeight = 1.em),
                color = colors.text,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        ToneBar(story.tone, Modifier.padding(top = 10.dp, bottom = 6.dp))
        shown.forEach { HeadlineRow(it, zone, locale) }
        val more = rows.size - shown.size
        if (more > 0) {
            Text(
                "$more more ›",
                style = FloorType.text(12.5f, FontWeight.SemiBold),
                color = colors.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(role = Role.Button, onClick = onMore)
                    .semantics { contentDescription = "Show $more more headlines in this story" }
                    .padding(vertical = 4.dp),
            )
        }
    }
}
