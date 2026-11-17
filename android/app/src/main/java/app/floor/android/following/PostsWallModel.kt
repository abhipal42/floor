package app.floor.android.following

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.floor.android.api.FloorApi
import app.floor.android.member.Load
import app.floor.android.member.revalidate
import app.floor.android.model.PostsWall
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * The Following tab's Posts wall (iOS `PostsWallModel`): `GET /v1/posts?members=` for your members
 * (your reps, then who you follow; the API's first twelve), saved for offline, reloaded when the
 * set of members changes.
 */
class PostsWallModel(private val api: FloorApi) : ViewModel() {
    var state by mutableStateOf<Load<PostsWall>>(Load.Loading)
        private set

    private var ids: List<String>? = null
    private var job: Job? = null

    fun appear(members: List<String>) {
        val wanted = members.distinct().take(PostsWall.MAX_MEMBERS)
        if (wanted == ids && !state.needsRefresh) return
        if (wanted != ids) state = Load.Loading
        ids = wanted
        reload()
    }

    fun reload() {
        val wanted = ids ?: return
        job?.cancel()
        job = viewModelScope.launch {
            revalidate(state, api.savedPosts(wanted), "Couldn't load your members' posts.", { state = it }) { api.posts(wanted) }
        }
    }
}
