package app.floor.android

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.viewmodel.compose.viewModel
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.home.HomeModel
import app.floor.android.home.HomeScreen
import app.floor.android.shell.FloorScreens
import app.floor.android.shell.FloorShell
import app.floor.android.bill.BillModel
import app.floor.android.bill.BillScreen
import app.floor.android.bill.BillScreenState
import app.floor.android.bill.SpeakUpSheet
import app.floor.android.bills.BillsModel
import app.floor.android.bills.BillsScreen
import app.floor.android.bills.TopicModel
import app.floor.android.bills.TopicScreen
import app.floor.android.design.Palette
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.saveable.rememberSaveable
import app.floor.android.vote.VoteKindsModel
import app.floor.android.vote.VoteKindsScreen
import app.floor.android.vote.VoteModel
import app.floor.android.vote.VoteScreen
import java.time.ZoneId
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Every response a screen reads is saved, so the app opens on what it last showed when
        // offline or slow, then refreshes.
        val api = FloorApi(BuildConfig.API_BASE_URL, cache = FileResponseCache(File(cacheDir, "responses")))
        setContent {
            var appearance by remember { mutableStateOf(Appearance.load(this)) }
            val dark = when (appearance) {
                Appearance.SYSTEM -> isSystemInDarkTheme()
                Appearance.LIGHT -> false
                Appearance.DARK -> true
            }
            // Edge to edge, with the status and navigation bar icons following Floor's appearance
            // rather than only the system's.
            LaunchedEffect(dark) {
                val style = if (dark) {
                    SystemBarStyle.dark(Color.TRANSPARENT)
                } else {
                    SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                }
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            FloorTheme(appearance) {
                FloorShell(
                    FloorScreens(
                        finals = { onOpenVote ->
                            val model: HomeModel = viewModel { HomeModel(api) }
                            LaunchedEffect(Unit) { model.appear() }
                            HomeScreen(
                                state = model.state,
                                appearance = appearance,
                                onAppearance = {
                                    appearance = it
                                    Appearance.save(this, it)
                                },
                                onFilter = model::select,
                                onRetry = model::reload,
                                onRefresh = model::refresh,
                                onOpenVote = onOpenVote,
                            )
                        },
                        bills = { onOpenBill, onOpenTopic ->
                            val model: BillsModel = viewModel { BillsModel(api) }
                            LaunchedEffect(Unit) { model.appear() }
                            BillsScreen(
                                state = model.state,
                                onQuery = model::type,
                                onSubmit = { model.type(model.state.search.query) },
                                onRetry = model::reloadTopics,
                                onOpenBill = onOpenBill,
                                onOpenTopic = onOpenTopic,
                            )
                        },
                        vote = { id, back, onOpenKinds, onOpenBill, onBack ->
                            // Scoped to its back-stack entry, so each vote on the stack keeps its own.
                            val model: VoteModel = viewModel { VoteModel(api, id) }
                            LaunchedEffect(id) { model.appear() }
                            VoteScreen(
                                state = model.state,
                                // The reader's own zone and locale, passed rather than read inside (lesson 69).
                                zone = ZoneId.systemDefault(),
                                locale = LocalConfiguration.current.locales[0],
                                onBack = onBack,
                                onRetry = model::reload,
                                onToggleExplainer = model::toggleExplainer,
                                onOpenKinds = onOpenKinds,
                                onSelectRollParty = model::selectRollParty,
                                onOpenMeasure = { onOpenBill(it.id) },
                                back = back,
                            )
                        },
                        voteKinds = { onBack ->
                            val model: VoteKindsModel = viewModel { VoteKindsModel(api) }
                            LaunchedEffect(Unit) { model.appear() }
                            VoteKindsScreen(model.state, onBack)
                        },
                        bill = { id, back, onOpenVote, onOpenTopic, onBack ->
                            // No district on Android until the "Your three" phase: Speak up says to set one.
                            val model: BillModel = viewModel { BillModel(api, id, delegation = null) }
                            LaunchedEffect(id) { model.appear() }
                            var speakingUp by rememberSaveable { mutableStateOf(false) }
                            BillScreen(
                                state = model.state,
                                back = back,
                                zone = ZoneId.systemDefault(),
                                locale = LocalConfiguration.current.locales[0],
                                onBack = onBack,
                                onRetry = model::reload,
                                onToggleCitation = model::toggleCitation,
                                onRetryAnalysis = model::retryAnalysis,
                                onOpenVote = { onOpenVote(it.id) },
                                onOpenTopic = onOpenTopic,
                                onSpeakUp = { speakingUp = true },
                            )
                            val bill = (model.state.phase as? BillScreenState.Phase.Loaded)?.bill
                            if (speakingUp && bill != null) {
                                ModalBottomSheet(
                                    onDismissRequest = { speakingUp = false },
                                    sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                                    containerColor = Palette.ground,
                                ) {
                                    SpeakUpSheet(model.state.facts(bill), model.delegation, contact = model::contact)
                                }
                            }
                        },
                        topic = { name, back, onOpenBill, onBack ->
                            val model: TopicModel = viewModel { TopicModel(api, name) }
                            LaunchedEffect(name) { model.appear() }
                            TopicScreen(
                                state = model.state,
                                back = back,
                                onBack = onBack,
                                onSelect = model::select,
                                onRetry = model::reload,
                                onLoadMore = model::loadMore,
                                onOpenBill = onOpenBill,
                            )
                        },
                    ),
                )
            }
        }
    }
}
