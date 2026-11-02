package app.bighelp.hermes

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The ordered Hermes gateway: one authenticated WebSocket at a time, a single ordered reader and a single
 * ordered writer, and nothing written before `gateway.ready`.
 *
 * **Connect.** `connect()` mints credentials through the [HermesAuthenticator] (a fresh single-use ticket
 * for every socket of a gated host), waits up to [GatewayTimings.readyMillis] for `gateway.ready`, then, in
 * order: advertises `client.capabilities {server_requests:true}` **only if handlers are registered**,
 * checks authenticated `GET /api/health`, and asks `gateway.capabilities`. Only then is the state
 * [GatewayConnection.Connected]. The advertisement repeats on every ready socket, so register handlers
 * before connecting.
 *
 * **Never silent about uncertainty.** A frame is marked `sendStarted` before it is handed to the socket. If
 * the connection ends while a mutation is pending, that request fails with
 * [HermesException.outcomeUnknown]; the client does not reconnect on its own, and no request is ever
 * resent on any socket. Reads and controls fail plainly and the automatic same-owner recovery (delays 0, 1
 * and 3 seconds) replaces the socket, advertises again and rediscovers capabilities, for the owner to
 * reconcile with session recovery.
 *
 * **Server requests.** Handlers answer the host's `approval`, `clarify`, `secret` and `sudo` requests. IDs
 * are opaque and live in a table separate from the client's own RPC IDs (64 at most; duplicates and an
 * over-capacity request are ignored). An unknown method gets `-32601`. A matching `request.cancel` (ID
 * **and** method) cancels the handler and removes a queued response.
 *
 * **Ordering and atomicity.** Every received message is decoded whole by [HermesWire] before any entry is
 * applied; entries are applied and published in wire order. Everything mutable lives on one
 * single-threaded dispatcher, so no result or event of an older socket can publish after a newer one starts.
 *
 * **Inbound bounds.** The socket (see `GatewayWebSocket.kt`) refuses a frame by its declared length before
 * allocating for it, caps the sum of fragments at 4 MiB, rejects malformed UTF-8 in a TEXT message instead of
 * repairing it, bounds the upgrade response headers, offers no extensions, and keeps the platform's default
 * TLS certificate and hostname checks.
 *
 * **Outbound bounds.** Frames reach the socket one at a time: the writer stops while the socket still holds
 * unwritten data, so a stalled peer fills this client's own bounded queues (8 MiB of ordinary requests, one
 * attachment of up to 12 MiB counted apart, 4 MiB of server replies) and then refuses new requests with
 * [HermesException.Kind.TooManyRequests] instead of growing without limit.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GatewayClient internal constructor(
    private val authenticator: HermesAuthenticator,
    private val scope: CoroutineScope,
    private val timings: GatewayTimings,
    private val transports: GatewayTransportFactory,
) {
    constructor(
        authenticator: HermesAuthenticator,
        scope: CoroutineScope,
        timings: GatewayTimings = GatewayTimings(),
    ) : this(authenticator, scope, timings, GatewayWebSockets)

    private val serial: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)

    /** Owns only the one-second hard-close timers, so they outlive the caller's scope; each ends by itself. */
    private val fallbackClose = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // Everything below is touched only on [serial], except the concurrent collections.
    private var terminal = false
    private var link: Link? = null
    private var generation = 0L
    private var owners = OwnerState.none
    private var lastFailure: HermesException? = null
    private var opening: Deferred<GatewayState>? = null
    private var openingWaiters = 0
    private var recovery: Job? = null
    private val handlers = ConcurrentHashMap<String, ServerRequestHandler>()
    private val subscribers = ConcurrentHashMap.newKeySet<Channel<GatewayEvent>>()
    private val mutableState = MutableStateFlow(GatewayState(GatewayConnection.Idle, 0, null, null, null, false, null))

    val state: StateFlow<GatewayState> = mutableState.asStateFlow()

    /**
     * Every event of every socket, in wire order, each with its socket generation. A collector sees events
     * from the moment it starts collecting, plus the retained first `gateway.ready` of a socket that is
     * already ready; start collecting before [connect] to see everything. A collector too slow to keep up
     * ([EVENT_BUFFER] events behind) fails with [HermesException.Kind.TooManyRequests] and must resynchronize.
     */
    val events: Flow<GatewayEvent> = flow {
        val channel = Channel<GatewayEvent>(EVENT_BUFFER)
        withContext(serial) {
            subscribers += channel
            link?.let { l ->
                val ready = l.socket.ready
                if (l.socket.phase == SocketPhase.Ready && ready != null) channel.trySend(GatewayEvent(l.generation, ready))
            }
        }
        try {
            for (event in channel) emit(event)
        } finally {
            withContext(NonCancellable + serial) { subscribers -= channel }
        }
    }

    internal val subscriberCount: Int get() = subscribers.size

    /** The bytes waiting in each bounded queue of the current socket (a test seam). */
    internal class QueueSnapshot(val ordinary: Int, val attachment: Int, val server: Int, val frames: Int)

    internal suspend fun queueSnapshot(): QueueSnapshot = withContext(serial) {
        link?.let { QueueSnapshot(it.queuedBytes, it.queuedAttachmentBytes, it.queuedServerBytes, it.outbox.size) } ?: QueueSnapshot(0, 0, 0, 0)
    }

    private class Pending(
        val id: String,
        val method: String,
        val result: CompletableDeferred<JsonElement>,
        val readOnly: Boolean,
        val isAttachment: Boolean,
    ) {
        var sendStarted = false
        var timeout: Job? = null
    }

    /** [kind] decides which of the three bounded queues counts it. */
    private class Outbound(val id: String, val serverMethod: String?, val text: String, val bytes: Int, val attachment: Boolean = false)
    private class ServerTask(val token: Any, val job: Job)

    private sealed interface Inbound {
        class Opened(val subprotocol: String?) : Inbound
        class Message(val bytes: ByteArray) : Inbound
        class Failed(val error: HermesException) : Inbound
    }

    private inner class Link(val generation: Long, val owner: ConnectionOwner, val request: SocketRequest) {
        var socket: GatewaySocket = GatewaySocket.opening(owner)
        var transport: GatewayTransport? = null
        val inbound = Channel<Inbound>(INBOUND_BUFFER)
        var reader: Job? = null
        var heartbeat: Job? = null
        var readyDeadline: Job? = null
        val readyGate = CompletableDeferred<Unit>()
        val pending = LinkedHashMap<String, Pending>()
        val outbox = ArrayDeque<Outbound>()
        var queuedBytes = 0
        var queuedAttachmentBytes = 0
        var queuedServerBytes = 0
        var attachmentId: String? = null
        var draining = false
        val serverRequests = ServerRequestTable()
        val serverTasks = HashMap<String, ServerTask>()
        var closed = false
        var wasReady = false
        var connected = false
        var advertised = false
    }

    // Connecting

    /** Opens the socket, waits for readiness and runs the startup sequence. Joins a connect already running. */
    suspend fun connect(): GatewayState = open(verify = false)

    /**
     * Like [connect] but first rediscovers the host's authentication mode and rechecks the identity (what
     * the automatic recovery does). Returns at once if already connected. It never resends anything.
     */
    suspend fun reconnect(): GatewayState = open(verify = true)

    private suspend fun open(verify: Boolean): GatewayState {
        val flight = withContext(serial) {
            if (terminal) throw notConnected()
            val current = link
            if (current != null && current.connected) return@withContext CompletableDeferred(mutableState.value)
            opening?.let { openingWaiters++; return@withContext it }
            val created = scope.async(serial) {
                try {
                    establish(verify)
                } finally {
                    opening = null
                }
            }
            opening = created
            openingWaiters = 1
            created
        }
        try {
            return flight.await()
        } catch (e: CancellationException) {
            // Nobody is left waiting for this attempt: end it, closing its socket.
            withContext(NonCancellable + serial) { if (--openingWaiters <= 0 && opening === flight) flight.cancel() }
            throw e
        }
    }

    private suspend fun establish(verify: Boolean): GatewayState {
        if (verify) authenticator.verifyModeAndSession()
        val request = authenticator.socketRequest()
        val opened = startLink(request)
        try {
            opened.readyGate.await()
            handshake(opened)
        } catch (e: Throwable) {
            val error = if (e is CancellationException) HermesException(HermesException.Kind.Cancelled) else asHermes(e)
            closeLink(opened, error, notify = false)
            throw if (e is CancellationException) e else error
        }
        return mutableState.value
    }

    private fun startLink(request: SocketRequest): Link {
        if (terminal) throw notConnected()
        link?.let { closeLink(it, HermesException(HermesException.Kind.Disconnected), notify = false) }
        generation += 1
        owners = owners.connect(authenticator.endpoint, authenticator.savedConnection?.principal.orEmpty())
        val created = Link(generation, owners.current!!, request)
        link = created
        publish()

        try {
            created.transport = transports.open(request, listenerFor(created))
        } catch (e: HermesException) {
            closeLink(created, e, notify = false)
            throw e
        }
        created.reader = scope.launch(serial) { readLoop(created) }
        created.readyDeadline = scope.launch(serial) {
            delay(timings.readyMillis)
            if (!created.wasReady) closeLink(created, HermesException(HermesException.Kind.TimedOut), notify = false)
        }
        return created
    }

    /** Socket callbacks arrive on the socket's reader thread; a full buffer blocks it, which is TCP backpressure. */
    private fun listenerFor(owner: Link) = object : GatewayTransportListener {
        override fun opened(negotiatedSubprotocol: String?) {
            owner.inbound.trySendBlocking(Inbound.Opened(negotiatedSubprotocol))
        }

        override fun message(bytes: ByteArray) {
            owner.inbound.trySendBlocking(Inbound.Message(bytes))
        }

        override fun failed(error: HermesException) {
            owner.inbound.trySendBlocking(Inbound.Failed(error))
        }
    }

    /** The single ordered reader: one inbound item at a time, each fully applied before the next is read. */
    private suspend fun readLoop(owner: Link) {
        for (item in owner.inbound) {
            if (owner.closed) return
            when (item) {
                is Inbound.Opened -> {
                    val required = owner.request.requiredSubprotocol
                    if (required != null && item.subprotocol != required) {
                        closeLink(owner, HermesException(HermesException.Kind.InvalidResponse), notify = false)
                        return
                    }
                    owner.socket = owner.socket.upgraded()
                }
                is Inbound.Message -> {
                    val decoded = try {
                        withContext(Dispatchers.Default) { HermesWire.decode(item.bytes) }
                    } catch (e: WireException) {
                        closeLink(owner, HermesException(
                            if (e.kind == WireException.Kind.MessageTooLarge) HermesException.Kind.MessageTooLarge else HermesException.Kind.InvalidResponse,
                        ), notify = true)
                        return
                    }
                    if (owner.closed) return
                    accept(owner, decoded)
                }
                is Inbound.Failed -> {
                    closeLink(owner, item.error, notify = true)
                    return
                }
            }
        }
    }

    private fun accept(owner: Link, messages: List<WireMessage>) {
        for (message in messages) {
            if (owner.closed) return
            when (message) {
                is WireMessage.Event -> {
                    if (message.type == "request.cancel") retireServerRequest(owner, HermesWire.cancellation(message))
                    if (message.type == GatewaySocket.GATEWAY_READY) {
                        val next = owner.socket.receive(message)
                        if (next.phase == SocketPhase.Closed || next.phase != SocketPhase.Ready) {
                            // A second ready on a ready socket, or one that arrives at the wrong time.
                            closeLink(owner, HermesException(HermesException.Kind.InvalidResponse), notify = true)
                            return
                        }
                        owner.socket = next
                        owner.wasReady = true
                        owner.readyDeadline?.cancel()
                        owner.readyGate.complete(Unit)
                        startHeartbeat(owner)
                        pump(owner)
                        publish()
                    }
                    publishEvent(owner, message)
                }
                is WireMessage.Request -> acceptServerRequest(owner, message.id, message.method, message.params)
                is WireMessage.Result -> finish(owner, message.id, Result.success(message.value))
                is WireMessage.Failure -> finish(owner, message.id, Result.failure(rpcFailure(message)))
            }
        }
    }

    private fun rpcFailure(failure: WireMessage.Failure): HermesException {
        val kind = if (failure.code == 4090L && failure.reason == "MAX_CONCURRENT_SESSIONS") {
            HermesException.Kind.ActiveSessionLimit
        } else {
            HermesException.Kind.RpcRejected
        }
        return HermesException(kind, code = failure.code, reason = failure.reason, refusal = failure.message)
    }

    private fun publishEvent(owner: Link, event: WireMessage.Event) {
        val published = GatewayEvent(owner.generation, event)
        for (channel in subscribers) {
            if (channel.trySend(published).isFailure) {
                channel.close(HermesException(HermesException.Kind.TooManyRequests))
                subscribers -= channel
            }
        }
    }

    // Startup sequence

    private suspend fun handshake(owner: Link) {
        if (claimAdvertisement(owner)) {
            try {
                requestOn(owner, "client.capabilities", buildJsonObject { put("server_requests", true) }, timings.advertiseMillis)
            } catch (e: HermesException) {
                // An older host that has no such method needs none; a lost socket is retried by the next one.
                if (e.kind != HermesException.Kind.RpcRejected) {
                    owner.advertised = false
                    throw e
                }
            }
        }
        authenticator.requireHealth()
        val result = requestOn(owner, "gateway.capabilities", JsonObject(emptyMap()), timings.requestMillis)
        val capabilities = try {
            GatewayCapabilities.decode(result)
        } catch (_: WireException) {
            throw HermesException(HermesException.Kind.InvalidResponse)
        }
        withContext(serial) {
            if (owner.closed) throw notConnected()
            owner.socket = owner.socket.discovered(capabilities)
            owner.connected = true
            publish()
        }
    }

    /** True exactly once per socket, and only when real handlers exist: advertising promises to answer. */
    private fun claimAdvertisement(owner: Link): Boolean {
        if (owner.advertised || owner.closed || handlers.isEmpty()) return false
        owner.advertised = true
        return true
    }

    /**
     * Registers (or, with null, removes) the handler for one server-request [method]. Only methods the
     * app can really fulfill belong here; everything else is refused with `-32601`. Registration alone
     * advertises nothing; the client advertises after `gateway.ready`, once per socket, as soon as it has
     * any handler. Handlers survive an automatic same-owner recovery and are forgotten when a connection
     * ends without one (an uncertain mutation, exhausted attempts, [disconnect]).
     */
    fun setServerRequestHandler(method: String, handler: ServerRequestHandler?) {
        require(HermesWire.isValidMethod(method) && method != "event") { "Invalid method" }
        if (handler == null) {
            handlers.remove(method)
            return
        }
        handlers[method] = handler
        scope.launch(serial) {
            val live = link ?: return@launch
            if (live.socket.phase != SocketPhase.Ready || !claimAdvertisement(live)) return@launch
            try {
                requestOn(live, "client.capabilities", buildJsonObject { put("server_requests", true) }, timings.advertiseMillis)
            } catch (e: HermesException) {
                if (e.kind != HermesException.Kind.RpcRejected) live.advertised = false
            }
        }
    }

    // Requests

    /**
     * One JSON-RPC call. [operation] defaults from the method: reads, controls, and the three submission
     * methods (`prompt.submit`, `slash.exec`, `command.dispatch`), which need the host's
     * `per_session_exclusive_submit` guarantee. A refused admission sends nothing.
     *
     * Failures are [HermesException]s; [HermesException.outcomeUnknown] marks a mutation that may have been
     * accepted. Cancelling the caller throws [RequestCancelledException] (a `CancellationException`) saying
     * whether the frame had been handed to the socket; it never stops the host and is never resent.
     *
     * [generation] fences a call that names something only one socket knows (a runtime ID): it is compared with
     * the current socket's generation in the same serial section that reads the socket, and a mismatch is
     * [HermesException.Kind.NotConnected] before anything is queued. [requestOn] then enqueues on exactly that
     * socket object, so the frame can only ever leave on the generation that was named.
     */
    suspend fun request(
        method: String,
        params: JsonObject = JsonObject(emptyMap()),
        timeoutMillis: Long = timings.requestMillis,
        operation: GatewayOperation? = null,
        maximumFrameBytes: Int = DEFAULT_FRAME_BYTES,
        generation: Long? = null,
    ): JsonElement {
        val live = withContext(serial) { link?.takeIf { generation == null || it.generation == generation } } ?: throw notConnected()
        return requestOn(live, method, params, timeoutMillis, operation, maximumFrameBytes)
    }

    private suspend fun requestOn(
        owner: Link,
        method: String,
        params: JsonObject,
        timeoutMillis: Long,
        operation: GatewayOperation? = null,
        maximumFrameBytes: Int = DEFAULT_FRAME_BYTES,
    ): JsonElement {
        if (!HermesWire.isValidMethod(method)) throw HermesException(HermesException.Kind.InvalidResponse)
        val isAttachment = method == "file.attach" || method == "image.attach_bytes"
        val ceiling = if (isAttachment) ATTACHMENT_FRAME_BYTES else maximumOutboundBytes(method)
        if (maximumFrameBytes > ceiling) throw HermesException(HermesException.Kind.MessageTooLarge)
        val id = UUID.randomUUID().toString()
        val text = buildJsonObject {
            put("jsonrpc", "2.0"); put("id", id); put("method", method); put("params", params)
        }.toString()
        val bytes = utf8Length(text)
        if (bytes > maximumFrameBytes || exceedsNesting(text)) throw HermesException(HermesException.Kind.MessageTooLarge)
        val op = operation ?: when {
            DispatchPolicy.isReadOnly(method) -> GatewayOperation.Read
            method in SUBMISSION_METHODS -> GatewayOperation.Submission
            else -> GatewayOperation.Control
        }

        try {
            // Cancellation can land while the frame is already on its way out of enqueue; the cleanup and the
            // dispatch outcome below must cover that window too, or a sent request would be forgotten.
            val pending = withContext(serial) { enqueue(owner, id, method, op, text, bytes, timeoutMillis, isAttachment) }
            return pending.result.await()
        } catch (e: CancellationException) {
            // Returning from withContext into an already cancelled caller rethrows its cancellation, even for
            // NonCancellable work, so the outcome is captured inside the block where the cleanup runs.
            var dispatch = DispatchOutcome.NotSent
            try {
                withContext(NonCancellable + serial) { dispatch = cancelPending(owner, id) }
            } catch (_: CancellationException) {
                // The cleanup above already ran.
            }
            throw RequestCancelledException(dispatch).also { it.initCause(e) }
        }
    }

    private fun maximumOutboundBytes(method: String) = if (method == "profiles.set_asset") 2_800_000 else DEFAULT_FRAME_BYTES

    private fun enqueue(
        owner: Link, id: String, method: String, operation: GatewayOperation, text: String, bytes: Int,
        timeoutMillis: Long, isAttachment: Boolean,
    ): Pending {
        if (owner.closed || owner !== link) throw notConnected()
        when (val admission = owner.socket.admit(operation, owners)) {
            Admission.Admitted -> Unit
            is Admission.Refused -> throw HermesException(
                if (admission.reason == Refusal.ExclusiveSubmitUnavailable) HermesException.Kind.ExclusiveSubmitUnavailable
                else HermesException.Kind.NotConnected,
            )
        }
        if (owner.pending.size >= MAXIMUM_PENDING) throw HermesException(HermesException.Kind.TooManyRequests)
        // Three separate queues, so a flood of ordinary requests can never refuse the one attachment frame the
        // contract allows (up to 12 MiB), nor the other way round, and neither starves a server reply.
        if (isAttachment) {
            if (owner.attachmentId != null || owner.queuedAttachmentBytes + bytes > ATTACHMENT_FRAME_BYTES) {
                throw HermesException(HermesException.Kind.TooManyRequests)
            }
        } else if (owner.queuedBytes + bytes > MAXIMUM_QUEUED_BYTES) {
            throw HermesException(HermesException.Kind.TooManyRequests)
        }

        val pending = Pending(id, method, CompletableDeferred(), DispatchPolicy.isReadOnly(method), isAttachment)
        owner.pending[id] = pending
        if (isAttachment) owner.attachmentId = id
        pending.timeout = scope.launch(serial) {
            delay(timeoutMillis)
            expire(owner, id)
        }
        owner.outbox.addLast(Outbound(id, null, text, bytes, isAttachment))
        if (isAttachment) owner.queuedAttachmentBytes += bytes else owner.queuedBytes += bytes
        pump(owner)
        return pending
    }

    /** Removes a cancelled request and reports how far it got. The frame, if sent, is not recalled. */
    private fun cancelPending(owner: Link, id: String): DispatchOutcome {
        val pending = owner.pending[id] ?: return DispatchOutcome.NotSent
        val outcome = if (pending.sendStarted) DispatchOutcome.MayHaveBeenSent else DispatchOutcome.NotSent
        removePending(owner, id)
        return outcome
    }

    private fun removePending(owner: Link, id: String): Pending? {
        val pending = owner.pending.remove(id) ?: return null
        pending.timeout?.cancel()
        if (owner.attachmentId == id) owner.attachmentId = null
        val index = owner.outbox.indexOfFirst { it.id == id && it.serverMethod == null }
        if (index >= 0) uncount(owner, owner.outbox.removeAt(index))
        return pending
    }

    private fun finish(owner: Link, id: String, result: Result<JsonElement>) {
        val pending = removePending(owner, id) ?: return
        result.fold({ pending.result.complete(it) }, { pending.result.completeExceptionally(it) })
    }

    private fun expire(owner: Link, id: String) {
        val pending = owner.pending[id] ?: return
        finish(owner, id, Result.failure(HermesException(HermesException.Kind.TimedOut, outcomeUnknown = pending.sendStarted && !pending.readOnly)))
        // A stalled send is unparked before anything queued behind it could go out.
        if (pending.sendStarted) closeLink(owner, HermesException(HermesException.Kind.TimedOut), notify = true)
    }

    /** Takes [item] out of whichever bounded queue counted it. */
    private fun uncount(owner: Link, item: Outbound) {
        when {
            item.serverMethod != null -> owner.queuedServerBytes -= item.bytes
            item.attachment -> owner.queuedAttachmentBytes -= item.bytes
            else -> owner.queuedBytes -= item.bytes
        }
    }

    /**
     * The single ordered writer. Nothing leaves before ready; each frame is marked sent before the socket call.
     * Frames go out one at a time, only while the socket holds no unwritten data: a peer that stops reading
     * leaves the rest here, where it is bounded and a queued server reply can still be cancelled.
     */
    private fun pump(owner: Link) {
        if (owner.closed || owner.socket.phase != SocketPhase.Ready) return
        val transport = owner.transport ?: return
        while (owner.outbox.isNotEmpty()) {
            if (transport.hasBufferedData) {
                drainLater(owner)
                return
            }
            val item = owner.outbox.removeFirst()
            uncount(owner, item)
            if (item.serverMethod != null) {
                if (!owner.serverRequests.beginSendingResponse(item.id, item.serverMethod)) continue
            } else {
                val pending = owner.pending[item.id] ?: continue
                pending.sendStarted = true
            }
            if (!transport.send(item.text)) {
                closeLink(owner, HermesException(HermesException.Kind.Disconnected), notify = true)
                return
            }
        }
    }

    /**
     * Resumes the writer once the socket has taken what it was given. The library offers no "written" callback, so the
     * wait polls, but backs off while the peer stays stalled (a stalled socket may last until the request timeout) and
     * starts fast again at the next stall.
     */
    private fun drainLater(owner: Link) {
        if (owner.draining) return
        owner.draining = true
        scope.launch(serial) {
            try {
                var wait = DRAIN_POLL_MILLIS
                while (!owner.closed && owner.outbox.isNotEmpty()) {
                    if (owner.transport?.hasBufferedData == true) {
                        delay(wait)
                        wait = minOf(wait * 2, DRAIN_POLL_MAX_MILLIS)
                    } else {
                        pump(owner)
                        wait = DRAIN_POLL_MILLIS
                    }
                }
            } finally {
                owner.draining = false
            }
        }
    }

    // Keepalive

    private fun startHeartbeat(owner: Link) {
        val hinted = (owner.socket.ready?.payload?.get("heartbeat") as? JsonPrimitive)?.takeIf { !it.isString }?.content == "true"
        val interval = if (hinted) timings.heartbeatMillis else timings.pingMillis
        owner.heartbeat?.cancel()
        owner.heartbeat = scope.launch(serial) {
            while (isActive && !owner.closed) {
                delay(interval)
                if (owner.closed) return@launch
                try {
                    requestOn(owner, "gateway.ping", JsonObject(emptyMap()), timings.pingReplyMillis)
                } catch (e: HermesException) {
                    // Any RPC answer proves the socket; this host just has no ping.
                    if (e.kind == HermesException.Kind.RpcRejected) return@launch
                    closeLink(owner, e, notify = true)
                    return@launch
                } catch (e: RequestCancelledException) {
                    return@launch
                }
            }
        }
    }

    /** A quick check after the app returns or the network changes; a silent socket is replaced at once. */
    suspend fun verifyLiveness() {
        val live = withContext(serial) { link?.takeIf { it.connected } } ?: return
        try {
            requestOn(live, "gateway.ping", JsonObject(emptyMap()), timings.livenessMillis)
        } catch (e: HermesException) {
            if (e.kind == HermesException.Kind.RpcRejected) return
            withContext(serial) { closeLink(live, e, notify = true) }
        }
    }

    /**
     * Proves the socket just before a prompt admission (a ping within [GatewayTimings.admissionMillis]); on
     * failure it waits for the automatic recovery and pings the replacement once. Nothing is constructed or
     * sent for the caller until the proof succeeds.
     * @throws HermesException [HermesException.Kind.NotConnected] when there is no socket to prove.
     */
    suspend fun prepareForAdmission() {
        withContext(serial) { recovery }?.join()
        pingForAdmission(first = true)
    }

    private suspend fun pingForAdmission(first: Boolean) {
        val live = withContext(serial) { if (terminal) null else link?.takeIf { it.connected } } ?: throw notConnected()
        try {
            requestOn(live, "gateway.ping", JsonObject(emptyMap()), timings.admissionMillis)
        } catch (e: HermesException) {
            if (!first) throw e
            withContext(serial) { recovery }?.join()
            pingForAdmission(first = false)
        }
    }

    // Server requests

    private fun acceptServerRequest(owner: Link, id: String, method: String, params: JsonObject) {
        when (owner.serverRequests.register(id, method)) {
            // The existing request stays authoritative and bounded: no second decision or response.
            ServerRequestTable.Registration.Duplicate, ServerRequestTable.Registration.AtCapacity -> return
            ServerRequestTable.Registration.Accepted -> Unit
        }
        val handler = handlers[method]
        if (handler == null) {
            queueServerResponse(owner, id, method, ServerResponse.Failure(-32601, "Method not supported by this client"))
            return
        }
        val token = Any()
        val job = scope.launch(Dispatchers.Default) {
            val response = try {
                handler.handle(IncomingServerRequest(owner.generation, id, method, params))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                ServerResponse.Failure(-32603, "Client could not handle the request")
            }
            withContext(serial + NonCancellable) { completeHandler(owner, id, method, token, response) }
        }
        owner.serverTasks[id] = ServerTask(token, job)
    }

    private fun completeHandler(owner: Link, id: String, method: String, token: Any, response: ServerResponse) {
        if (owner.serverTasks[id]?.token !== token) return
        owner.serverTasks.remove(id)
        if (owner.closed || owner !== link) return
        queueServerResponse(owner, id, method, response)
    }

    private fun queueServerResponse(owner: Link, id: String, method: String, response: ServerResponse) {
        var text = encodeResponse(id, response)
            ?: encodeResponse(id, ServerResponse.Failure(-32603, "Client could not encode the response"))
            ?: run { owner.serverRequests.retire(id, method); return }
        var bytes = utf8Length(text)
        if (owner.queuedServerBytes + bytes > MAXIMUM_QUEUED_SERVER_BYTES) {
            text = encodeResponse(id, ServerResponse.Failure(-32603, "Client response queue is full"))
                ?: run { owner.serverRequests.retire(id, method); return }
            bytes = utf8Length(text)
            if (owner.queuedServerBytes + bytes > MAXIMUM_QUEUED_SERVER_BYTES) {
                owner.serverRequests.retire(id, method)
                return
            }
        }
        if (!owner.serverRequests.stageResponse(id, method)) return
        owner.outbox.addLast(Outbound(id, method, text, bytes))
        owner.queuedServerBytes += bytes
        pump(owner)
    }

    /** The response envelope with the original ID bytes, or null if it cannot be encoded within limits. */
    private fun encodeResponse(id: String, response: ServerResponse): String? {
        if (!HermesWire.isValidRequestID(id)) return null
        val envelope = try {
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", id)
                when (response) {
                    is ServerResponse.Result -> put("result", response.value)
                    is ServerResponse.Failure -> {
                        if (response.message.isEmpty() || utf8Length(response.message) > HermesWire.MAXIMUM_CANCELLATION_REASON_BYTES) return null
                        put("error", buildJsonObject {
                            put("code", response.code)
                            put("message", response.message)
                            response.data?.let { put("data", it) }
                        })
                    }
                }
            }.toString()
        } catch (_: Exception) {
            return null
        }
        return envelope.takeIf { utf8Length(it) <= MAXIMUM_RESPONSE_BYTES && !exceedsNesting(it) }
    }

    private fun retireServerRequest(owner: Link, cancellation: RequestCancellation) {
        if (!owner.serverRequests.retire(cancellation.id, cancellation.method)) return
        owner.serverTasks.remove(cancellation.id)?.job?.cancel()
        val index = owner.outbox.indexOfFirst { it.id == cancellation.id && it.serverMethod == cancellation.method }
        if (index >= 0) {
            uncount(owner, owner.outbox.removeAt(index))
        }
    }

    /**
     * Adopts the final `session.events.since.open_requests` snapshot through the same handler path as live
     * requests. The whole snapshot (at most 64 rows of exactly `id`, `method` and `params`, each with
     * `params.session_id == runtimeId`) is validated before anything is adopted. [generation] must be the
     * current socket generation.
     */
    suspend fun adoptOpenRequests(rows: JsonElement, runtimeId: String, generation: Long) {
        withContext(serial) {
            val live = link
            if (live == null || live.closed || live.generation != generation || live.socket.phase != SocketPhase.Ready) throw notConnected()
            val invalid = HermesException(HermesException.Kind.InvalidResponse)
            if (runtimeId.isEmpty() || utf8Length(runtimeId) > 4_096) throw invalid
            val array = rows as? JsonArray ?: throw invalid
            if (array.size > ServerRequestTable.MAXIMUM_OPEN) throw invalid
            val requests = array.map { row ->
                val entry = row as? JsonObject ?: throw invalid
                if (entry.keys != setOf("id", "method", "params")) throw invalid
                val id = (entry["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf(HermesWire::isValidRequestID) ?: throw invalid
                val method = (entry["method"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf(HermesWire::isValidMethod) ?: throw invalid
                val params = entry["params"] as? JsonObject ?: throw invalid
                if ((params["session_id"] as? JsonPrimitive)?.takeIf { it.isString }?.content != runtimeId) throw invalid
                Triple(id, method, params)
            }
            for ((id, method, params) in requests) acceptServerRequest(live, id, method, params)
        }
    }

    // Closing

    /**
     * Ends this client for good: closes the socket, fails what is pending, forgets the handlers, and gives a
     * renewal already on its way a moment to save. A new client (or [connect] on a fresh instance) is needed
     * afterwards. Credentials in the store are untouched.
     */
    suspend fun disconnect() {
        withContext(serial) {
            terminal = true
            recovery?.cancel()
            recovery = null
            opening?.cancel()
            link?.let { closeLink(it, HermesException(HermesException.Kind.Disconnected), notify = false, orderly = true) }
            handlers.clear()
            publish()
            subscribers.forEach { it.close() }
            subscribers.clear()
        }
        authenticator.settlePendingRenewal()
    }

    private fun closeLink(owner: Link, reason: HermesException, notify: Boolean, orderly: Boolean = false) {
        if (owner.closed) return
        owner.closed = true
        val uncertain = owner.pending.values.any { it.sendStarted && !it.readOnly }
        val recover = notify && owner.connected && !terminal && !uncertain
        if (link === owner) link = null
        owner.readyDeadline?.cancel()
        owner.heartbeat?.cancel()
        owner.transport?.let { transport ->
            if (orderly) {
                transport.close(orderly = true)
                // Not on `scope`: the owner cancels it right after disconnect(), which would drop this fallback.
                fallbackClose.launch { delay(1_000); transport.close(orderly = false) }
            } else {
                transport.close(orderly = false)
            }
        }
        owner.inbound.close()
        owner.reader?.cancel()
        owner.readyGate.completeExceptionally(reason)
        val failing = owner.pending.values.toList()
        owner.pending.clear()
        for (pending in failing) {
            pending.timeout?.cancel()
            pending.result.completeExceptionally(
                if (pending.sendStarted && !pending.readOnly) HermesException(HermesException.Kind.Disconnected, outcomeUnknown = true) else reason,
            )
        }
        owner.serverTasks.values.forEach { it.job.cancel() }
        owner.serverTasks.clear()
        owner.serverRequests.removeAll()
        owner.outbox.clear()
        owner.queuedBytes = 0
        owner.queuedAttachmentBytes = 0
        owner.queuedServerBytes = 0
        owner.attachmentId = null
        lastFailure = reason
        if (recover) {
            startRecovery(reason)
        } else if (owner.connected && recovery == null) {
            // A connection that ended without automatic recovery: the next owner registers handlers again.
            handlers.clear()
        }
        publish()
    }

    private fun startRecovery(initial: HermesException) {
        if (recovery != null) return
        recovery = scope.launch(serial) {
            var last = initial
            for (delayMillis in timings.reconnectDelaysMillis) {
                if (delayMillis > 0) delay(delayMillis)
                if (terminal) return@launch
                try {
                    open(verify = true)
                    // Published state still says Recovering while this loop runs, so read the link itself.
                    if (link?.connected == true) {
                        recovery = null
                        publish()
                        return@launch
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    last = asHermes(e)
                }
            }
            if (terminal) return@launch
            recovery = null
            handlers.clear()
            lastFailure = last
            publish()
        }
        publish()
    }

    private fun publish() {
        val live = link
        val connection = when {
            terminal -> GatewayConnection.Closed
            recovery != null -> GatewayConnection.Recovering
            live == null -> GatewayConnection.Idle
            live.connected -> GatewayConnection.Connected
            else -> GatewayConnection.Connecting
        }
        val ready = live?.socket?.ready
        val replayEpoch = (ready?.payload?.get("replay_epoch") as? JsonPrimitive)?.takeIf { it.isString }?.content
        val heartbeat = (ready?.payload?.get("heartbeat") as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content == "true"
        mutableState.value = GatewayState(connection, generation, live?.owner, live?.socket, replayEpoch, heartbeat, lastFailure)
    }

    private fun notConnected() = HermesException(HermesException.Kind.NotConnected)

    private fun asHermes(error: Throwable): HermesException = when (error) {
        is HermesException -> error
        is WireException -> HermesException(HermesException.Kind.InvalidResponse)
        else -> HermesException(HermesException.Kind.ConnectionFailed)
    }

    /** Counts `{`/`[` depth outside strings, like the inbound check, so hostile nesting is never sent. */
    private fun exceedsNesting(text: String): Boolean {
        var depth = 0
        var quoted = false
        var escaped = false
        for (c in text) {
            if (quoted) {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false
            } else if (c == '"') {
                quoted = true
            } else if (c == '{' || c == '[') {
                if (++depth > HermesWire.MAXIMUM_NESTING) return true
            } else if (c == '}' || c == ']') {
                depth--
            }
        }
        return false
    }

    companion object {
        const val DEFAULT_FRAME_BYTES = 2 * 1_024 * 1_024
        const val ATTACHMENT_FRAME_BYTES = 12 * 1_024 * 1_024
        const val MAXIMUM_PENDING = 64
        const val MAXIMUM_QUEUED_BYTES = 8 * 1_024 * 1_024
        const val MAXIMUM_RESPONSE_BYTES = 2 * 1_024 * 1_024
        const val MAXIMUM_QUEUED_SERVER_BYTES = 4 * 1_024 * 1_024
        const val EVENT_BUFFER = 8_192
        private const val DRAIN_POLL_MILLIS = 2L
        private const val DRAIN_POLL_MAX_MILLIS = 50L
        // Few, because one message can be 4 MiB; a full buffer blocks the socket reader, which is TCP backpressure.
        private const val INBOUND_BUFFER = 8
        private val SUBMISSION_METHODS = setOf("prompt.submit", "slash.exec", "command.dispatch")
    }
}
