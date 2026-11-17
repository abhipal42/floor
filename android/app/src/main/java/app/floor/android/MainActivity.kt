package app.floor.android

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.viewmodel.compose.viewModel
import app.floor.android.api.FileResponseCache
import app.floor.android.api.FloorApi
import app.floor.android.bill.BillFollow
import app.floor.android.bill.BillModel
import app.floor.android.bill.BillScreen
import app.floor.android.bill.BillScreenState
import app.floor.android.bill.SpeakUpSheet
import app.floor.android.bills.BillsModel
import app.floor.android.bills.BillsScreen
import app.floor.android.bills.FollowActions
import app.floor.android.bills.TopicModel
import app.floor.android.bills.TopicScreen
import app.floor.android.design.Appearance
import app.floor.android.design.FloorTheme
import app.floor.android.design.Palette
import app.floor.android.following.AddFollows
import app.floor.android.following.FollowingActions
import app.floor.android.following.FollowingScreen
import app.floor.android.following.FollowingSegment
import app.floor.android.following.FollowingState
import app.floor.android.following.PostsWallModel
import app.floor.android.home.HomeModel
import app.floor.android.home.HomeScreen
import app.floor.android.model.FloorLink
import app.floor.android.week.WeekModel
import app.floor.android.widget.FloorWidgets
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import app.floor.android.week.WeekScreen
import android.content.Intent
import app.floor.android.member.ElectModel
import app.floor.android.member.ElectScreen
import app.floor.android.member.MemberFollow
import app.floor.android.member.MemberModel
import app.floor.android.member.MemberScreen
import app.floor.android.onboarding.AndroidLocation
import app.floor.android.onboarding.OnboardingModel
import app.floor.android.onboarding.OnboardingRoute
import app.floor.android.shell.FloorScreens
import app.floor.android.shell.FloorShell
import app.floor.android.shell.LocalNavigate
import app.floor.android.shell.Routes
import app.floor.android.store.DeviceStore
import app.floor.android.store.Session
import app.floor.android.vote.VoteKindsModel
import app.floor.android.vote.VoteKindsScreen
import app.floor.android.vote.VoteModel
import app.floor.android.vote.VoteScreen
import java.io.File
import java.time.ZoneId

@OptIn(ExperimentalMaterial3Api::class)
class MainActivity : ComponentActivity() {
    /** A link the app was opened with and has not shown yet: a shared bill, or the widget's vote. */
    private var link by mutableStateOf<FloorLink?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreated (a rotation, a theme change), the intent is the one already shown.
        if (savedInstanceState == null) link = FloorLink.parse(intent?.dataString ?: "")
        // Every response a screen reads is saved, so the app opens on what it last showed when
        // offline or slow, then refreshes.
        val api = FloorApi(BuildConfig.API_BASE_URL, cache = FileResponseCache(File(cacheDir, "responses")))
        // Your district and what you follow, on this phone only (DataStore, out of backups).
        val device = DeviceStore(this)
        val session = Session(device, device)
        val location = AndroidLocation(this)
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
                if (session.onboarding) {
                    val model: OnboardingModel = viewModel(key = "onboarding") { OnboardingModel(api, location) }
                    if (session.changingAddress) BackHandler { session.closeOnboarding() }
                    OnboardingRoute(
                        model, location,
                        onSkip = if (session.changingAddress) null else session::skip,
                        onFinished = session::finish,
                    )
                } else {
                    App(api, session, appearance, link, onLinkHandled = { link = null }) {
                        appearance = it
                        Appearance.save(this, it)
                    }
                }
            }
        }
    }

    /** Leaving the app: the widgets redraw from what it now holds (a new district, a follow). */
    override fun onStop() {
        super.onStop()
        lifecycleScope.launch { FloorWidgets.updateAll(applicationContext) }
    }

    /** A link while the app is open: the widget tapped, or a shared bill opened from another app. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        link = FloorLink.parse(intent.dataString ?: "")
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun App(
    api: FloorApi,
    session: Session,
    appearance: Appearance,
    link: FloorLink?,
    onLinkHandled: () -> Unit,
    onAppearance: (Appearance) -> Unit,
) {
    // Finals and Following share one feed: the Following tab's rings and latest votes come from it.
    val home: HomeModel = viewModel(key = "home") { HomeModel(api, session) }
    val follows = session.follows
    val followActions = FollowActions(
        follows.state, session.reps.map { it.bioguideId }.toSet(),
        onMember = follows::toggle, onBill = follows::toggle, onTopic = follows::toggleTopic,
    )
    val zone = ZoneId.systemDefault()
    val locale = LocalConfiguration.current.locales[0]
    FloorShell(
        FloorScreens(
            finals = { onOpenVote ->
                val navigate = LocalNavigate.current
                LaunchedEffect(home.syncKey) { home.appear() }
                HomeScreen(
                    state = home.state,
                    appearance = appearance,
                    onAppearance = onAppearance,
                    onFilter = home::select,
                    onRetry = home::reload,
                    onRefresh = home::refresh,
                    onOpenVote = onOpenVote,
                    onScope = home::selectScope,
                    onOpenMember = { navigate(Routes.member(it.bioguideId)) },
                    onOpenElect = { navigate(Routes.elect(it)) },
                    onFindReps = session::findReps,
                )
            },
            week = { onOpenBill ->
                val model: WeekModel = viewModel { WeekModel(api) }
                LaunchedEffect(Unit) { model.appear() }
                WeekScreen(
                    state = model.state,
                    follows = follows.state,
                    onWeek = model::show,
                    onChamber = model::select,
                    onExpand = model::expand,
                    onRetry = model::reload,
                    onOpenBill = onOpenBill,
                )
            },
            bills = { onOpenBill, onOpenTopic ->
                val navigate = LocalNavigate.current
                val model: BillsModel = viewModel { BillsModel(api) }
                LaunchedEffect(Unit) { model.appear() }
                BillsScreen(
                    state = model.state,
                    onQuery = model::type,
                    onSubmit = { model.type(model.state.search.query) },
                    onRetry = model::reloadTopics,
                    onOpenBill = onOpenBill,
                    onOpenTopic = onOpenTopic,
                    onChamber = model::selectChamber,
                    onOpenMember = { navigate(Routes.member(it.bioguideId)) },
                    onOpenElect = { navigate(Routes.elect(it)) },
                    follow = followActions,
                )
            },
            following = {
                val navigate = LocalNavigate.current
                val topics: BillsModel = viewModel(key = "following-topics") { BillsModel(api) }
                var segment by rememberSaveable { mutableStateOf(FollowingSegment.MEMBERS) }
                var editing by rememberSaveable { mutableStateOf(false) }
                var adding by rememberSaveable { mutableStateOf(false) }
                LaunchedEffect(home.syncKey) { home.appear() }
                LaunchedEffect(segment) { if (segment == FollowingSegment.TOPICS) topics.appear() }
                val wall: PostsWallModel = viewModel(key = "posts-wall") { PostsWallModel(api) }
                val followingState = FollowingState(
                    follows = follows.state, delegation = session.delegation, segment = segment, editing = editing,
                    loyalty = home.state.loyalty, records = home.records, topics = topics.state.topics, wall = wall.state,
                )
                val wallIds = followingState.wallMembers.map { it.bioguideId }
                LaunchedEffect(segment, wallIds) { if (segment == FollowingSegment.POSTS) wall.appear(wallIds) }
                FollowingScreen(
                    followingState,
                    FollowingActions(
                        onSegment = {
                            segment = it
                            editing = false
                        },
                        onEditing = { editing = it },
                        onAdd = { adding = true },
                        onUpdate = follows::update,
                        onOpenMember = { navigate(Routes.member(it.bioguideId)) },
                        onOpenBill = { navigate(Routes.bill(it)) },
                        onOpenTopic = { navigate(Routes.topic(it)) },
                        onFindReps = session::findReps,
                        onRetryTopics = topics::reloadTopics,
                        onRetryWall = wall::reload,
                    ),
                    zone,
                    locale,
                )
                if (adding) {
                    // A fresh search each time the sheet opens.
                    val search: BillsModel = viewModel(key = "add-search") { BillsModel(api) }
                    fun close(then: () -> Unit) {
                        adding = false
                        search.type("")
                        then()
                    }
                    ModalBottomSheet(
                        onDismissRequest = { close {} },
                        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                        containerColor = Palette.ground,
                    ) {
                        AddFollows(
                            search.state.search, followActions,
                            onQuery = search::type, onSubmit = { search.type(search.state.search.query) }, onChamber = search::selectChamber,
                            onDone = { close {} },
                            onOpenBill = { close { navigate(Routes.bill(it)) } },
                            onOpenTopic = { close { navigate(Routes.topic(it)) } },
                            onOpenMember = { close { navigate(Routes.member(it.bioguideId)) } },
                            onOpenElect = { close { navigate(Routes.elect(it)) } },
                        )
                    }
                }
            },
            vote = { id, back, onOpenKinds, onOpenBill, onBack ->
                val navigate = LocalNavigate.current
                // Scoped to its back-stack entry, so each vote on the stack keeps its own.
                val model: VoteModel = viewModel { VoteModel(api, id, session.yourMembers) }
                LaunchedEffect(id) { model.appear() }
                VoteScreen(
                    state = model.state,
                    // The reader's own zone and locale, passed rather than read inside (lesson 69).
                    zone = zone,
                    locale = locale,
                    onBack = onBack,
                    onRetry = model::reload,
                    onToggleExplainer = model::toggleExplainer,
                    onOpenKinds = onOpenKinds,
                    onSelectRollParty = model::selectRollParty,
                    onOpenMeasure = { onOpenBill(it.id) },
                    back = back,
                    onOpenMember = { navigate(Routes.member(it.bioguideId)) },
                )
            },
            voteKinds = { onBack ->
                val model: VoteKindsModel = viewModel { VoteKindsModel(api) }
                LaunchedEffect(Unit) { model.appear() }
                VoteKindsScreen(model.state, onBack)
            },
            bill = { id, back, onOpenVote, onOpenTopic, onBack ->
                val model: BillModel = viewModel { BillModel(api, id, session.delegation, session.yourMembers) }
                LaunchedEffect(id) { model.appear() }
                var speakingUp by rememberSaveable { mutableStateOf(false) }
                val bill = (model.state.phase as? BillScreenState.Phase.Loaded)?.bill
                // A bill you follow: its saved row (the Following tab's Bills) follows the fresh record.
                LaunchedEffect(bill, model.state.saved) { if (bill != null && model.state.saved == null) follows.refresh(bill) }
                BillScreen(
                    state = model.state,
                    back = back,
                    zone = zone,
                    locale = locale,
                    onBack = onBack,
                    onRetry = model::reload,
                    onToggleCitation = model::toggleCitation,
                    onRetryAnalysis = model::retryAnalysis,
                    onOpenVote = { onOpenVote(it.id) },
                    onOpenTopic = onOpenTopic,
                    onSpeakUp = { speakingUp = true },
                    follow = BillFollow(follows.state.isFollowingBill(id), follows.state::isFollowingTopic) {
                        bill?.let { follows.toggle(app.floor.android.store.listItem(it)) }
                    },
                )
                if (speakingUp && bill != null) {
                    ModalBottomSheet(
                        onDismissRequest = { speakingUp = false },
                        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                        containerColor = Palette.ground,
                    ) {
                        SpeakUpSheet(
                            model.state.facts(bill), session.delegation, contact = model::contact,
                            onSetDistrict = {
                                speakingUp = false
                                session.findReps()
                            },
                        )
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
                    follow = follows.state.isFollowingTopic(name) to { follows.toggleTopic(name) },
                )
            },
            member = { id, back, onOpenVote, onBack ->
                val navigate = LocalNavigate.current
                val model: MemberModel = viewModel { MemberModel(api, id) }
                LaunchedEffect(id) { model.appear() }
                val member = model.state.member
                MemberScreen(
                    state = model.state,
                    back = back,
                    zone = zone,
                    locale = locale,
                    onBack = onBack,
                    onSection = model::select,
                    onMoneySegment = model::selectMoney,
                    onSelectCall = model::selectCall,
                    onRetry = model::reload,
                    onRetryMoney = { model.reloadMoney() },
                    onRetryDisclosures = { model.reloadDisclosures() },
                    onOpenVote = onOpenVote,
                    follow = MemberFollow(follows.state.isFollowing(id), session.reps.any { it.bioguideId == id }) {
                        member?.let { follows.toggle(it) }
                    },
                    onPromise = model::selectPromise,
                    onOpenTopic = { navigate(Routes.topic(it)) },
                    onRetryPromises = { model.reloadPromises() },
                    onRetryPosts = { model.reloadPosts() },
                )
            },
            elect = { id, back, onBack ->
                val model: ElectModel = viewModel { ElectModel(api, id) }
                LaunchedEffect(id) { model.appear() }
                ElectScreen(model.state, back, locale, onBack, model::select, model::selectMoney) { model.reload() }
            },
        ),
        link = link,
        onLinkHandled = onLinkHandled,
    )
}
