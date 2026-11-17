package app.floor.android.api

import app.floor.android.model.Chamber
import app.floor.android.model.RecentVotes
import app.floor.android.model.VoteDetail
import app.floor.android.model.VoteKindList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.time.Instant
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** What can go wrong talking to the Floor API (iOS `FloorAPIError`). */
sealed class FloorApiError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** The request never completed: offline, DNS, TLS, timeout. */
    class Transport(cause: Throwable) : FloorApiError("Couldn't reach Floor. Check your connection and try again.", cause)

    /**
     * The server answered, but not with success. [apiMessage] is the API's own wording where it
     * sent one, which is written for people.
     */
    class Http(val status: Int, val apiMessage: String?) :
        FloorApiError(apiMessage ?: "Floor returned an unexpected response (HTTP $status).")

    /** The body did not match the contract. A bug on one side or the other, not a user error. */
    class Decoding(cause: Throwable) :
        FloorApiError("Floor sent something this version of the app doesn't understand.", cause)
}

/** A response as it was saved, and when it was fetched. */
data class Saved<T>(val value: T, val fetchedAt: Instant)

/**
 * An OkHttp client for the Floor API: one method per route a screen uses, each returning a model.
 *
 * With a [cache], every successful response is saved, and the `saved…` twin of a route answers from
 * it without touching the network, so a screen can open on its last-seen data when offline or slow.
 * OkHttp's own HTTP cache stays off: [ResponseCache] is the only cache this app keeps, as on iOS.
 */
class FloorApi(
    baseUrl: String,
    private val client: OkHttpClient = OkHttpClient(),
    private val cache: ResponseCache? = null,
    private val now: () -> Instant = Instant::now,
) {
    private val base: HttpUrl = baseUrl.toHttpUrl()

    /**
     * The most recent final votes in both chambers (or one), newest first, each with what it was
     * on: the Finals feed.
     */
    suspend fun recentVotes(chamber: Chamber? = null, limit: Int = 40): RecentVotes =
        get(recentVotesUrl(chamber, limit), RecentVotes.serializer())

    /** [recentVotes] as last saved, or null with nothing saved. */
    fun savedRecentVotes(chamber: Chamber? = null, limit: Int = 40): Saved<RecentVotes>? =
        saved(recentVotesUrl(chamber, limit), RecentVotes.serializer())

    private fun recentVotesUrl(chamber: Chamber?, limit: Int): HttpUrl =
        base.newBuilder().addPathSegments("v1/votes").apply {
            addQueryParameter("limit", limit.toString())
            if (chamber != null) addQueryParameter("chamber", chamber.name.lowercase())
        }.build()

    /**
     * One vote with its party breakdown, and the named members' own positions (`?members=`, at
     * most ten: the API's cap). The vote screen.
     */
    suspend fun vote(id: String, members: List<String> = emptyList()): VoteDetail =
        get(voteUrl(id, members), VoteDetail.serializer())

    /** [vote] as last saved, or null with nothing saved. */
    fun savedVote(id: String, members: List<String> = emptyList()): Saved<VoteDetail>? =
        saved(voteUrl(id, members), VoteDetail.serializer())

    private fun voteUrl(id: String, members: List<String>): HttpUrl =
        base.newBuilder().addPathSegments("v1/votes").addPathSegment(id).apply {
            if (members.isNotEmpty()) addQueryParameter("members", members.take(10).joinToString(","))
        }.build()

    /** Every kind of vote Floor explains, in the table's order: the "Kinds of vote" list. */
    suspend fun voteKinds(): VoteKindList = get(voteKindsUrl(), VoteKindList.serializer())

    /** [voteKinds] as last saved, or null with nothing saved. */
    fun savedVoteKinds(): Saved<VoteKindList>? = saved(voteKindsUrl(), VoteKindList.serializer())

    private fun voteKindsUrl(): HttpUrl = base.newBuilder().addPathSegments("v1/vote-kinds").build()

    private fun <T> saved(url: HttpUrl, strategy: DeserializationStrategy<T>): Saved<T>? {
        val entry = cache?.load(url.toString()) ?: return null
        // A saved body this version can't read is as good as nothing saved.
        return try {
            Saved(json.decodeFromString(strategy, entry.body), entry.fetchedAt)
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private suspend fun <T> get(url: HttpUrl, strategy: DeserializationStrategy<T>): T {
        val request = Request.Builder().url(url).header("Accept", "application/json").get().build()
        val (status, body) = try {
            client.newCall(request).await().use { it.code to (it.body.string()) }
        } catch (e: CancellationException) {
            // A screen that went away is not being offline; callers must tell the two apart.
            throw e
        } catch (e: IOException) {
            throw FloorApiError.Transport(e)
        }
        if (status !in 200..299) {
            // Every route answers a 4xx with `{ "error": ... }`, phrased for a person. Fall back to
            // the bare status for anything else, e.g. a proxy's error page.
            val message = try {
                json.decodeFromString(ApiErrorBody.serializer(), body).error
            } catch (_: Exception) {
                null
            }
            throw FloorApiError.Http(status, message)
        }
        val value = try {
            json.decodeFromString(strategy, body)
        } catch (e: SerializationException) {
            throw FloorApiError.Decoding(e)
        } catch (e: IllegalArgumentException) {
            throw FloorApiError.Decoding(e)
        }
        cache?.save(url.toString(), body, now())
        return value
    }

    @Serializable
    private data class ApiErrorBody(val error: String)

    companion object {
        /** Fields the app does not know yet (a newer API) are ignored rather than fatal. */
        val json = Json { ignoreUnknownKeys = true }
    }
}

private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = continuation.resume(response)

        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
}
