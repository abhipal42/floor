package app.floor.android.api

import app.floor.android.model.Bill
import app.floor.android.model.BillAnalysis
import app.floor.android.model.BillShare
import app.floor.android.model.Chamber
import app.floor.android.model.Disclosures
import app.floor.android.model.ElectProfile
import app.floor.android.model.MemberDetail
import app.floor.android.model.MemberFunding
import app.floor.android.model.MemberPosts
import app.floor.android.model.MemberSearch
import app.floor.android.model.MemberVotes
import app.floor.android.model.MembersElect
import app.floor.android.model.PostsWall
import app.floor.android.model.Promises
import app.floor.android.model.Reps
import app.floor.android.model.Topic
import app.floor.android.model.RecentVotes
import app.floor.android.model.Schedule
import app.floor.android.model.SearchResults
import app.floor.android.model.TopicBills
import app.floor.android.model.TopicFilter
import app.floor.android.model.TopicList
import app.floor.android.model.VoteDetail
import app.floor.android.model.VoteKindList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.nullable
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
    suspend fun recentVotes(chamber: Chamber? = null, limit: Int = 40, topics: List<String> = emptyList()): RecentVotes {
        // Only the 32 are sent; a list of nothing but unknown names is no votes, not every vote.
        val known = topics.mapNotNull { Topic.canonical(it) }.distinct()
        if (topics.isNotEmpty() && known.isEmpty()) return RecentVotes(emptyList())
        return get(recentVotesUrl(chamber, limit, known), RecentVotes.serializer())
    }

    /** [recentVotes] as last saved, or null with nothing saved. */
    fun savedRecentVotes(chamber: Chamber? = null, limit: Int = 40, topics: List<String> = emptyList()): Saved<RecentVotes>? =
        saved(recentVotesUrl(chamber, limit, topics.mapNotNull { Topic.canonical(it) }.distinct()), RecentVotes.serializer())

    private fun recentVotesUrl(chamber: Chamber?, limit: Int, topics: List<String> = emptyList()): HttpUrl =
        base.newBuilder().addPathSegments("v1/votes").apply {
            addQueryParameter("limit", limit.toString())
            if (chamber != null) addQueryParameter("chamber", chamber.name.lowercase())
            // One `topic=` each: names hold commas ("Arts, Culture, Religion").
            topics.forEach { addQueryParameter("topic", it) }
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

    /** One bill: its record, actions and roll calls. The bill screen. */
    suspend fun bill(id: String): Bill = get(billUrl(id), Bill.serializer())

    fun savedBill(id: String): Saved<Bill>? = saved(billUrl(id), Bill.serializer())

    private fun billUrl(id: String, tail: String? = null): HttpUrl =
        base.newBuilder().addPathSegments("v1/bills").addPathSegment(id).apply { if (tail != null) addPathSegment(tail) }.build()

    /**
     * The AI analysis of a bill's CRS summary, or null when the worker has not written one: the
     * route's 404 means "none yet", and is saved as `null` so offline it is still known there was none.
     */
    suspend fun billAnalysis(id: String): BillAnalysis? =
        get(billUrl(id, "analysis"), BillAnalysis.serializer().nullable, notFound = "null")

    fun savedBillAnalysis(id: String): Saved<BillAnalysis?>? = saved(billUrl(id, "analysis"), BillAnalysis.serializer().nullable)

    /** What the share sheet sends for a bill: its share link and a neutral line. */
    suspend fun billShare(id: String): BillShare = get(billUrl(id, "share"), BillShare.serializer())

    fun savedBillShare(id: String): Saved<BillShare>? = saved(billUrl(id, "share"), BillShare.serializer())

    /** A week's floor lists: this week in Washington's week, or the week of [week], a Monday `YYYY-MM-DD`. */
    suspend fun schedule(week: String? = null): Schedule = get(scheduleUrl(week), Schedule.serializer())

    fun savedSchedule(week: String? = null): Saved<Schedule>? = saved(scheduleUrl(week), Schedule.serializer())

    private fun scheduleUrl(week: String?): HttpUrl =
        base.newBuilder().addPathSegments("v1/schedule").apply { if (week != null) addQueryParameter("week", week) }.build()

    /** The 32 topics with their bill counts, for the Congress in session. */
    suspend fun topics(): TopicList = get(topicsUrl(), TopicList.serializer())

    fun savedTopics(): Saved<TopicList>? = saved(topicsUrl(), TopicList.serializer())

    private fun topicsUrl(): HttpUrl = base.newBuilder().addPathSegments("v1/topics").build()

    /** One page of a topic's bills, newest action first; pass the last page's `nextCursor` for the next. */
    suspend fun topicBills(name: String, filter: TopicFilter = TopicFilter.ALL, cursor: String? = null): TopicBills =
        get(topicBillsUrl(name, filter, cursor), TopicBills.serializer())

    fun savedTopicBills(name: String, filter: TopicFilter = TopicFilter.ALL): Saved<TopicBills>? =
        saved(topicBillsUrl(name, filter, null), TopicBills.serializer())

    private fun topicBillsUrl(name: String, filter: TopicFilter, cursor: String?): HttpUrl =
        base.newBuilder().addPathSegments("v1/topics").addPathSegment(name).addPathSegment("bills").apply {
            addQueryParameter("filter", filter.raw)
            if (cursor != null) addQueryParameter("cursor", cursor)
        }.build()

    /**
     * Members, bills and topics matching what was typed; a bill number in any spelling is exactly
     * that bill. Never saved: a list of what someone searched for is not worth keeping on the phone,
     * and a search with no network should say so rather than answer from an old list.
     */
    suspend fun search(query: String, chamber: Chamber? = null): SearchResults =
        get(
            base.newBuilder().addPathSegments("v1/search").addQueryParameter("q", query).apply {
                if (chamber != null) addQueryParameter("chamber", chamber.name.lowercase())
            }.build(),
            SearchResults.serializer(),
            cacheable = false,
        )

    /**
     * Sitting members matching a name, a state or a seat, with the members-elect and undecided seats
     * matching the same text. Never saved, for the reason [search] gives.
     */
    suspend fun searchMembers(query: String, chamber: Chamber? = null, limit: Int = 100): MemberSearch =
        get(
            base.newBuilder().addPathSegments("v1/members").addQueryParameter("q", query)
                .addQueryParameter("limit", limit.toString()).apply {
                    if (chamber != null) addQueryParameter("chamber", chamber.name.lowercase())
                }.build(),
            MemberSearch.serializer(),
            cacheable = false,
        )

    /**
     * The district an address falls in, with its members. The address goes to this route and nowhere
     * else: never saved (the cache key would be the address), never logged.
     */
    suspend fun reps(address: String): Reps =
        get(base.newBuilder().addPathSegments("v1/reps").addQueryParameter("address", address).build(), Reps.serializer(), cacheable = false)

    /**
     * The district a point falls in. Each coordinate is rounded to 4 decimals (about 11 m) before it
     * leaves the phone, as the API keeps no more; never saved, never logged. A 404: not in a district.
     */
    suspend fun reps(latitude: Double, longitude: Double): Reps =
        get(
            base.newBuilder().addPathSegments("v1/reps")
                .addQueryParameter("lat", coordinate(latitude))
                .addQueryParameter("lng", coordinate(longitude)).build(),
            Reps.serializer(),
            cacheable = false,
        )

    /** A member's recent votes, newest first. */
    suspend fun memberVotes(id: String, limit: Int = 40): MemberVotes = get(memberVotesUrl(id, limit), MemberVotes.serializer())

    fun savedMemberVotes(id: String, limit: Int = 40): Saved<MemberVotes>? = saved(memberVotesUrl(id, limit), MemberVotes.serializer())

    private fun memberVotesUrl(id: String, limit: Int): HttpUrl =
        memberUrl(id).newBuilder().addPathSegment("votes").addQueryParameter("limit", limit.toString()).build()

    /** What a member's current campaign reported receiving, and the committees that gave to it. */
    suspend fun funding(id: String): MemberFunding = get(fundingUrl(id), MemberFunding.serializer())

    fun savedFunding(id: String): Saved<MemberFunding>? = saved(fundingUrl(id), MemberFunding.serializer())

    private fun fundingUrl(id: String): HttpUrl =
        memberUrl(id).newBuilder().addPathSegment("funding").addQueryParameter("committees", "10").build()

    /** A member's financial disclosures; an API without the route (its 404) reads as off. */
    suspend fun disclosures(id: String): Disclosures =
        get(disclosuresUrl(id), Disclosures.serializer(), notFound = Disclosures.UNAVAILABLE_BODY)

    fun savedDisclosures(id: String): Saved<Disclosures>? = saved(disclosuresUrl(id), Disclosures.serializer())

    private fun disclosuresUrl(id: String): HttpUrl = memberUrl(id).newBuilder().addPathSegment("disclosures").build()

    /**
     * What a member's campaign site said in the race that won this term, quoted from the Internet
     * Archive's copy before election day. An API without the route (its 404) reads as not checked.
     */
    suspend fun promises(id: String): Promises = get(promisesUrl(id), Promises.serializer(), notFound = Promises.UNCHECKED_BODY)

    fun savedPromises(id: String): Saved<Promises>? = saved(promisesUrl(id), Promises.serializer())

    private fun promisesUrl(id: String): HttpUrl = memberUrl(id).newBuilder().addPathSegment("promises").build()

    /** A member's posts from the free networks, newest first; an API without the route reads as none. */
    suspend fun memberPosts(id: String): MemberPosts = get(memberPostsUrl(id), MemberPosts.serializer(), notFound = MemberPosts.NONE_BODY)

    fun savedMemberPosts(id: String): Saved<MemberPosts>? = saved(memberPostsUrl(id), MemberPosts.serializer())

    private fun memberPostsUrl(id: String): HttpUrl = memberUrl(id).newBuilder().addPathSegment("posts").build()

    /** The Following tab's wall: posts by these members (the first twelve, the API's cap), newest first. */
    suspend fun posts(members: List<String>): PostsWall {
        if (members.isEmpty()) return PostsWall()
        return get(postsUrl(members), PostsWall.serializer(), notFound = PostsWall.NONE_BODY)
    }

    fun savedPosts(members: List<String>): Saved<PostsWall>? = if (members.isEmpty()) null else saved(postsUrl(members), PostsWall.serializer())

    private fun postsUrl(members: List<String>): HttpUrl =
        base.newBuilder().addPathSegments("v1/posts")
            .addQueryParameter("members", members.distinct().take(PostsWall.MAX_MEMBERS).joinToString(",")).build()

    /** Members-elect and undecided seats in one state; an API without the route reads as none. */
    suspend fun membersElect(state: String): MembersElect =
        get(membersElectUrl(state), MembersElect.serializer(), notFound = MembersElect.NONE_BODY)

    fun savedMembersElect(state: String): Saved<MembersElect>? = saved(membersElectUrl(state), MembersElect.serializer())

    private fun membersElectUrl(state: String): HttpUrl =
        base.newBuilder().addPathSegments("v1/members-elect").addQueryParameter("state", state).build()

    /** One member-elect's profile, or null once the API no longer lists them (its 404). */
    suspend fun memberElect(id: String): ElectProfile? =
        get(memberElectUrl(id), ElectProfile.serializer().nullable, notFound = "null")

    fun savedMemberElect(id: String): Saved<ElectProfile?>? = saved(memberElectUrl(id), ElectProfile.serializer().nullable)

    private fun memberElectUrl(id: String): HttpUrl = base.newBuilder().addPathSegments("v1/members-elect").addPathSegment(id).build()

    /** A member's record, for their office's contact (Speak up). */
    suspend fun member(id: String): MemberDetail = get(memberUrl(id), MemberDetail.serializer())

    fun savedMember(id: String): Saved<MemberDetail>? = saved(memberUrl(id), MemberDetail.serializer())

    private fun memberUrl(id: String): HttpUrl = base.newBuilder().addPathSegments("v1/members").addPathSegment(id).build()

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

    /**
     * @param cacheable false for a response never saved (search).
     * @param notFound the body a 404 stands for, on a route whose 404 means "none".
     */
    private suspend fun <T> get(
        url: HttpUrl,
        strategy: DeserializationStrategy<T>,
        cacheable: Boolean = true,
        notFound: String? = null,
    ): T {
        val request = Request.Builder().url(url).header("Accept", "application/json").get().build()
        var (status, body) = try {
            client.newCall(request).await().use { it.code to (it.body.string()) }
        } catch (e: CancellationException) {
            // A screen that went away is not being offline; callers must tell the two apart.
            throw e
        } catch (e: IOException) {
            throw FloorApiError.Transport(e)
        }
        if (status == 404 && notFound != null) {
            status = 200
            body = notFound
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
        if (cacheable) cache?.save(url.toString(), body, now())
        return value
    }

    @Serializable
    private data class ApiErrorBody(val error: String)

    companion object {
        /** `30.2747`: rounded to the nearest 4th decimal. */
        fun coordinate(value: Double): String = String.format(java.util.Locale.US, "%.4f", Math.round(value * 10_000) / 10_000.0)

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
