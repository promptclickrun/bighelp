package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The agent list and the saved chats. It only reads: `profiles.list` (with each agent's sessions, so the Bot Chat
 * registry is named) and `GET /api/sessions`. It never creates or resumes a chat to learn whether anything is
 * running. The hidden canonical Bot Chat is merged from the registry, deliberately archived chats are left out of
 * the normal list (Hermes' idle sweep archives are kept), and one unreadable row hides only itself.
 */
internal class CatalogEngine(private val ctx: ChatContext, private val binder: SessionBinder) {
    private val mutableState = MutableStateFlow(CatalogState())
    val state: StateFlow<CatalogState> = mutableState.asStateFlow()
    private var unreadable = 0

    suspend fun refresh(): CatalogState {
        mutableState.value = mutableState.value.copy(loading = true, error = null)
        try {
            val agents = loadAgents()
            val sessions = ArrayList<SessionSummary>()
            val failures = LinkedHashMap<String, ChatError>()
            var truncated = false
            for (agent in agents) {
                // One agent's list can fail on its own (a profile with no session store yet answers 503): the others stay listed.
                try {
                    val rows = listProfile(agent.id, agent.canonicalChat, archived = "include", keepDeliberate = false)
                    sessions += rows.first
                    truncated = truncated || rows.second
                } catch (e: HermesException) {
                    if (fatal(e)) throw e
                    failures[agent.id] = SessionBinder.chatError(e)
                } catch (e: ChatException) {
                    failures[agent.id] = e.error
                }
                agent.canonicalChat?.let { canonical ->
                    // Hermes hides every Bot Chat, so the list never has it: the registry names it. Without this, a refresh dropped it.
                    if (sessions.none { it.profile == agent.id && (it.ref.anchor == canonical.id || it.storedId == canonical.id || it.storedId == canonical.resolvedId) }) {
                        sessions += CatalogDecoder.registryOnly(agent.id, canonical)
                    }
                }
            }
            if (agents.isNotEmpty() && failures.size == agents.size) throw ChatException(failures.values.first())
            val next = CatalogState(agents, failures, sessions, loading = false, error = null, loadedAtMillis = ctx.config.clock(), truncated = truncated)
            mutableState.value = next
            return next
        } catch (e: ChatException) {
            return fail(e.error)
        } catch (e: HermesException) {
            return fail(SessionBinder.chatError(e))
        }
    }

    /** A sign-in or connection problem is the whole catalog's, not one agent's. */
    private fun fatal(e: HermesException) = SessionBinder.chatError(e).kind.let { it == ChatError.Kind.SignInRequired || it == ChatError.Kind.NotConnected }

    private fun fail(error: ChatError): CatalogState {
        // The previous list stays; the error is shown beside it.
        val next = mutableState.value.copy(loading = false, error = error)
        mutableState.value = next
        return next
    }

    suspend fun loadAgents(): List<AgentSummary> {
        val agents = CatalogDecoder.profiles(ctx.gateway.request("profiles.list", buildJsonObject { put("include_sessions", true) }))
        agents.forEach { a -> a.canonicalChat?.let { binder.canonical[a.id] = it } ?: binder.canonical.remove(a.id) }
        mutableState.value = mutableState.value.copy(agents = agents)
        return agents
    }

    /** Chats the person archived, every agent's. A plain read: nothing is bound or opened. */
    suspend fun loadArchived(): List<SessionSummary> {
        val agents = mutableState.value.agents.ifEmpty { loadAgents() }
        val result = ArrayList<SessionSummary>()
        for (agent in agents) {
            try {
                result += listProfile(agent.id, agent.canonicalChat, archived = "only", keepDeliberate = true).first
            } catch (e: HermesException) {
                if (fatal(e)) throw e // one agent's list failing leaves the others
            }
        }
        return result.filter { it.archive == ArchiveState.Deliberate }.sortedByDescending { it.lastActiveEpochSeconds ?: 0.0 }
    }

    /** All pages of one profile: 100 per page, bounded continuation. Returns the rows and whether the ceiling cut the list. */
    private suspend fun listProfile(profile: String, canonical: CanonicalChat?, archived: String, keepDeliberate: Boolean): Pair<List<SessionSummary>, Boolean> {
        val rows = ArrayList<SessionSummary>()
        val seen = HashSet<String>()
        var offset = 0
        while (true) {
            val page = CatalogDecoder.sessionPage(ctx.rest.get("/api/sessions", CatalogDecoder.listQuery(profile, offset, archived = archived)), profile, offset)
            for (row in page.rows) {
                val id = row["id"].asString!!
                // Hermes 0.21.x adds pinned rows to every page; they are skipped after the first. Any other repeat means the list moved.
                if (!seen.add(id)) {
                    if (page.hasMore != null || row["pinned"].let { it.asBool == true || it.asLong == 1L }) continue
                    throw ChatException(ChatError.Kind.HistoryChanged)
                }
                if (!keepDeliberate && CatalogDecoder.archiveState(row) == ArchiveState.Deliberate) continue
                val summary = try { CatalogDecoder.summary(row, profile, canonical) } catch (e: HermesException) { unreadable += 1; continue }
                rows += summary
                if (rows.size > CatalogDecoder.MAXIMUM_SESSIONS) throw ChatException(ChatError.Kind.TooLarge)
            }
            if (page.rows.isEmpty() || !CatalogDecoder.hasMore(page, offset, page.rows.size)) return rows to false
            offset += page.limit
            if (offset > CatalogDecoder.MAXIMUM_SESSIONS) return rows to true
        }
    }

    suspend fun search(profile: String, query: String, limit: Int): List<SessionSearchResult> {
        if (query.isEmpty() || utf8(query) > 4_096 || limit !in 1..100) throw ChatException(ChatError.Kind.InvalidInput)
        val canonical = binder.canonical[profile]
        val envelope = ctx.rest.get("/api/sessions/search", listOf("q" to query, "profile" to profile, "limit" to limit.toString(), "exclude_sources" to CatalogDecoder.DEFAULT_EXCLUDED_SOURCES.joinToString(",")))
        val rows = envelope.asObject?.get("results").asArray?.takeIf { it.size <= limit } ?: throw invalidResponse()
        val seen = HashSet<String>()
        return rows.map { value ->
            val row = value.asObject ?: throw invalidResponse()
            val id = (row["id"] ?: row["session_id"]).asString ?: throw invalidResponse()
            row["profile"]?.let { if (it.asString != profile) throw invalidResponse() }
            val normalized = kotlinx.serialization.json.JsonObject(row + mapOf("id" to kotlinx.serialization.json.JsonPrimitive(id), "profile" to kotlinx.serialization.json.JsonPrimitive(profile)))
            val summary = CatalogDecoder.summary(normalized, profile, canonical)
            if (!seen.add(summary.ref.id)) throw invalidResponse()
            SessionSearchResult(summary, CatalogDecoder.optionalText(row["snippet"], 64 * 1024).orEmpty())
        }
    }

    /** Replaces one row after an edit, or drops it. */
    fun update(ref: ConversationRef, change: (SessionSummary) -> SessionSummary?) {
        val current = mutableState.value
        mutableState.value = current.copy(sessions = current.sessions.mapNotNull { if (it.ref == ref) change(it) else it })
    }

    fun add(summary: SessionSummary) {
        val current = mutableState.value
        if (current.sessions.none { it.ref == summary.ref }) mutableState.value = current.copy(sessions = listOf(summary) + current.sessions)
    }

    private fun utf8(text: String) = app.bighelp.hermes.utf8Length(text)
}
