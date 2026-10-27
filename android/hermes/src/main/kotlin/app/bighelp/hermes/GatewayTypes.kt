package app.bighelp.hermes

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Deadlines and paces of the gateway, injectable so tests need not wait. Defaults are the contract's. */
class GatewayTimings(
    /** From creating the socket to `gateway.ready`. HTTP 101 alone is not ready. */
    val readyMillis: Long = 20_000,
    /** `client.capabilities` reply deadline. */
    val advertiseMillis: Long = 15_000,
    /** An ordinary RPC, from enqueue (not from the host starting it). */
    val requestMillis: Long = 45_000,
    /** Periodic ping when `gateway.ready` said `heartbeat: true`. */
    val heartbeatMillis: Long = 15_000,
    /** Periodic ping otherwise. */
    val pingMillis: Long = 20_000,
    val pingReplyMillis: Long = 15_000,
    /** A quick check after foreground or a network change. */
    val livenessMillis: Long = 4_000,
    /** The proof just before a prompt admission. */
    val admissionMillis: Long = 5_000,
    /** Automatic same-owner recovery attempts: the delay before each. */
    val reconnectDelaysMillis: List<Long> = listOf(0, 1_000, 3_000),
)

/** One event with the socket generation it arrived on, so a consumer can drop a stale one. */
class GatewayEvent(val generation: Long, val event: WireMessage.Event) {
    override fun toString() = "GatewayEvent($generation, ${event.type})"
}

enum class GatewayConnection {
    /** Never connected, or the last connection ended and recovery is not running. */
    Idle,
    Connecting,

    /** Ready, advertised, healthy and with capabilities known. */
    Connected,

    /** The socket was lost and the automatic same-owner recovery is under way. */
    Recovering,

    /** [GatewayClient.disconnect] ran. This client object is finished. */
    Closed,
}

/** What a consumer needs to know about the connection right now. */
class GatewayState(
    val connection: GatewayConnection,
    /** The current (or last) socket generation; changes with every new socket, even to the same owner. */
    val generation: Long,
    val owner: ConnectionOwner?,
    /** Phase, capabilities and the retained first `gateway.ready` of the current socket. */
    val socket: GatewaySocket?,
    /** `payload.replay_epoch` of the retained ready, when the host sent one. */
    val replayEpoch: String?,
    val heartbeatAdvertised: Boolean,
    /** Why the previous socket ended, if it did. */
    val lastFailure: HermesException?,
) {
    val ready: WireMessage.Event? get() = socket?.ready
    val capabilities: GatewayCapabilities? get() = socket?.capabilities
    val isConnected: Boolean get() = connection == GatewayConnection.Connected

    override fun toString() = "GatewayState($connection, generation=$generation)"
}

/** A request the host sent to this client. [generation] is the socket it arrived on. */
class IncomingServerRequest(val generation: Long, val id: String, val method: String, val params: JsonObject) {
    override fun toString() = "IncomingServerRequest($method)"
}

/** The answer to a server request. The transport never makes a decision itself; only a handler does. */
sealed interface ServerResponse {
    class Result(val value: JsonElement) : ServerResponse

    /** A JSON-RPC error; [message] is nonempty and at most 4,096 bytes. */
    class Failure(val code: Long, val message: String, val data: JsonElement? = null) : ServerResponse
}

/**
 * Answers one kind of server request (`approval`, `clarify`, `secret`, `sudo`). It runs in its own
 * coroutine and may suspend for as long as a person takes. It is cancelled when the host sends a matching
 * `request.cancel` or the socket generation ends, and then nothing is sent. Registering handlers is what
 * makes the client advertise `server_requests`, after `gateway.ready`, on every socket.
 */
fun interface ServerRequestHandler {
    suspend fun handle(request: IncomingServerRequest): ServerResponse
}

/**
 * Thrown to a coroutine that was cancelled while its RPC was pending. It is a [CancellationException], so
 * structured concurrency is unaffected, but it says how far the request got: [dispatch] is
 * [DispatchOutcome.MayHaveBeenSent] once the frame was handed to the socket. Cancelling never stops the
 * host and is not an interrupt; the request is never resent.
 */
class RequestCancelledException(val dispatch: DispatchOutcome) : CancellationException("Request cancelled")
