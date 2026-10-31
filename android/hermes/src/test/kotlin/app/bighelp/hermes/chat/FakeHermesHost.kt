package app.bighelp.hermes.chat

import app.bighelp.hermes.ConnectionOwner
import app.bighelp.hermes.DispatchOutcome
import app.bighelp.hermes.RequestCancelledException
import app.bighelp.hermes.GatewayCapabilities
import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.GatewayEvent
import app.bighelp.hermes.GatewaySocket
import app.bighelp.hermes.GatewayState
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.IncomingServerRequest
import app.bighelp.hermes.ServerRequestHandler
import app.bighelp.hermes.ServerResponse
import app.bighelp.hermes.WireMessage
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * A scripted Hermes for the chat tests: a small model of the real host (profiles, stored sessions with physical
 * history rows, runtimes with a replay ring, idempotent create) behind the same seams the repository uses. It is
 * not Hermes; it follows the documented contract, including the facts that make the client's rules necessary:
 * `prompt.submit` answers `streaming` (never `queued` for an idle chat) and the reply arrives later as events,
 * a lost receipt still applies the mutation, and a compaction successor shows up only on resume or in history.
 */
internal class FakeHermesHost : ChatGateway, ChatRest {
    /** [fence] is the socket generation the caller asked to be fenced to (null: not fenced). */
    class Recorded(val method: String, val params: JsonObject, val generation: Long, val fence: Long? = null)
    class RestRecorded(val route: String, val query: List<Pair<String, String>>)

    inner class Session(val id: String, val profile: String) {
        var title = ""
        var archived = false
        var autoArchived = false
        var hidden = false
        var pinned = false
        var cwd: String? = null
        var source = "bighelp"
        var model = "stub-model"
        var provider = "stub-provider"
        var reasoning = "medium"
        var tier = "normal"
        var startedAt = 1_792_000_000.0 + sessions.size
        var lastActive = startedAt
        var lineage: List<String>? = null
        var lineageRoot: String? = null
        val rows = ArrayList<JsonObject>()

        fun addRow(role: String, content: String?, extra: Map<String, JsonElement> = emptyMap()): Long {
            val rowId = nextRowId.getAndIncrement()
            rows += buildJsonObject {
                put("id", rowId); put("session_id", id); put("role", role)
                put("content", content); put("timestamp", startedAt + rows.size)
                extra.forEach { (k, v) -> put(k, v) }
            }
            lastActive = startedAt + rows.size
            return rowId
        }
    }

    inner class Runtime(val id: String, var stored: String, val profile: String) {
        var running = false
        var seq = 0L
        var lazy = true
        val ring = ArrayList<JsonObject>()
        val openRequests = ArrayList<JsonObject>()
        var interruptRequested = false
        val steers = ArrayList<String>()
    }

    // ---- connection

    private val nextRowId = AtomicLong(100)
    var generation = 1L
        private set
    var exclusiveSubmit: Boolean? = true
    var epoch = "epoch-1"
    var heartbeat = true

    override val state: MutableStateFlow<GatewayState> = MutableStateFlow(connectedState())
    @Volatile private var delivery = Channel<GatewayEvent>(Channel.RENDEZVOUS)
    override val events: Flow<GatewayEvent> = flow { for (event in delivery) emit(event) }

    /**
     * The collector fell too far behind: the stream the client is reading fails with the gateway's own overflow
     * error (events are lost), and the next subscription starts on a fresh stream, as the real client's does.
     */
    fun overflowEvents() {
        val old = delivery
        delivery = Channel(Channel.RENDEZVOUS)
        old.close(HermesException(HermesException.Kind.TooManyRequests))
    }

    private fun owner(gen: Long) = ConnectionOwner("http://fake.test", "dashboard-session", gen)

    private fun connectedState(): GatewayState {
        val ready = WireMessage.Event("gateway.ready", null, buildJsonObject { put("replay_epoch", epoch); put("heartbeat", heartbeat) }, null)
        var socket = GatewaySocket.opening(owner(generation)).upgraded().receive(ready)
        exclusiveSubmit?.let { socket = socket.discovered(GatewayCapabilities(it)) }
        return GatewayState(GatewayConnection.Connected, generation, owner(generation), socket, epoch, heartbeat, null)
    }

    /** The host's guarantee changes (for example it reports false): the current socket's capabilities are republished. */
    fun changeExclusiveSubmit(value: Boolean?) {
        exclusiveSubmit = value
        state.value = connectedState()
    }

    /** The socket ends without an automatic recovery: the client is Idle and every pending request fails. */
    fun dropConnection() {
        state.value = GatewayState(GatewayConnection.Idle, generation, null, null, null, false,
            HermesException(HermesException.Kind.Disconnected))
    }

    /** A replacement socket becomes ready: a new generation, and `gateway.ready` is the first event on it. */
    suspend fun newSocket(newEpoch: String = epoch) {
        generation += 1
        epoch = newEpoch
        state.value = connectedState()
        deliver(WireMessage.Event("gateway.ready", null, buildJsonObject { put("replay_epoch", epoch); put("heartbeat", heartbeat) }, null))
        // Return only once the client has fully processed the ready event (it closes admission synchronously there).
        flush()
    }

    // ---- recording and scripting

    val requests = CopyOnWriteArrayList<Recorded>()
    val restRequests = CopyOnWriteArrayList<RestRecorded>()
    fun calls(method: String) = requests.filter { it.method == method }
    fun count(method: String) = calls(method).size

    private val overrides = HashMap<String, ArrayDeque<suspend (JsonObject) -> JsonElement>>()

    /** Replaces the next call of [method] with [behavior]. It may call [defaultHandle] itself to apply the real effect first. */
    fun once(method: String, behavior: suspend (JsonObject) -> JsonElement) {
        overrides.getOrPut(method) { ArrayDeque() }.addLast(behavior)
    }

    fun rejectOnce(method: String, code: Long, reason: String? = null) = once(method) {
        throw HermesException(
            if (code == 4090L && reason == "MAX_CONCURRENT_SESSIONS") HermesException.Kind.ActiveSessionLimit else HermesException.Kind.RpcRejected,
            code = code, reason = reason,
        )
    }

    /** The host applies [method] and the connection dies before the receipt: the client sees an unknown outcome. */
    fun loseReplyOnce(method: String, dropSocket: Boolean = true) = once(method) { params ->
        defaultHandle(method, params)
        if (dropSocket) dropConnection()
        throw HermesException(HermesException.Kind.Disconnected, outcomeUnknown = true)
    }

    fun timeOutOnce(method: String, applyFirst: Boolean = true) = once(method) { params ->
        if (applyFirst) defaultHandle(method, params)
        throw HermesException(HermesException.Kind.TimedOut, outcomeUnknown = true)
    }

    var rejectCwdExplicit = false
    var ignoreRequestedModel = false
    var failRest: ((String) -> Boolean)? = null

    // ---- model of the host

    val profiles = LinkedHashMap<String, JsonObject>()
    val sessions = LinkedHashMap<String, Session>()
    val runtimes = LinkedHashMap<String, Runtime>()
    private val idempotency = HashMap<String, String>()
    private val successors = HashMap<String, String>()
    private var counter = 0
    val canonicalIds = HashMap<String, String>()

    init {
        addProfile("research", "Research Bot")
        addProfile("scratch")
    }

    fun addProfile(name: String, display: String? = null) {
        profiles[name] = buildJsonObject { put("name", name); if (display != null) put("display_name", display) }
    }

    fun addSession(profile: String, id: String = "saved-${++counter}", title: String = "Chat $id", build: Session.() -> Unit = {}): Session =
        Session(id, profile).also { it.title = title; it.build(); sessions[id] = it }

    /** Marks [session] as the profile's canonical Bot Chat (hidden from the list; named by the registry). */
    fun makeCanonical(session: Session) {
        session.hidden = true
        session.title = "Bot Chat"
        canonicalIds[session.profile] = session.id
    }

    /** The host compacts [oldId]: its transcript continues under [newId], and resume of the old ID resolves to the new one. */
    fun compact(oldId: String, newId: String) {
        val old = sessions.getValue(oldId)
        val next = addSession(old.profile, newId, old.title) {
            rows += old.rows.map { JsonObject(it + ("session_id" to JsonPrimitive(newId))) }
            lineageRoot = old.lineageRoot ?: oldId
            lineage = (old.lineage ?: listOf(oldId)) + newId
        }
        old.archived = false
        successors[oldId] = newId
        runtimes.values.filter { it.stored == oldId }.forEach { it.stored = newId }
        sessions.remove(oldId)?.also { sessions[oldId] = it }
        next.lastActive = old.lastActive
    }

    private fun tip(id: String): String { var t = id; while (successors.containsKey(t)) t = successors.getValue(t); return t }

    fun runtimeFor(stored: String): Runtime? = runtimes.values.lastOrNull { it.stored == tip(stored) }

    // ---- events

    private suspend fun deliver(event: WireMessage.Event, gen: Long = generation) { delivery.send(GatewayEvent(gen, event)) }

    /** Emits one runtime event with the next sequence number and keeps it in the replay ring. */
    suspend fun emit(runtime: Runtime, type: String, payload: String = "{}", gen: Long = generation) {
        val params = emitParams(runtime, type, payload)
        deliver(WireMessage.Event(type, runtime.id, params["payload"] as JsonObject, params["seq"].asLong, params), gen)
    }

    /** Records an event as the host ring would, without delivering it (the client missed it). */
    fun emitSilently(runtime: Runtime, type: String, payload: String = "{}") { emitParams(runtime, type, payload) }

    private fun emitParams(runtime: Runtime, type: String, payload: String): JsonObject {
        runtime.seq += 1
        val params = buildJsonObject {
            put("type", type); put("session_id", runtime.id); put("seq", runtime.seq)
            put("payload", jsonObject(payload))
        }
        runtime.ring += params
        return params
    }

    /** Waits until the client has fully processed everything emitted before this call. */
    suspend fun flush() {
        repeat(2) { deliver(WireMessage.Event("test.flush", null, JsonObject(emptyMap()), null)) }
    }

    /** A complete streamed turn: start, deltas, final, row persistence, `running:false`. */
    suspend fun streamReply(runtime: Runtime, text: String, userRowId: Long? = null, deltas: List<String> = listOf(text)) {
        val session = sessions.getValue(runtime.stored)
        runtime.running = true
        emit(runtime, "message.start")
        deltas.forEach { emit(runtime, "message.delta", """{"text":${JsonPrimitive(it)}}""") }
        val assistant = session.addRow("assistant", text)
        val payload = buildJsonObject {
            put("text", text)
            put("persisted_turn", buildJsonObject { userRowId?.let { put("user_row_id", it) }; put("final_assistant_row_id", assistant) })
        }
        emit(runtime, "message.complete", payload.toString())
        runtime.running = false
        emit(runtime, "session.info", """{"running":false}""")
    }

    // ---- server requests

    val handlers = HashMap<String, ServerRequestHandler>()
    private val serverCounter = AtomicLong()

    /** The host asks the client something. The returned deferred completes with the client's response. */
    fun serverRequest(scope: CoroutineScope, method: String, params: String, id: String = "server-${serverCounter.incrementAndGet()}", gen: Long = generation): Deferred<ServerResponse> {
        val handler = handlers[method]
        return scope.async {
            handler?.handle(IncomingServerRequest(gen, id, method, jsonObject(params)))
                ?: ServerResponse.Failure(-32601, "Method not supported by this client")
        }
    }

    // ---- ChatGateway

    /** A request held before its frame is written: cancelling the caller then is cancelling an unsent request. */
    class Hold { val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>() }
    private val writeHolds = HashMap<String, ArrayDeque<Hold>>()
    fun holdBeforeWrite(method: String): Hold = Hold().also { writeHolds.getOrPut(method) { ArrayDeque() }.addLast(it) }

    override suspend fun request(method: String, params: JsonObject, timeoutMillis: Long?, generation: Long?): JsonElement {
        // Like the real client, a cancelled caller learns whether its frame had been handed to the socket.
        var written = false
        try {
            writeHolds[method]?.removeFirstOrNull()?.let { it.reached.complete(Unit); it.release.await() }
            val live = state.value
            if (live.connection != GatewayConnection.Connected) throw HermesException(HermesException.Kind.NotConnected)
            // The real client compares the fence with the socket it queues on: a mismatch writes nothing.
            if (generation != null && live.generation != generation) throw HermesException(HermesException.Kind.NotConnected)
            requests += Recorded(method, params, live.generation, generation)
            written = true
            overrides[method]?.removeFirstOrNull()?.let { return it(params) }
            return defaultHandle(method, params)
        } catch (e: CancellationException) {
            if (e is RequestCancelledException) throw e
            throw RequestCancelledException(if (written) DispatchOutcome.MayHaveBeenSent else DispatchOutcome.NotSent).also { it.initCause(e) }
        }
    }

    var admissionPreparations = 0
    var failNextAdmission: HermesException? = null
    override suspend fun prepareForAdmission() {
        admissionPreparations += 1
        failNextAdmission?.let { failNextAdmission = null; throw it }
        if (state.value.connection != GatewayConnection.Connected) throw HermesException(HermesException.Kind.NotConnected)
    }

    override suspend fun verifyLiveness() = Unit
    override suspend fun reconnect(): GatewayState = state.value
    val adopted = CopyOnWriteArrayList<Triple<JsonElement, String, Long>>()
    override suspend fun adoptOpenRequests(rows: JsonElement, runtimeId: String, generation: Long) { adopted += Triple(rows, runtimeId, generation) }
    override fun setServerRequestHandler(method: String, handler: ServerRequestHandler?) {
        if (handler == null) handlers.remove(method) else handlers[method] = handler
    }

    // ---- RPC behavior

    suspend fun defaultHandle(method: String, p: JsonObject): JsonElement = when (method) {
        "gateway.ping", "client.capabilities" -> JsonObject(emptyMap())
        "profiles.list" -> buildJsonObject {
            put("profiles", buildJsonArray {
                profiles.values.forEach { row ->
                    val name = row["name"].asString!!
                    add(JsonObject(row + (canonicalIds[name]?.let { id ->
                        mapOf("canonical_session" to buildJsonObject { put("id", id); sessions[id]?.let { put("resolved_id", tip(id)) } })
                    } ?: emptyMap())))
                }
            })
        }
        "session.create" -> create(p)
        "session.resume" -> resume(p)
        "session.activate" -> activate(p)
        "session.events.since" -> eventsSince(p)
        "prompt.submit" -> submit(p)
        "session.steer" -> steer(p)
        "session.interrupt" -> { runtime(p).interruptRequested = true; buildJsonObject { put("status", "interrupted") } }
        "session.title" -> {
            val rt = runtime(p)
            val title = p["title"].asString!!
            if (sessions.values.any { it.id != rt.stored && it.title == title && it.hidden && title == "Bot Chat" }) throw HermesException(HermesException.Kind.RpcRejected, code = 4022)
            val session = sessions.getValue(rt.stored)
            session.title = title
            // A hidden chat titled "Bot Chat" becomes the profile's registry chat, as on the real host.
            if (title == "Bot Chat" && session.hidden) canonicalIds.putIfAbsent(session.profile, session.id)
            buildJsonObject { put("pending", false); put("title", title) }
        }
        "commands.catalog" -> commandCatalog
        "slash.exec" -> slashExec(p)
        "command.dispatch" -> dispatch(p)
        "model.options" -> modelOptions(p)
        "config.set" -> configSet(p)
        "config.get" -> configGet(p)
        "session.archive" -> archive(p, "archived")
        "session.set_hidden" -> archive(p, "hidden")
        "session.delete" -> delete(p)
        "session.branch" -> branch(p)
        "session.compress" -> buildJsonObject { put("status", "compressed"); put("removed", 4); put("before_tokens", 1000); put("after_tokens", 400) }
        else -> throw HermesException(HermesException.Kind.RpcRejected, code = -32601)
    }

    private fun runtime(p: JsonObject): Runtime {
        val id = p["session_id"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        return runtimes[id] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4001)
    }

    private fun info(rt: Runtime): JsonObject {
        val s = sessions.getValue(rt.stored)
        return buildJsonObject {
            put("profile_name", rt.profile); put("stored_session_id", rt.stored); put("model", s.model); put("provider", s.provider)
            put("reasoning_effort", s.reasoning); put("service_tier", s.tier); s.cwd?.let { put("cwd", it) }; put("lazy", rt.lazy)
        }
    }

    private var runtimeCounter = 0
    private fun nextRuntimeId() = "rt-${++runtimeCounter}"
    private var createCounter = 0
    private fun create(p: JsonObject): JsonElement {
        val profile = p["profile"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        if (!profiles.containsKey(profile)) throw HermesException(HermesException.Kind.RpcRejected, code = 4007)
        if (p["source"].asString != "bighelp") throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        if (rejectCwdExplicit && p.containsKey("cwd_explicit")) throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        val key = p["idempotency_key"].asString
        key?.let { existing -> idempotency[existing]?.let { stored -> return created(runtimes.values.last { it.stored == stored }, p) } }
        val session = addSession(profile, "saved-c${++createCounter}", p["title"].asString ?: "") {
            hidden = p["hidden"].asBool == true
            cwd = p["cwd"].asString
            if (!ignoreRequestedModel) p["model"].asString?.let { model = it }
            p["provider"].asString?.let { provider = it }
            p["reasoning_effort"].asString?.let { reasoning = it }
        }
        val rt = Runtime(nextRuntimeId(), session.id, profile).also { runtimes[it.id] = it }
        key?.let { idempotency[it] = session.id }
        return created(rt, p)
    }

    private fun created(rt: Runtime, p: JsonObject) = buildJsonObject {
        put("session_id", rt.id); put("stored_session_id", rt.stored); put("session_key", rt.stored)
        put("message_count", 0); put("messages", JsonArray(emptyList())); put("running", false)
        put("info", info(rt))
    }

    private fun resume(p: JsonObject): JsonElement {
        val requested = p["session_id"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        if (p["source"].asString != "bighelp") throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        val stored = tip(requested)
        val session = sessions[stored] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4007)
        if (p["profile"].asString != session.profile) throw HermesException(HermesException.Kind.RpcRejected, code = 4007)
        val rt = runtimes.values.lastOrNull { it.stored == stored } ?: Runtime(nextRuntimeId(), stored, session.profile).also { runtimes[it.id] = it }
        return buildJsonObject {
            put("session_id", rt.id); put("stored_session_id", stored); put("session_key", stored); put("resumed", stored)
            put("running", rt.running); put("messages", JsonArray(emptyList())); put("messages_omitted", true)
            put("info", info(rt))
        }
    }

    private fun activate(p: JsonObject): JsonElement {
        val rt = runtime(p)
        return buildJsonObject {
            put("session_id", rt.id); put("session_key", rt.stored); put("running", rt.running)
            put("messages", JsonArray(emptyList())); put("messages_omitted", true); put("info", info(rt))
            put("pending_connection", JsonNull)
        }
    }

    var legacyPrompts = false
    var truncateReplay = false
    private fun eventsSince(p: JsonObject): JsonElement {
        val id = p["session_id"].asString.orEmpty()
        val last = p["last_seen"].asLong ?: 0
        if (id.isEmpty()) return buildJsonObject {
            put("epoch", epoch); put("latest_seq", 0); put("truncated", false); put("count", 0)
            put("events", JsonArray(emptyList())); put("open_requests", JsonArray(emptyList()))
        }
        val rt = runtimes[id] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4001)
        return buildJsonObject {
            put("epoch", epoch); put("latest_seq", rt.seq); put("truncated", truncateReplay)
            put("events", JsonArray(if (truncateReplay) emptyList() else rt.ring.filter { it["seq"].asLong!! > last }))
            if (!legacyPrompts) put("open_requests", JsonArray(rt.openRequests.toList()))
        }
    }

    var autoReply: String? = null
    var beforeReceipt: (suspend (Runtime) -> Unit)? = null
    private suspend fun submit(p: JsonObject): JsonElement {
        val rt = runtime(p)
        val session = sessions.getValue(rt.stored)
        val text = p["text"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        if (rt.running) {
            return if (p["queued"].asBool == true) buildJsonObject { put("status", "queued") } else buildJsonObject { put("status", "steered") }
        }
        val userRow = session.addRow("user", text)
        rt.lazy = false
        rt.running = true
        beforeReceipt?.invoke(rt)
        return buildJsonObject { put("status", "streaming"); put("user_row_id", userRow) }
    }

    private fun steer(p: JsonObject): JsonElement {
        val rt = runtime(p)
        if (!rt.running) return buildJsonObject { put("status", "rejected") }
        rt.steers += p["text"].asString.orEmpty()
        return buildJsonObject { put("status", "queued") }
    }

    val commandCatalog: JsonObject = jsonObject(
        """{"pairs":[["/help","Show help"],["/plan","Plan first"],["/deploy-skill","Run the deploy skill"],["/model","Pick a model"]],
            "canon":{"/h":"/help"},"skills":{"deploy-skill":{}},
            "categories":[{"name":"Plugin Commands","pairs":[["/model","Pick a model"]]}],
            "commands":{"/plan":{"argument_mode":"text"}}}""",
    )
    val slashOutputs = HashMap<String, JsonObject>()
    val dispatchResults = HashMap<String, JsonObject>()
    private suspend fun slashExec(p: JsonObject): JsonElement {
        runtime(p)
        val command = p["command"].asString.orEmpty()
        val name = command.trim().removePrefix("/").substringBefore(' ').lowercase()
        if (name == "deploy-skill") throw HermesException(HermesException.Kind.RpcRejected, code = 4018)
        return slashOutputs[name] ?: buildJsonObject { put("output", "ran $name") }
    }

    private suspend fun dispatch(p: JsonObject): JsonElement {
        runtime(p)
        val name = p["name"].asString.orEmpty()
        return dispatchResults[name] ?: buildJsonObject { put("type", "skill"); put("message", "EXPANDED(${p["arg"].asString.orEmpty()})") }
    }

    var modelOptionRows: JsonObject = jsonObject(
        """{"model":"stub-model","providers":[{"slug":"stub-provider","name":"Stub","is_current":true,"models":["stub-model","big-model"]},
            {"slug":"other-provider","name":"Other","models":["other-model"]}]}""",
    )
    private fun modelOptions(p: JsonObject): JsonElement = modelOptionRows

    var deferModelChange = false
    var requireModelConfirmation = false
    private fun configSet(p: JsonObject): JsonElement {
        val rt = runtime(p)
        val session = sessions.getValue(rt.stored)
        val key = p["key"].asString
        val value = p["value"].asString.orEmpty()
        return when (key) {
            "model" -> {
                val model = value.substringBefore(" --provider ")
                val provider = value.substringAfter(" --provider ").substringBefore(" --session")
                if (requireModelConfirmation && p["confirm_expensive_model"].asBool != true) {
                    return buildJsonObject { put("key", "model"); put("scope", "session"); put("value", model); put("confirm_required", true); put("confirm_message", "That model is expensive. Continue?") }
                }
                if (!deferModelChange) { session.model = model; session.provider = provider }
                buildJsonObject {
                    put("key", "model"); put("scope", "session"); put("value", model); put("confirm_required", false)
                    if (deferModelChange) put("deferred", true)
                }
            }
            "reasoning" -> { session.reasoning = value; buildJsonObject { put("key", "reasoning"); put("value", value) } }
            "fast" -> { session.tier = value; buildJsonObject { put("key", "fast"); put("value", value) } }
            "yolo" -> buildJsonObject { put("key", "yolo"); put("value", if (value == "on") "1" else "0") }
            else -> throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        }
    }

    private fun configGet(p: JsonObject): JsonElement {
        val session = sessions.getValue(runtime(p).stored)
        val key = p["key"].asString
        return buildJsonObject {
            put("key", key)
            put("value", when (key) { "reasoning" -> session.reasoning; "fast" -> session.tier; else -> "" })
        }
    }

    private fun archive(p: JsonObject, field: String): JsonElement {
        val id = p["session_id"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        val session = sessions[tip(id)] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4007)
        val value = p[field].asBool ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        if (field == "archived") { session.archived = value; session.autoArchived = false } else session.hidden = value
        return buildJsonObject { put(field, value); put("session_key", session.id) }
    }

    private fun delete(p: JsonObject): JsonElement {
        val id = p["session_id"].asString ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4000)
        val session = sessions[id] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 4007)
        if (runtimes.values.any { it.stored == session.id && it.running }) throw HermesException(HermesException.Kind.RpcRejected, code = 4009)
        sessions.remove(id)
        return buildJsonObject { put("deleted", id) }
    }

    private fun branch(p: JsonObject): JsonElement {
        val rt = runtime(p)
        val parent = sessions.getValue(rt.stored)
        val count = p["count"].asInt ?: parent.rows.size
        val name = p["name"].asString ?: "${parent.title} · Fork"
        val child = addSession(parent.profile, "saved-b${++counter}", name) {
            // Like the real host, the child's rows are numbered afresh.
            parent.rows.take(count).forEach { addRow(it["role"].asString!!, it["content"].asString) }
        }
        val childRuntime = Runtime(nextRuntimeId(), child.id, parent.profile).also { runtimes[it.id] = it }
        return buildJsonObject {
            put("session_id", childRuntime.id); put("stored_session_id", child.id); put("title", name); put("parent", parent.id)
            put("message_count", count)
            put("messages", buildJsonArray {
                child.rows.forEach { row ->
                    add(buildJsonObject { put("role", row["role"].asString); put("text", row["content"].asString.orEmpty()); put("row_id", row["id"].asLong) })
                }
            })
            put("info", JsonObject(info(childRuntime) + ("running" to JsonPrimitive(false))))
        }
    }

    // ---- REST

    override suspend fun get(route: String, query: List<Pair<String, String>>): JsonElement {
        restRequests += RestRecorded(route, query)
        if (failRest?.invoke(route) == true) throw HermesException(HermesException.Kind.ServerUnavailable)
        fun q(name: String) = query.firstOrNull { it.first == name }?.second
        val result = when {
            route == "/api/sessions" -> listSessions(q("profile")!!, q("offset")!!.toInt(), q("limit")!!.toInt(), q("archived"), q("exclude_sources"))
            route == "/api/sessions/search" -> search(q("profile")!!, q("q")!!, q("limit")!!.toInt())
            route.startsWith("/api/sessions/") && route.endsWith("/messages") -> messages(route.removePrefix("/api/sessions/").removeSuffix("/messages"), q("profile")!!, q("offset")!!.toInt(), q("limit")!!.toInt(), q("order")!!)
            route.startsWith("/api/sessions/") -> detail(route.removePrefix("/api/sessions/"), q("profile"))
            else -> throw HermesException(HermesException.Kind.InvalidResponse)
        }
        // The answer was fixed when the request arrived; a held read delivers that older picture late.
        if (route.endsWith("/messages")) holdMessages?.await()
        return result
    }

    /** When set, history reads answer as if the rows belonged to this other session ID. */
    @Volatile var historySessionOverride: String? = null

    /** When set, history reads answer only after this completes (they keep the data they saw on arrival). */
    @Volatile var holdMessages: kotlinx.coroutines.CompletableDeferred<Unit>? = null

    var legacyListEnvelope = false
    private fun rowOf(s: Session) = buildJsonObject {
        put("id", s.id); put("profile", s.profile); put("title", s.title); put("started_at", s.startedAt); put("last_active", s.lastActive)
        put("message_count", s.rows.size); put("source", s.source); put("pinned", s.pinned)
        if (s.archived) put("archived", true); if (s.autoArchived) put("auto_archived", true)
        s.cwd?.let { put("cwd", it) }
        s.lineageRoot?.let { put("_lineage_root_id", it) }
        s.lineage?.let { ids -> put("_lineage_ids", buildJsonArray { ids.forEach { add(JsonPrimitive(it)) } }) }
        put("preview", s.rows.firstOrNull { it["role"].asString == "user" }?.get("content").asString.orEmpty())
    }

    /** Profiles whose list answers 503, as a real profile with no session store yet does. */
    val unavailableLists = HashSet<String>()

    private fun listSessions(profile: String, offset: Int, limit: Int, archived: String?, excluded: String?): JsonElement {
        if (profile in unavailableLists) throw HermesException(HermesException.Kind.ServerUnavailable)
        val hiddenSources = excluded?.split(',').orEmpty()
        val all = sessions.values.filter { s ->
            s.profile == profile && !s.hidden && s.source !in hiddenSources && tip(s.id) == s.id &&
                (archived == "include" || (archived == "only") == s.archived)
        }.sortedByDescending { it.startedAt }
        val page = all.drop(offset).take(limit)
        return if (legacyListEnvelope) buildJsonObject {
            put("sessions", buildJsonArray { page.forEach { add(rowOf(it)) } }); put("total", all.size); put("limit", limit); put("offset", offset)
        } else buildJsonObject {
            put("object", "list"); put("data", buildJsonArray { page.forEach { add(rowOf(it)) } })
            put("has_more", offset + page.size < all.size); put("limit", limit); put("offset", offset)
        }
    }

    private fun search(profile: String, needle: String, limit: Int): JsonElement = buildJsonObject {
        put("results", buildJsonArray {
            sessions.values.filter { it.profile == profile && !it.hidden && (it.title.contains(needle, true) || it.rows.any { r -> r["content"].asString.orEmpty().contains(needle, true) }) }
                .take(limit).forEach { s ->
                    add(JsonObject(rowOf(s) + ("snippet" to JsonPrimitive(s.rows.firstOrNull { r -> r["content"].asString.orEmpty().contains(needle, true) }?.get("content").asString.orEmpty()))))
                }
        })
    }

    private fun messages(id: String, profile: String, offset: Int, limit: Int, order: String): JsonElement {
        val stored = tip(id)
        val session = sessions[stored] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 404)
        if (session.profile != profile) throw HermesException(HermesException.Kind.RpcRejected, code = 404)
        val ordered = session.rows
        val page = if (order == "latest") ordered.reversed().drop(offset).take(limit).reversed() else ordered.drop(offset).take(limit)
        val answerAs = historySessionOverride ?: stored
        val rows = if (answerAs == stored) page else page.map { JsonObject(it + ("session_id" to JsonPrimitive(answerAs))) }
        return historyEnvelope(rows, offset, limit, order, session = answerAs, profile = profile)
    }

    private fun detail(id: String, profile: String?): JsonElement {
        val s = sessions[tip(id)] ?: throw HermesException(HermesException.Kind.RpcRejected, code = 404)
        return buildJsonObject { put("object", "hermes.session"); put("session", rowOf(s)) }
    }

    // ---- convenience for tests

    /** Rows of a stored session as ids, for assertions. */
    fun rowIds(stored: String) = sessions.getValue(stored).rows.map { it["id"].asLong!! }
}
