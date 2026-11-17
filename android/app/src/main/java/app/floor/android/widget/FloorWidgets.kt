package app.floor.android.widget

import android.content.Context
import android.content.Intent
import androidx.core.net.toUri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontFamily
import androidx.glance.text.FontStyle
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import app.floor.android.BuildConfig
import app.floor.android.MainActivity
import app.floor.android.R
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.design.FloorColors
import app.floor.android.design.outcome
import app.floor.android.model.outcome
import app.floor.android.model.FloorLink
import app.floor.android.model.Position
import app.floor.android.model.VoteKind
import app.floor.android.store.DeviceStore
import okhttp3.OkHttpClient
import java.io.File
import java.time.Instant
import java.util.concurrent.TimeUnit

// The two home-screen widgets (iOS `FloorWidgets`, section "D · Widgets" of
// https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn): small, the latest final in your members'
// records; medium, your three members' latest votes. What they show is built and tested in
// `WidgetFeed.kt`; this file is Glance and drawing only.
//
// Where Android differs, and why: Glance draws through RemoteViews, which cannot carry the app's
// bundled fonts, so headlines are the system's condensed sans rather than Barlow Condensed. The
// header's glyph is the app icon's F rather than iOS's chamber glyph. The medium widget has no
// member pick (iOS's Edit Widget menu): it shows your reps, else the first three you follow.

/** Loads what a widget shows: your district and follows from the app's store, votes through its cache. */
private suspend fun loadContent(context: Context): WidgetContent {
    val device = DeviceStore(context)
    // The app's own cache directory, so the widget opens on what the app last saw and saves what it fetches.
    val api = FloorApi(
        BuildConfig.API_BASE_URL,
        client = OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build(),
        cache = FileResponseCache(File(context.cacheDir, "responses")),
    )
    return WidgetFeed.load(api, WidgetMembers.of(device.load(), device.loadFollows()))
}

/** Small: the newest final vote any of your members took part in, and how one of them voted. */
class LatestFinalWidget(
    private val content: suspend (Context) -> WidgetContent = ::loadContent,
    private val now: () -> Instant = Instant::now,
) : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val shown = content(context)
        provideContent { LatestFinal(context, shown, now()) }
    }
}

/** Medium: your three members' most recent votes. */
class MembersWidget(
    private val content: suspend (Context) -> WidgetContent = ::loadContent,
    private val now: () -> Instant = Instant::now,
) : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val shown = content(context)
        provideContent { Members(context, shown, now()) }
    }
}

class LatestFinalWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = LatestFinalWidget()
}

class MembersWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MembersWidget()
}

object FloorWidgets {
    /**
     * Redraws every placed widget: the app calls it when it goes to the background, so a change of
     * district or follows reaches the home screen without waiting for the 30-minute refresh.
     */
    suspend fun updateAll(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        if (manager.getGlanceIds(LatestFinalWidget::class.java).isNotEmpty()) LatestFinalWidget().updateAll(context)
        if (manager.getGlanceIds(MembersWidget::class.java).isNotEmpty()) MembersWidget().updateAll(context)
    }
}

// MARK: - Small

@Composable
private fun LatestFinal(context: Context, content: WidgetContent, now: Instant) {
    when (content) {
        is WidgetContent.Loaded -> {
            val final = content.snapshot.latestFinal
            if (final == null) {
                Message(context, "Final", "No finals yet", "Your members' next vote shows here.")
            } else {
                SmallCard(context, final, WidgetText.asOf(content.snapshot.fetchedAt, now))
            }
        }
        WidgetContent.NoMembers -> NoMembers(context)
        WidgetContent.Failed -> Failed(context)
    }
}

@Composable
private fun SmallCard(context: Context, final: WidgetSnapshot.Final, asOf: String?) {
    val vote = final.vote
    val (left, right) = WidgetText.score(vote)
    Surface(
        context, FloorLink.Vote(vote.id),
        listOfNotNull(WidgetText.smallLabel(final), asOf?.let { "$it." }).joinToString(" "),
    ) {
        Header(WidgetText.smallHeader(vote))
        Spacer(GlanceModifier.height(7.dp))
        Text(WidgetText.citation(vote, final.measure).uppercase(), style = display(20.sp, Tokens.text), maxLines = 1)
        WidgetText.resultWord(vote)?.let { word ->
            val tint = if (vote.kind == VoteKind.ELECTION) Tokens.textSecondary else Tokens.pair { outcome(vote.outcome) }
            Text(word, style = display(12.sp, tint), maxLines = 1)
        }
        Spacer(GlanceModifier.defaultWeight())
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Score(left)
            Spacer(GlanceModifier.defaultWeight())
            // A one-candidate Speaker ballot has no second number to show.
            right?.let { Score(it, alignEnd = true) }
        }
        Spacer(GlanceModifier.height(7.dp))
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            PositionChip(final.call.position, final.call.choice)
            Spacer(GlanceModifier.width(6.dp))
            Text(final.call.member.lastName, style = text(11.sp, Tokens.textSecondary), maxLines = 1)
            if (asOf != null) {
                Spacer(GlanceModifier.defaultWeight())
                Text(asOf, style = text(9.sp, Tokens.textMuted), maxLines = 1)
            }
        }
    }
}

@Composable
private fun Score(score: WidgetText.Score, alignEnd: Boolean = false) {
    val tint = when (score.side) {
        WidgetText.Side.YEA -> Tokens.yea
        WidgetText.Side.NAY -> Tokens.nay
        null -> Tokens.text
    }
    Column(horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start) {
        Text(score.value.toString(), style = display(32.sp, tint, italic = true), maxLines = 1)
        // Yea and nay say which is which by colour; two Speaker candidates need their names.
        if (score.side == null && score.label.isNotEmpty()) {
            Text(score.label, style = text(10.sp, Tokens.textMuted), maxLines = 1)
        }
    }
}

// MARK: - Medium

@Composable
private fun Members(context: Context, content: WidgetContent, now: Instant) {
    when (content) {
        is WidgetContent.Loaded -> MemberRows(context, content.snapshot, WidgetText.asOf(content.snapshot.fetchedAt, now))
        WidgetContent.NoMembers -> NoMembers(context)
        WidgetContent.Failed -> Failed(context)
    }
}

@Composable
private fun MemberRows(context: Context, snapshot: WidgetSnapshot, asOf: String?) {
    val rows = snapshot.mediumRows
    val header = WidgetText.header(snapshot)
    // A tap outside a row opens the newest of the votes shown.
    val newest = rows.mapNotNull { it.latest?.vote }.maxByOrNull { it.occurredAtInstant ?: Instant.MIN }
    Surface(
        context, newest?.let { FloorLink.Vote(it.id) } ?: FloorLink.Open,
        (listOf("$header.") + rows.map { WidgetText.rowLabel(it) } + listOfNotNull(asOf?.let { "$it." })).joinToString(" "),
    ) {
        Header(header, trailing = asOf)
        Spacer(GlanceModifier.height(7.dp))
        rows.forEach { row ->
            val latest = row.latest
            Row(
                GlanceModifier.fillMaxWidth().padding(vertical = 3.dp)
                    .then(if (latest != null) GlanceModifier.clickable(open(context, FloorLink.Vote(latest.vote.id))) else GlanceModifier),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (latest != null) PositionChip(latest.position, latest.choice) else Text("—", style = display(11.sp, Tokens.textMuted))
                Spacer(GlanceModifier.width(8.dp))
                Text(row.member.lastName.uppercase(), style = display(15.sp, Tokens.text, italic = true), maxLines = 1)
                Spacer(GlanceModifier.width(6.dp))
                Text(WidgetText.detail(row), style = text(11.5.sp, Tokens.textSecondary), maxLines = 1, modifier = GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(8.dp))
                Text(latest?.let { WidgetText.day(it.vote) } ?: "", style = text(11.5.sp, Tokens.textMuted), maxLines = 1)
            }
        }
        WidgetText.loneMemberNote(snapshot)?.let {
            Spacer(GlanceModifier.height(4.dp))
            Text(it, style = text(11.sp, Tokens.textMuted), maxLines = 2)
        }
    }
}

// MARK: - Pieces

@Composable
private fun NoMembers(context: Context) =
    Message(context, "Floor", "Open Floor to pick your members", "Your district and who you follow stay on this phone.")

@Composable
private fun Failed(context: Context) = Message(context, "Floor", "Couldn't reach Floor", "Trying again in a few minutes.")

/** Empty and error states: tapping opens the app. */
@Composable
private fun Message(context: Context, header: String, title: String, detail: String) {
    Surface(context, FloorLink.Open, "$title. $detail") {
        Header(header)
        Spacer(GlanceModifier.defaultWeight())
        Text(title, style = display(18.sp, Tokens.text, italic = true))
        Text(detail, style = text(11.sp, Tokens.textMuted))
    }
}

/** The widget's ground, its padding, its one tap target and its one spoken line. */
@Composable
private fun Surface(context: Context, link: FloorLink, spoken: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(Tokens.widget)
            .cornerRadius(16.dp)
            .padding(14.dp)
            .clickable(open(context, link))
            .semantics { contentDescription = spoken },
    ) { content() }
}

/** The glyph and the tracked-out caps line: `FINAL · HOUSE`, `YOUR MEMBERS · TX-37`. */
@Composable
private fun Header(text: String, trailing: String? = null) {
    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Box(GlanceModifier.size(16.dp).background(Tokens.flapBoard).cornerRadius(4.dp), contentAlignment = Alignment.Center) {
            Image(
                ImageProvider(R.drawable.ic_launcher_foreground), contentDescription = null,
                colorFilter = ColorFilter.tint(ColorProvider(Color.White)), modifier = GlanceModifier.size(16.dp),
            )
        }
        Spacer(GlanceModifier.width(6.dp))
        Text(text.uppercase(), style = display(11.sp, Tokens.textMuted), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        trailing?.let { Text(it, style = text(10.sp, Tokens.textMuted), maxLines = 1) }
    }
}

/** The YEA / NAY / DNV / PRESENT chip, or a Speaker candidate's name. */
@Composable
private fun PositionChip(position: Position, choice: String?) {
    val fill = when (position) {
        Position.YEA -> Tokens.yea
        Position.NAY -> Tokens.nay
        Position.PRESENT, Position.NOT_VOTING -> Tokens.textMuted
        Position.CANDIDATE -> Tokens.text
    }
    Box(GlanceModifier.background(fill).cornerRadius(4.dp).padding(horizontal = 6.dp, vertical = 3.dp)) {
        Text(WidgetText.chip(position, choice), style = display(11.sp, Tokens.ground), maxLines = 1)
    }
}

private fun open(context: Context, link: FloorLink): Action =
    actionStartActivity(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(link.url.toUri()))

/** Barlow Condensed's stand-in: RemoteViews can name only a system family. */
private val condensed = FontFamily("sans-serif-condensed")

private fun display(size: TextUnit, color: ColorProvider, italic: Boolean = false) =
    TextStyle(color = color, fontSize = size, fontWeight = FontWeight.Bold, fontFamily = condensed, fontStyle = if (italic) FontStyle.Italic else FontStyle.Normal)

private fun text(size: TextUnit, color: ColorProvider) = TextStyle(color = color, fontSize = size, fontWeight = FontWeight.Medium)

/** Floor's tokens as day/night pairs: a widget follows the system's dark mode, not the app's setting. */
private object Tokens {
    private val light = FloorColors(isDark = false)
    private val dark = FloorColors(isDark = true)
    fun pair(pick: FloorColors.() -> Color) = ColorProvider(day = light.pick(), night = dark.pick())

    val widget = pair { widget }
    val ground = pair { ground }
    val text = pair { text }
    val textSecondary = pair { textSecondary }
    val textMuted = pair { textMuted }
    val yea = pair { yea }
    val nay = pair { nay }
    val flapBoard = pair { flapBoard }
}
