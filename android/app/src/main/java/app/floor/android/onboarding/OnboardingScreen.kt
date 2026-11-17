package app.floor.android.onboarding

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.em
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import app.floor.android.design.FloorType
import app.floor.android.design.MemberPortrait
import app.floor.android.design.Palette
import app.floor.android.model.Chamber
import app.floor.android.model.Member
import app.floor.android.model.Reps
import app.floor.android.model.StateName
import app.floor.android.model.seatCaption

/**
 * The onboarding screen with the platform behind it: the location permission (asked only when "Use
 * my location" is tapped, never at launch), the one fix, and the trip to Settings and back.
 */
@Composable
fun OnboardingRoute(model: OnboardingModel, location: AndroidLocation, onSkip: (() -> Unit)?, onFinished: (app.floor.android.model.Delegation) -> Unit) {
    val context = LocalContext.current
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { model.useLocation(location.access()) }
    // Back from Settings with the "location is off" banner up: they went to turn it on, so try again.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        val notice = model.state.notice
        if ((notice == OnboardingState.Notice.LOCATION_OFF || notice == OnboardingState.Notice.SERVICES_OFF) &&
            location.access().let { it == LocationAccess.PRECISE || it == LocationAccess.APPROXIMATE }
        ) {
            model.useLocation(location.access())
        }
    }
    OnboardingScreen(
        state = model.state,
        onType = model::type,
        onLookUp = { model.lookUp() },
        onLocate = {
            when (val access = location.access()) {
                LocationAccess.DENIED -> ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                else -> model.useLocation(access)
            }
        },
        onOpenSettings = {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
        },
        onConfirm = { model.confirm()?.let(onFinished) },
        onTypeAddressInstead = model::typeAddressInstead,
        onSkip = onSkip,
    )
}

/**
 * "Pull your three." (iOS `OnboardingView`, the locked LocApp mock): your location or an address
 * finds your district, the members it resolves to are dealt as cards, and "Deal me in" keeps the
 * district on this phone. The address and the location are each used for one request and dropped.
 */
@Composable
fun OnboardingScreen(
    state: OnboardingState,
    onType: (String) -> Unit,
    onLookUp: () -> Unit,
    onLocate: () -> Unit,
    onOpenSettings: () -> Unit,
    onConfirm: () -> Unit,
    onTypeAddressInstead: () -> Unit,
    onSkip: (() -> Unit)?,
) {
    val colors = Palette
    val focus = LocalFocusManager.current
    Box(Modifier.fillMaxSize().background(colors.ground)) {
        Box(Modifier.fillMaxWidth().height(420.dp).background(Brush.verticalGradient(listOf(colors.groundGlow, colors.ground))))
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).imePadding()) {
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Text("FLOOR", style = FloorType.headline(30f), color = colors.text)
                // One text at the mock's 0.84 line height, trimmed so the lines sit as tight as the mock's.
                val big = FloorType.headline(68f).copy(
                    lineHeight = 0.84.em,
                    lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.Both),
                )
                Text(
                    buildAnnotatedString {
                        append("PULL YOUR\n")
                        withStyle(SpanStyle(color = colors.yea)) { append("THREE.") }
                    },
                    style = big, color = colors.text, maxLines = 2,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    "Your location or address finds your district. Floor keeps the district and drops the rest.",
                    style = FloorType.text(16f), color = colors.textSecondary,
                )
                if (state.offersLocation) Locate {
                    focus.clearFocus()
                    onLocate()
                }
                state.notice?.let { Banner(it, onOpenSettings) }
                if (state.showsAddressField) AddressField(state, onType) {
                    focus.clearFocus()
                    onLookUp()
                }
                when (val phase = state.phase) {
                    OnboardingState.Phase.Looking -> Skeleton()
                    is OnboardingState.Phase.Found -> Dealt(phase.reps, state.source == OnboardingState.Source.LOCATION, onTypeAddressInstead)
                    else -> {}
                }
            }
            Column(
                Modifier.windowInsetsPadding(WindowInsets.navigationBars).padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val found = state.phase is OnboardingState.Phase.Found
                val looking = state.phase == OnboardingState.Phase.Looking
                Text(
                    if (found) "Deal me in" else if (looking) "Finding…" else "Find my three",
                    style = FloorType.text(16f, FontWeight.Bold),
                    color = colors.ground,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(colors.yea)
                        .clickable(enabled = !looking, role = Role.Button) {
                            focus.clearFocus()
                            if (found) onConfirm() else onLookUp()
                        }
                        .padding(17.dp),
                )
                if (onSkip != null) {
                    Text(
                        "Skip, I'll pick members myself",
                        style = FloorType.text(14f, FontWeight.SemiBold),
                        color = colors.textSecondary,
                        modifier = Modifier.clickable(enabled = !looking, role = Role.Button, onClick = onSkip).padding(4.dp),
                    )
                }
                Text(
                    "Floor keeps the district and drops the street — and the location.",
                    style = FloorType.text(11f), color = colors.textFaint, textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun Locate(onClick: () -> Unit) {
    val colors = Palette
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(colors.panel)
                .border(1.dp, colors.yea, RoundedCornerShape(14.dp))
                .clickable(role = Role.Button, onClick = onClick)
                .padding(15.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The mock's glyph: a dot in a ring.
            val yea = colors.yea
            Canvas(Modifier.size(16.dp).clearAndSetSemantics { }) {
                val c = Offset(size.width / 2, size.height / 2)
                drawCircle(yea, 3.dp.toPx(), c)
                drawCircle(yea, 6.2.dp.toPx(), c, style = Stroke(1.6.dp.toPx()))
            }
            Spacer(Modifier.size(10.dp))
            Text("Use my location", style = FloorType.text(16f, FontWeight.Bold), color = colors.text)
        }
        Text("or type an address", style = FloorType.text(12f), color = colors.textMuted)
    }
}

@Composable
private fun Banner(notice: OnboardingState.Notice, onOpenSettings: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(colors.warningPanel, shape).border(1.dp, colors.warningBorder, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(notice.title, style = FloorType.text(13f, FontWeight.Bold), color = colors.nay)
        Text(notice.body, style = FloorType.text(13f), color = colors.textSecondary)
        if (notice.opensSettings) {
            Text("Open Settings ›", style = FloorType.text(13f, FontWeight.SemiBold), color = colors.yea,
                modifier = Modifier.clickable(role = Role.Button, onClick = onOpenSettings))
        }
    }
}

@Composable
private fun AddressField(state: OnboardingState, onType: (String) -> Unit, onSubmit: () -> Unit) {
    val colors = Palette
    val shape = RoundedCornerShape(12.dp)
    val failure = state.failure
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Your address", style = FloorType.text(13f, FontWeight.Bold), color = colors.text)
        Box(
            Modifier.fillMaxWidth().clip(shape).background(colors.panel, shape)
                .border(1.dp, if (failure == null) colors.panelBorder else colors.liveText, shape).padding(15.dp),
        ) {
            val style = FloorType.text(15f)
            if (state.address.isEmpty()) Text("1100 Congress Ave, Austin, TX 78701", style = style, color = colors.textMuted, maxLines = 1)
            BasicTextField(
                value = state.address,
                onValueChange = onType,
                singleLine = true,
                textStyle = style.copy(color = colors.text),
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, autoCorrectEnabled = false, imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Your address" },
            )
        }
        if (failure != null) Text(failure, style = FloorType.text(13f), color = colors.liveText)
    }
}

@Composable
private fun Skeleton() {
    val colors = Palette
    Column(Modifier.clearAndSetSemantics { contentDescription = "Finding your district" }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("FINDING YOUR DISTRICT…", style = FloorType.text(12f, FontWeight.Bold), color = colors.textMuted)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            repeat(3) { Box(Modifier.weight(1f).height(150.dp).clip(RoundedCornerShape(12.dp)).background(colors.card)) }
        }
    }
}

@Composable
private fun Dealt(reps: Reps, fromLocation: Boolean, onTypeAddressInstead: () -> Unit) {
    val colors = Palette
    val large = LocalDensity.current.fontScale >= 1.5f
    // Representative first, then senators, as the mock deals them.
    val members = reps.members.filter { it.chamber == Chamber.HOUSE } + reps.members.filter { it.chamber == Chamber.SENATE }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(StateName.districtName(reps.district.state, reps.district.district).uppercase(), style = FloorType.text(12f, FontWeight.Bold), color = colors.yea)
        if (large) {
            // A third of the width cannot hold a surname and a seat at these sizes: one card per row.
            members.forEach { MemberCard(it, Modifier.fillMaxWidth()) }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                members.forEach { MemberCard(it, Modifier.weight(1f)) }
                // Always three columns: D.C.'s one card keeps a card's width.
                repeat(maxOf(0, 3 - members.size)) { Spacer(Modifier.weight(1f)) }
            }
        }
        OnboardingState.singleMemberNote(reps)?.let { Text(it, style = FloorType.text(12f), color = colors.textSecondary) }
        if (fromLocation) {
            Text(
                "Not your district? Type an address",
                style = FloorType.text(12f).copy(textDecoration = TextDecoration.Underline), color = colors.textMuted,
                modifier = Modifier.clickable(role = Role.Button, onClick = onTypeAddressInstead),
            )
        }
    }
}

@Composable
private fun MemberCard(member: Member, modifier: Modifier) {
    val colors = Palette
    Box(
        modifier.clip(RoundedCornerShape(12.dp)).background(Brush.linearGradient(colors.silver)).padding(3.dp)
            .clearAndSetSemantics { contentDescription = app.floor.android.model.SpokenMember.member(member) },
    ) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(colors.panel)) {
            MemberPortrait(member, Modifier.fillMaxWidth().height(96.dp), cornerRadius = 0.dp)
            Column(Modifier.padding(6.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(member.lastName.uppercase(), style = FloorType.label(15f), color = colors.text, maxLines = 1)
                Text(member.seatCaption, style = FloorType.text(9f), color = colors.textMuted)
            }
        }
    }
}
