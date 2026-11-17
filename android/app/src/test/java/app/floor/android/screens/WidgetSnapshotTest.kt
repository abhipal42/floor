package app.floor.android.screens

import android.app.Activity
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.compose
import app.floor.android.Fixtures
import app.floor.android.model.Delegation
import app.floor.android.model.MemberVotes
import app.floor.android.widget.LatestFinalWidget
import app.floor.android.widget.MembersWidget
import app.floor.android.widget.WidgetContent
import app.floor.android.widget.WidgetMembers
import app.floor.android.widget.WidgetSnapshot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.Instant

/**
 * The two home-screen widgets, drawn the way the launcher draws them: Glance composes the
 * RemoteViews, which are applied to a view and captured. Light and dark follow the system, as the
 * widgets do. The content is the recorded TX-37 records (iOS's `WidgetSnapshot.sample`).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class WidgetSnapshotTest {
    private val fetched = Instant.ofEpochSecond(1_794_528_000)

    private val tx37: WidgetContent
        get() {
            val records = mapOf("D000399" to "doggett", "C001056" to "cornyn", "C001098" to "cruz")
                .mapValues { Fixtures.decode("member-votes-${it.value}-40", MemberVotes.serializer()).votes }
            val who = WidgetMembers.of(Fixtures.decode("reps-location-austin", Delegation.serializer()))
            return WidgetContent.Loaded(WidgetSnapshot.make(who, records, fetched))
        }

    private fun snap(name: String, widget: GlanceAppWidget, size: DpSize) {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val views = runBlocking { widget.compose(activity, size = size) }
        val density = activity.resources.displayMetrics.density
        val width = (size.width.value * density).toInt()
        val height = (size.height.value * density).toInt()
        // The launcher's cell: the widget's own views at exactly its size, on a neutral ground.
        val host = FrameLayout(activity)
        host.addView(views.apply(activity, host), FrameLayout.LayoutParams(width, height))
        activity.setContentView(host, ViewGroup.LayoutParams(width, height))
        host.captureRoboImage("src/test/snapshots/$name.png")
    }

    private val small = DpSize(170.dp, 170.dp)
    private val medium = DpSize(364.dp, 170.dp)

    @Test
    @Config(qualifiers = "w420dp-h400dp-notnight-xhdpi")
    fun latestFinalLight() = snap("widgetLatestFinal.light", LatestFinalWidget(content = { tx37 }, now = { fetched }), small)

    @Test
    @Config(qualifiers = "w420dp-h400dp-night-xhdpi")
    fun latestFinalDark() = snap("widgetLatestFinal.dark", LatestFinalWidget(content = { tx37 }, now = { fetched }), small)

    @Test
    @Config(qualifiers = "w420dp-h400dp-notnight-xhdpi")
    fun membersLight() = snap("widgetMembers.light", MembersWidget(content = { tx37 }, now = { fetched }), medium)

    @Test
    @Config(qualifiers = "w420dp-h400dp-night-xhdpi")
    fun membersDark() = snap("widgetMembers.dark", MembersWidget(content = { tx37 }, now = { fetched }), medium)

    /** Hours old: "As of 7:00 PM" in the header. */
    @Test
    @Config(qualifiers = "w420dp-h400dp-notnight-xhdpi")
    fun membersStale() = snap("widgetMembersStale.light", MembersWidget(content = { tx37 }, now = { fetched.plusSeconds(3 * 3600 + 60) }), medium)

    @Test
    @Config(qualifiers = "w420dp-h400dp-notnight-xhdpi")
    fun noMembers() = snap("widgetNoMembers.light", LatestFinalWidget(content = { WidgetContent.NoMembers }), small)

    @Test
    @Config(qualifiers = "w420dp-h400dp-night-xhdpi")
    fun failed() = snap("widgetFailed.dark", MembersWidget(content = { WidgetContent.Failed }), medium)
}
