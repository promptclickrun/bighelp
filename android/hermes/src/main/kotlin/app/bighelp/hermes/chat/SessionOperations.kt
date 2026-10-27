package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.RequestCancelledException
import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Everyday session edits: rename, archive, restore, delete and fork. Each goes through the socket's own methods on
 * the identifiers the host expects (the registry or lineage root, not whichever tip is current), and each result is
 * checked against what the host answered or read back, so a quiet no-op is never reported as done.
 */
internal class SessionOperations(
    private val ctx: ChatContext,
    private val engine: ConversationEngine,
    private val binder: SessionBinder,
    private val catalog: CatalogEngine,
) {
    private suspend fun <T> mapErrors(block: suspend () -> T): T = try {
        block()
    } catch (e: HermesException) {
        throw ChatException(if (e.outcomeUnknown) ChatError(ChatError.Kind.OutcomeUnknown, e.kind, e.code, e.reason) else SessionBinder.chatError(e))
    } catch (e: RequestCancelledException) {
        throw ChatException(ChatError.Kind.OutcomeUnknown)
    }

    /** The conversation, attached to a live runtime on this socket (resuming it if needed). */
    private suspend fun attached(ref: ConversationRef): Pair<ConversationRuntime, Binding> {
        val rt = engine.open(ref, hint = null)
        return ctx.onState {
            val binding = rt.binding
            if (binding == null || rt.requiresReattach || binding.generation != ctx.gateway.state.value.generation) throw ChatException(rt.lastError ?: ChatError(ChatError.Kind.NoLiveSession))
            rt to binding
        }
    }

    // ---- rename

    suspend fun rename(ref: ConversationRef, title: String): Unit = mapErrors {
        val trimmed = title.trim()
        if (trimmed.isEmpty() || utf8Length(trimmed) > 240 || trimmed.any { Character.isISOControl(it) }) throw ChatException(ChatError.Kind.InvalidInput)
        val (rt, binding) = attached(ref)
        val registry = ctx.onState { rt.identity.canonicalRegistryId ?: binder.canonical[ref.profile]?.id?.takeIf { it == ref.anchor } }
        if (registry != null) {
            // Hermes refuses to rename a hidden "Bot Chat" (hidden is what makes it the agent's): release it first.
            val released = ctx.gateway.request("session.set_hidden", buildJsonObject { put("session_id", registry); put("profile", ref.profile); put("hidden", false) }).asObject
            if (released?.get("hidden").asBool != false || released?.get("session_key").asString.isNullOrEmpty()) throw ChatException(ChatError.Kind.InvalidResponse)
            binder.canonical.remove(ref.profile)
        }
        val reply = ctx.gateway.request("session.title", buildJsonObject { put("session_id", binding.runtimeId); put("title", trimmed) }).asObject
        ctx.onState { if (rt.binding != binding) throw ChatException(ChatError.Kind.NotConnected) }
        if (reply?.get("pending").asBool != false || reply?.get("title").asString != trimmed) throw ChatException(ChatError.Kind.OutcomeUnknown)
        ctx.onState { rt.title = trimmed; engine.publish(rt) }
        catalog.update(ref) { SessionSummary(it.ref, it.profile, it.storedId, trimmed, it.preview, it.startedAtEpochSeconds, it.lastActiveEpochSeconds, it.messageCount, it.source, it.cwd, it.pinned, it.archive, it.lineageRootId, it.lineageIds, false, it.isRegistryOnly) }
    }

    // ---- archive and restore

    /** Archives or restores [ref]; the host's own flag is read back. Restoring needs a catalog refresh to bring the row back. */
    suspend fun setArchived(ref: ConversationRef, archived: Boolean): Unit = mapErrors {
        val identity = ctx.onState { engine.conversations[ref]?.identity }
        val target = identity?.canonicalRegistryId ?: identity?.lineageRootId ?: ref.anchor
        val reply = ctx.gateway.request("session.archive", buildJsonObject { put("session_id", target); put("profile", ref.profile); put("archived", archived) }).asObject
        if (reply?.get("archived").asBool != archived || reply?.get("session_key").asString.isNullOrEmpty()) throw ChatException(ChatError.Kind.InvalidResponse)
        val detail = ctx.rest.get("/api/sessions/$target", listOf("profile" to ref.profile))
        val session = detail.asObject?.let { it["session"].asObject ?: it } ?: throw invalidResponse()
        if (CatalogDecoder.archiveState(session) != ArchiveState.None == !archived) throw ChatException(ChatError.Kind.Conflict)
        if (archived) catalog.update(ref) { null }
    }

    // ---- delete

    suspend fun delete(ref: ConversationRef): Unit = mapErrors {
        val rowId = findRow(ref) ?: throw ChatException(ChatError.Kind.Conflict)
        try {
            val reply = ctx.gateway.request("session.delete", buildJsonObject { put("session_id", rowId); put("profile", ref.profile) }).asObject
            if (reply?.get("deleted").asString != rowId) throw ChatException(ChatError.Kind.InvalidResponse)
        } catch (e: HermesException) {
            // A row that is already gone counts as deleted.
            if (!(e.kind == HermesException.Kind.RpcRejected && e.code == 4007L)) throw e
        }
        forget(ref)
        catalog.update(ref) { null }
    }

    /** The host's own row for [ref]: the list row whose ID, lineage root or lineage names the anchor. */
    private suspend fun findRow(ref: ConversationRef): String? {
        val canonical = binder.canonical[ref.profile]
        var offset = 0
        while (offset <= CatalogDecoder.MAXIMUM_SESSIONS) {
            val page = CatalogDecoder.sessionPage(ctx.rest.get("/api/sessions", CatalogDecoder.listQuery(ref.profile, offset)), ref.profile, offset)
            for (row in page.rows) {
                val summary = runCatching { CatalogDecoder.summary(row, ref.profile, canonical) }.getOrNull() ?: continue
                if (summary.ref == ref || summary.storedId == ref.anchor || summary.lineageRootId == ref.anchor || summary.lineageIds?.contains(ref.anchor) == true) return summary.storedId
            }
            if (page.rows.isEmpty() || !CatalogDecoder.hasMore(page, offset, page.rows.size)) return null
            offset += page.limit
        }
        return null
    }

    /** A deleted chat takes its unsent text, uncertain sends and caches with it. */
    private suspend fun forget(ref: ConversationRef) {
        val scope = ctx.conversationScope(ref)
        val ops = ArrayList<StoreOp>()
        ops += StoreOp.Delete(RecordKey.draft(scope)); ops += StoreOp.Delete(RecordKey.identity(scope))
        ctx.store.keys(ctx.host, RecordKind.Journal, ref.profile, ref.anchor).forEach { ops += StoreOp.Delete(it) }
        runCatching { ctx.store.commit(ops) }
        ctx.store.deleteCache(RecordKey.history(scope))
        ctx.onState {
            engine.conversations.remove(ref)?.let { engine.historyCache.remove(ref); engine.prompts.retireFor(ref) }
            engine.publishAll()
        }
    }

    // ---- fork

    /** A branch of [ref] through the saved row [throughRowId]: the host counts visible messages, so the whole transcript is read first. */
    suspend fun fork(ref: ConversationRef, throughRowId: Long): ConversationRef = mapErrors {
        val (rt, binding) = attached(ref)
        val rows = hydrateAll(rt)
        val checkpoint = rows.indexOfFirst { it.id == throughRowId }
        if (checkpoint < 0) throw ChatException(ChatError.Kind.InvalidInput)
        // Messages exactly as the host counts them: visible user, assistant and model-switch rows with text.
        val messages = rows.take(checkpoint + 1).mapNotNull { row ->
            if (!row.isVisible) return@mapNotNull null
            val role = when {
                row.displayKind == "model_switch" || row.role == "assistant" -> "assistant"
                row.role == "user" -> "user"
                else -> return@mapNotNull null
            }
            val text = if (row.role == "user" && row.displayKind != "model_switch") UserMessageDisplay.text(row.text) else row.text
            if (text.isBlank()) null else Triple(row.id, role, text)
        }
        if (messages.isEmpty() || messages.last().first != throughRowId || messages.none { it.second == "user" } || messages.size > 50_000) throw ChatException(ChatError.Kind.InvalidInput)
        val parentStored = ctx.onState { rt.identity.storedTip }
        val title = forkTitle(rt.title)
        val reply = ctx.gateway.request("session.branch", buildJsonObject { put("session_id", binding.runtimeId); put("count", messages.size); put("name", title) }).asObject
            ?: throw invalidResponse()
        val childRuntime = reply["session_id"].asString ?: throw invalidResponse()
        val childStored = reply["stored_session_id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
        val info = reply["info"].asObject ?: throw invalidResponse()
        val returned = reply["messages"].asArray ?: throw invalidResponse()
        if (childRuntime == binding.runtimeId || childStored == parentStored || reply["title"].asString != title || reply["parent"].asString != parentStored ||
            reply["message_count"].asInt != messages.size || returned.size != messages.size ||
            info["profile_name"].asString != ref.profile || info["running"].asBool == null
        ) throw invalidResponse()
        returned.forEachIndexed { index, value ->
            val m = value.asObject ?: throw invalidResponse()
            val (_, role, text) = messages[index]
            // The child's rows carry the child's own new row IDs (a real host numbers them afresh), so only role and text are compared.
            if (m["role"].asString != role || m["text"].asString != text) throw invalidResponse()
        }
        val child = ConversationRef(ref.profile, childStored)
        engine.open(child, hint = null)
        child
    }

    private fun forkTitle(source: String): String {
        val suffix = " · Fork"
        return source.take(maxOf(1, 240 - suffix.length)) + suffix
    }

    /** The whole saved transcript, oldest first: 200 rows, then 201 with the previous last row repeated and checked byte for byte. */
    suspend fun hydrateAll(rt: ConversationRuntime): List<HistoryRow> {
        val stored = ctx.onState { rt.identity.storedTip }
        val profile = rt.scope.profile
        val rows = ArrayList<HistoryRow>()
        val seen = HashSet<Long>()
        var bytes = 0L
        var first = true
        while (true) {
            val offset = if (first) 0 else rows.size - 1
            val limit = if (first) 200 else 201
            val envelope: JsonElement = ctx.rest.get("/api/sessions/$stored/messages", listOf("profile" to profile, "limit" to limit.toString(), "offset" to offset.toString(), "order" to "oldest", "include_compacted" to "true"))
            val page = HistoryPage.parse(envelope, profile, offset, limit, "oldest")
            if (page.storedId != stored) throw ChatException(ChatError.Kind.HistoryChanged)
            if (!first) {
                val anchor = rows.last()
                val repeated = page.rows.firstOrNull()
                if (repeated == null || repeated.id != anchor.id || repeated.canonicalJson() != anchor.canonicalJson()) throw ChatException(ChatError.Kind.HistoryChanged)
            }
            val added = if (first) page.rows else page.rows.drop(1)
            for (row in added) {
                if (!seen.add(row.id)) throw ChatException(ChatError.Kind.HistoryChanged)
                bytes += row.encodedBytes()
                if (rows.size >= HistoryWindow.MAXIMUM_ROWS || bytes > HistoryWindow.MAXIMUM_BYTES) throw ChatException(ChatError.Kind.TooLarge)
                rows += row
            }
            if (page.returned < page.limit) break
            if (added.isEmpty()) throw ChatException(ChatError.Kind.HistoryChanged)
            first = false
        }
        return rows
    }
}
