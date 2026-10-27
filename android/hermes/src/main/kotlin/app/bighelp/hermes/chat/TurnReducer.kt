package app.bighelp.hermes.chat

import app.bighelp.hermes.WireMessage
import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** How Hermes says a turn failed (`message.complete` with `status:"error"`). Every part is optional advice. */
data class TurnFailure(
    val layer: String?,
    val code: String?,
    val retryable: Boolean,
    val providerLabel: String?,
    val resetsAtEpochSeconds: Double?,
    val billingUrl: String?,
)

enum class CompactionSignal { Compressing, Compacting, Compacted }

internal class PersistedTurn(val userRowId: Long?, val finalAssistantRowId: Long?)

/** What one event changed, beyond the items. The repository applies it to the conversation. */
internal class Change {
    /** The event's sequence was not newer than the cursor: it changed nothing. */
    var ignored = false
    var terminal = false
    var failedBeforeStart = false
    var turnFailure: TurnFailure? = null
    var terminalError: String? = null
    var settledAnswer = false
    var errorEvent = false
    var status: String? = null
    var title: String? = null
    var runtime: RuntimeInfo? = null
    var storedIdReport: String? = null
    var persistedTurn: PersistedTurn? = null
    var compaction: CompactionSignal? = null
    var started = false
}

/**
 * The ordered reduction of one runtime's live events into transcript items, one instance per conversation. It
 * is pure: no I/O, no clock. `message.complete` closes a segment; only `session.info running:false` after
 * running ends the turn. Streaming rows are keyed by turn and segment so an upsert keeps its place.
 */
internal class TurnReducer(initialEpoch: String = "") {
    var epoch: String = initialEpoch
        private set
    var lastSequence: Long = 0
        private set
    var running = false
        private set
    var turnId: String = ""
        private set
    var failedTurnId: String? = null
        private set
    var hasLiveEvents = false
        private set

    private val live = LinkedHashMap<String, TranscriptItem>()
    private var text = ""
    private var reasoning = ""
    private var reasoningSegment = 0
    private var reasoningSealed = false
    private var segment = 0
    private var segmentId: String? = null
    private var sealedSegmentId: String? = null
    private var anonymous = 0L

    val items: List<TranscriptItem> get() = live.values.toList()

    fun seedCheckpoint(sequence: Long) { lastSequence = maxOf(lastSequence, sequence) }

    /** A new replay epoch restarts sequence numbers. Rows stay; only the cursor moves. */
    fun resetCursor(newEpoch: String, latest: Long) {
        epoch = newEpoch
        lastSequence = latest
    }

    fun seedRunning(value: Boolean) { running = value }

    /** An optimistic row for a message just sent from here. It is bound to a saved row by the host's row ID, never by text. */
    fun addLocalUser(localId: String, body: String) {
        val id = "local:$localId"
        live[id] = MessageItem(id, MessageRole.User, "user", body, ItemOrigin.Local)
    }

    fun removeLocal(localId: String) { live.remove("local:$localId") }

    /** A command's output, shown once as a result instead of a turn. */
    fun addCommandResult(id: String, output: String) {
        live[id] = MessageItem(id, MessageRole.Assistant, "assistant", output, ItemOrigin.Live, isCommandResult = true)
    }

    /** `prompt.submit`'s `user_row_id`: the newest local user row, if it has none yet. */
    fun bindUserRow(rowId: Long) {
        val last = live.values.lastOrNull { it is MessageItem && it.role == MessageRole.User && it.origin == ItemOrigin.Local } as? MessageItem ?: return
        if (last.rowId == null) live[last.id] = last.copy(rowId = rowId)
    }

    /** `message.complete.persisted_turn`: the newest human row and the newest assistant row, only when each is still unbound. */
    fun bindRows(turn: PersistedTurn) {
        turn.userRowId?.let(::bindUserRow)
        turn.finalAssistantRowId?.let { rowId ->
            val last = live.values.lastOrNull { it is MessageItem && it.role == MessageRole.Assistant } as? MessageItem ?: return@let
            if (last.rowId == null) live[last.id] = last.copy(rowId = rowId)
        }
    }

    /** Drops every live row. Called when saved history has caught up with them. */
    fun clearItems() {
        live.clear()
        text = ""; reasoning = ""; segmentId = null; sealedSegmentId = null; reasoningSealed = false
    }

    fun retain(predicate: (TranscriptItem) -> Boolean) {
        live.entries.removeAll { !predicate(it.value) }
    }

    fun accept(event: WireMessage.Event): Change {
        val change = Change()
        event.sequence?.let { sequence ->
            if (sequence <= lastSequence) return change.also { it.ignored = true }
            lastSequence = sequence
        }
        if (event.type.startsWith("message.") || event.type.startsWith("tool.")) hasLiveEvents = true
        val p = event.payload
        val key = "$epoch:${event.sequence ?: "x${++anonymous}"}"
        when (event.type) {
            "message.start" -> {
                change.started = true
                running = true
                turnId = key
                text = ""; reasoning = ""; reasoningSegment = 0; reasoningSealed = false
                segment = 0; segmentId = null; sealedSegmentId = null
            }
            "message.delta" -> {
                val delta = p["text"].asString.orEmpty()
                if (delta.isNotEmpty()) finishReasoning()
                running = true
                text += delta
                if (text.isNotEmpty()) publishText(text, key, complete = false)
            }
            "message.interim" -> {
                finishReasoning()
                val interim = p["text"].asString.orEmpty()
                if (interim.isNotEmpty()) {
                    publishText(interim, key, complete = true)
                    sealedSegmentId = segmentId
                }
                text = ""; reasoning = ""; segment += 1; segmentId = null
            }
            "message.complete" -> complete(p, key, change)
            "reasoning.delta" -> {
                val delta = p["text"].asString.orEmpty()
                if (reasoningSealed && delta.isNotEmpty()) { reasoningSegment += 1; reasoningSealed = false; reasoning = "" }
                reasoning += delta
                if (reasoning.isNotEmpty()) activity("reasoning:$reasoningSegment", ActivityKind.Reasoning, "Reasoning", reasoning, terminal = false, payload = p)
            }
            "thinking.delta" -> thinking(p)?.let { change.status = it }
            "tool.generating" -> exactly(p, setOf("name"))?.let { fields ->
                val name = fields["name"].asString ?: return@let
                change.status = if (name.isEmpty()) "Preparing tool" else "Preparing $name"
            }
            "status.update" -> exactly(p, setOf("kind", "text"))?.let { fields ->
                val kind = fields["kind"].asString ?: return@let
                val words = fields["text"].asString ?: return@let
                change.status = words.ifEmpty { "Working" }
                change.compaction = when (kind) {
                    "compressing" -> CompactionSignal.Compressing
                    "compacting" -> CompactionSignal.Compacting
                    "compacted" -> CompactionSignal.Compacted
                    else -> null
                }
            }
            "notice" -> exactly(p, setOf("message"))?.let { fields ->
                val message = fields["message"].asString ?: return@let
                activity("notice:$key", ActivityKind.Notice, "Hermes notice", message, terminal = true, payload = JsonObject(emptyMap()), lifecycle = ActivityLifecycle.Recorded)
                if (message.isNotEmpty()) change.status = message
            }
            "tool.start", "tool.progress", "tool.complete" -> {
                val toolId = p["tool_id"].asString?.takeIf { it.isNotEmpty() } ?: return change
                if (event.type == "tool.start") finishReasoning()
                activity("tool:$toolId", ActivityKind.Tool, p["name"].asString ?: "Tool", p["context"].asString, event.type == "tool.complete", p, toolId = toolId)
            }
            "session.info" -> sessionInfo(p, change)
            "session.title" -> p["title"].asString?.let { change.title = it }
            "error" -> change.errorEvent = true
            else -> if (event.type.startsWith("subagent.")) subagent(event.type, p)
        }
        return change
    }

    private fun complete(p: JsonObject, key: String, change: Change) {
        val failure = turnFailure(p)
        if (failure != null && !running) {
            // Hermes refused some turns before message.start. Its failed final is a turn of its own, and its end.
            turnId = key
            text = ""; reasoning = ""; reasoningSegment = 0; reasoningSealed = false
            segment = 0; segmentId = null; sealedSegmentId = null
            change.terminal = true
            change.failedBeforeStart = true
        }
        if (failure != null) { failedTurnId = turnId; change.turnFailure = failure }
        finishReasoning()
        val final = p["text"].asString ?: text
        val reused = p["response_reused"].asBool == true || p["response_previewed"].asBool == true
        if (final.isNotEmpty() && reused && segmentId == null && settleSealedAnswer(final)) {
            change.settledAnswer = true
        } else if (final.isNotEmpty()) {
            publishText(final, key, complete = true, failure = failure)
        }
        p["reasoning"].asString?.takeIf { it.isNotEmpty() }?.let {
            reasoning = it
            activity("reasoning:$reasoningSegment", ActivityKind.Reasoning, "Reasoning", it, terminal = true, payload = p)
        }
        p["error"].asString?.let { change.terminalError = it }
        p["persisted_turn"].asObject?.let { turn ->
            change.persistedTurn = PersistedTurn(turn["user_row_id"].asLong?.takeIf { it > 0 }, turn["final_assistant_row_id"].asLong?.takeIf { it > 0 })
        }
    }

    private fun sessionInfo(p: JsonObject, change: Change) {
        p["stored_session_id"].asString?.let { change.storedIdReport = it }
        val info = RuntimeInfo(
            model = p["model"].asString, provider = p["provider"].asString, reasoningEffort = p["reasoning_effort"].asString,
            serviceTier = p["service_tier"].asString, cwd = p["cwd"].asString,
        )
        if (info != RuntimeInfo()) change.runtime = info
        p["title"].asString?.takeIf { it.isNotEmpty() }?.let { change.title = it }
        val active = p["running"].asBool ?: return
        change.terminal = running && !active
        running = active
        if (change.terminal) {
            for ((id, item) in live.entries.toList()) {
                if (item is ActivityItem && item.kind != ActivityKind.Subagent && item.lifecycle == ActivityLifecycle.Running) {
                    val settled = if (item.kind == ActivityKind.Tool) ActivityLifecycle.Recorded else ActivityLifecycle.Succeeded
                    live[id] = item.copy(lifecycle = settled)
                }
            }
        }
    }

    private fun subagent(type: String, p: JsonObject) {
        val child = p["child_session_id"].asString?.takeIf { it.isNotEmpty() }
        val id = p["subagent_id"].asString?.takeIf { it.isNotEmpty() } ?: child ?: return
        val key = "subagent:$id"
        val previous = live["$turnId:$key"] as? ActivityItem
        val detail = if (type == "subagent.thinking" || type == "subagent.text") {
            (previous?.detail ?: "") + p["text"].asString.orEmpty()
        } else p["summary"].asString ?: p["tool_preview"].asString ?: p["text"].asString
        activity(key, ActivityKind.Subagent, p["goal"].asString?.takeIf { it.isNotEmpty() } ?: previous?.title ?: "Subagent",
            detail ?: previous?.detail, type == "subagent.complete", p)
    }

    private fun finishReasoning() {
        if (reasoningSealed || reasoning.isEmpty()) return
        val unfinished = live.entries.filter { (_, item) ->
            item is ActivityItem && item.turnId == turnId && item.kind == ActivityKind.Reasoning && item.lifecycle == ActivityLifecycle.Running
        }
        if (unfinished.isEmpty()) return
        reasoningSealed = true
        for ((id, item) in unfinished) live[id] = (item as ActivityItem).copy(lifecycle = ActivityLifecycle.Succeeded)
    }

    private fun publishText(value: String, eventKey: String, complete: Boolean, failure: TurnFailure? = null) {
        val id = segmentId ?: "live:${turnId.ifEmpty { eventKey }}:$segment".also { segmentId = it }
        val old = live[id] as? MessageItem
        live[id] = (old ?: MessageItem(id, MessageRole.Assistant, "assistant", value, ItemOrigin.Live))
            .copy(text = value, complete = complete, failure = failure ?: old?.failure)
    }

    private fun settleSealedAnswer(final: String): Boolean {
        val id = sealedSegmentId ?: return false
        val item = live[id] as? MessageItem ?: return false
        if (item.role != MessageRole.Assistant || item.text.trim() != final.trim()) return false
        live[id] = item.copy(complete = true)
        segmentId = id
        return true
    }

    private fun activity(
        key: String, kind: ActivityKind, title: String, detail: String?, terminal: Boolean, payload: JsonObject,
        toolId: String? = null, lifecycle: ActivityLifecycle? = null,
    ) {
        val id = "$turnId:$key"
        val old = live[id] as? ActivityItem
        val status = payload["status"].asString
        val finalOnlyReasoning = terminal && kind == ActivityKind.Reasoning && old == null
        val state = lifecycle ?: when {
            status == "failed" || status == "error" -> ActivityLifecycle.Failed
            status == "cancelled" || status == "interrupted" -> ActivityLifecycle.Cancelled
            finalOnlyReasoning -> ActivityLifecycle.Recorded
            terminal -> ActivityLifecycle.Succeeded
            old != null && old.lifecycle != ActivityLifecycle.Running -> old.lifecycle
            else -> ActivityLifecycle.Running
        }
        live[id] = ActivityItem(
            id = id, kind = kind, title = old?.title ?: title, detail = detail ?: old?.detail, lifecycle = state,
            toolCallId = toolId ?: old?.toolCallId, turnId = turnId, origin = ItemOrigin.Live,
            arguments = jsonText(payload["args"]) ?: old?.arguments, result = jsonText(payload["result"]) ?: old?.result,
        )
    }

    private fun jsonText(value: JsonElement?): String? = when {
        value == null || value is JsonNull -> null
        value is JsonPrimitive && value.isString -> value.content
        else -> value.toString()
    }

    private fun exactly(p: JsonObject, keys: Set<String>): JsonObject? = p.takeIf { it.keys == keys }

    /** Spinner text only: `text`, optionally `rendered` and `verbose`, nothing else. */
    private fun thinking(p: JsonObject): String? {
        if (!setOf("text", "rendered", "verbose").containsAll(p.keys)) return null
        val raw = p["text"].asString ?: return null
        p["rendered"]?.let { if (it !is JsonNull && it.asString == null) return null }
        p["verbose"]?.let { if (it !is JsonNull && it.asBool == null) return null }
        val trimmed = raw.take(256).trim()
        return trimmed.ifEmpty { "Working" }
    }

    private fun turnFailure(p: JsonObject): TurnFailure? {
        if (p["status"].asString != "error") return null
        val surface = p["error_surface"].asObject ?: JsonObject(emptyMap())
        val billing = p["billing"].asObject ?: JsonObject(emptyMap())
        fun token(v: JsonElement?) = v.asString?.trim()?.takeIf { it.isNotEmpty() && utf8Length(it) <= 64 && it.all { c -> c.code in 33..126 } }
        fun label(v: JsonElement?) = v.asString?.trim()?.takeIf { s -> s.isNotEmpty() && s.none { c -> Character.isISOControl(c) } }?.take(80)
        val resets = surface["resets_at"].asDouble?.takeIf { it > 1_000_000_000 && it < 100_000_000_000 }
        val billingUrl = billing["billing_url"].asString?.takeIf { it.length <= 2_048 && it.startsWith("https://") && it.length > 8 }
        return TurnFailure(
            layer = token(surface["layer"]), code = token(surface["code"]) ?: token(p["failure_reason"]),
            retryable = surface["retryable"].asBool ?: true,
            providerLabel = label(surface["provider_label"]) ?: label(billing["provider_label"]),
            resetsAtEpochSeconds = resets, billingUrl = billingUrl,
        )
    }
}
