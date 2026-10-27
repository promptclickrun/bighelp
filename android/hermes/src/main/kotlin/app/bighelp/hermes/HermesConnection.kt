package app.bighelp.hermes

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

// Pure, immutable policy for who owns a connection and what it may do. It performs no I/O: a transport
// feeds it facts (upgraded, a decoded message, a capability result) and asks before acting. It is not a
// client; nothing here opens a socket, sends a frame or reconnects.

/**
 * Who a socket, request or result belongs to. [generation] changes on every new connection, even to the
 * same endpoint and principal, so an older answer can never be mistaken for the current one.
 */
data class ConnectionOwner(val endpoint: String, val principal: String, val generation: Long)

/**
 * The one current owner, or none while disconnected. Hold it in a single atomic holder and check
 * [accepts] on the same context that applies the result: a retired owner can never publish.
 */
class OwnerState private constructor(val current: ConnectionOwner?, private val lastGeneration: Long) {
    /** Supersedes any current owner. Generations only grow, also across [disconnect]. */
    fun connect(endpoint: HermesEndpoint, principal: String): OwnerState {
        val owner = ConnectionOwner(endpoint.canonical, principal, lastGeneration + 1)
        return OwnerState(owner, owner.generation)
    }

    fun disconnect(): OwnerState = OwnerState(null, lastGeneration)

    /** True only for the exact current owner: same endpoint, same principal, same generation. */
    fun accepts(owner: ConnectionOwner): Boolean = owner == current

    companion object {
        val none = OwnerState(null, 0)
    }
}

/** Host-advertised `gateway.capabilities`. Unknown keys are ignored; the one Boolean is required. */
data class GatewayCapabilities(val perSessionExclusiveSubmit: Boolean) {
    companion object {
        /**
         * @throws WireException unless [result] is an object whose `per_session_exclusive_submit` is a JSON
         * Boolean. Missing, `"true"` or any other shape fails discovery; never infer it from a version.
         */
        fun decode(result: JsonElement): GatewayCapabilities {
            val flag = (result as? JsonObject)?.get("per_session_exclusive_submit") as? JsonPrimitive
            val value = flag?.takeIf { !it.isString }?.booleanOrNull
                ?: throw WireException(WireException.Kind.InvalidResponse)
            return GatewayCapabilities(value)
        }
    }
}

enum class SocketPhase {
    /** The upgrade request is under way. */
    Connecting,

    /** The WebSocket opened (HTTP 101) but Hermes has not said `gateway.ready`. Not usable. */
    Upgraded,

    /** `gateway.ready` arrived. Only now may the application write. */
    Ready,

    Closed,
}

/** What a request needs from the connection. */
enum class GatewayOperation {
    /** Reads such as listing sessions. */
    Read,

    /** Prompt answers, stop, steer and other session controls that do not submit a new turn. */
    Control,

    /** Starting a turn: chat send, queue and slash commands. Needs the exclusive-submit guarantee. */
    Submission,
}

enum class Refusal {
    /** The owner was superseded or disconnected. */
    StaleOwner,

    /** The socket is not past `gateway.ready`; an upgrade alone allows no application writes. */
    NotReady,

    /** Capabilities have not been discovered on this socket yet. */
    CapabilitiesUnknown,

    /** The host did not guarantee serialized submitters, so starting a turn stays off. */
    ExclusiveSubmitUnavailable,
}

sealed interface Admission {
    data object Admitted : Admission
    data class Refused(val reason: Refusal) : Admission
}

/**
 * One socket generation's readiness and capabilities. Readiness is a separate fact from the upgrade and
 * from capability discovery; every transition returns a new value.
 */
class GatewaySocket private constructor(
    val owner: ConnectionOwner,
    val phase: SocketPhase,
    /** Null until discovered on this ready socket. Capabilities belong to one socket and are never carried over. */
    val capabilities: GatewayCapabilities?,
    /** The retained initial `gateway.ready`, so a late consumer still sees its epoch and heartbeat hint. */
    val ready: WireMessage.Event?,
) {
    fun upgraded(): GatewaySocket =
        if (phase == SocketPhase.Connecting) GatewaySocket(owner, SocketPhase.Upgraded, null, null) else this

    /**
     * Feeds one decoded message. The first `gateway.ready` on an upgraded socket makes it ready; a second
     * one on an already ready socket is invalid and closes it. Everything else changes nothing.
     */
    fun receive(message: WireMessage): GatewaySocket {
        if (message !is WireMessage.Event || message.type != GATEWAY_READY) return this
        return when (phase) {
            SocketPhase.Upgraded -> GatewaySocket(owner, SocketPhase.Ready, null, message)
            SocketPhase.Ready -> closed()
            else -> this
        }
    }

    /** @throws IllegalStateException unless the socket is ready: capabilities are asked after `gateway.ready`. */
    fun discovered(capabilities: GatewayCapabilities): GatewaySocket {
        check(phase == SocketPhase.Ready) { "Capabilities are only discovered on a ready socket." }
        return GatewaySocket(owner, phase, capabilities, ready)
    }

    fun closed(): GatewaySocket = GatewaySocket(owner, SocketPhase.Closed, null, ready)

    /** Server requests may arrive early, but their responses and every client frame wait for this. */
    val canWriteApplicationFrames: Boolean get() = phase == SocketPhase.Ready

    fun admit(operation: GatewayOperation, owners: OwnerState): Admission {
        if (!owners.accepts(owner)) return Admission.Refused(Refusal.StaleOwner)
        if (!canWriteApplicationFrames) return Admission.Refused(Refusal.NotReady)
        if (operation == GatewayOperation.Submission) {
            val known = capabilities ?: return Admission.Refused(Refusal.CapabilitiesUnknown)
            if (!known.perSessionExclusiveSubmit) return Admission.Refused(Refusal.ExclusiveSubmitUnavailable)
        }
        return Admission.Admitted
    }

    companion object {
        const val GATEWAY_READY = "gateway.ready"

        fun opening(owner: ConnectionOwner) = GatewaySocket(owner, SocketPhase.Connecting, null, null)
    }
}

/** How far one outgoing RPC got. Mark [MayHaveBeenSent] before awaiting the socket send, not after. */
enum class DispatchOutcome {
    /** Nothing left the device. */
    NotSent,

    /** Bytes may have reached the host. A failed send call does not prove otherwise. */
    MayHaveBeenSent,

    ConfirmedResult,
    ConfirmedRefusal,
}

object DispatchPolicy {
    /** The current client's conservative read-only allowlist. Anything else counts as a mutation. */
    val readOnlyMethods: Set<String> = setOf(
        "gateway.ping", "session.list", "session.active_list", "session.history",
        "session.status", "session.usage", "session.events.since", "commands.catalog",
        "config.get", "delegation.status", "spawn_tree.list",
        "profiles.list", "profiles.describe", "profiles.get_asset", "model.options",
        "projects.list", "projects.get", "subagent.list", "subagent.tail", "client.capabilities",
        "groups.capabilities", "groups.list", "groups.state", "groups.log", "pet.gallery", "pet.thumb",
    )

    fun isReadOnly(method: String): Boolean = method in readOnlyMethods

    /** A mutation that may have been sent has an unknown outcome: show it as uncertain, never as failed. */
    fun isUncertain(method: String, outcome: DispatchOutcome): Boolean =
        outcome == DispatchOutcome.MayHaveBeenSent && !isReadOnly(method)

    /**
     * Whether the owning layer may issue a fresh request after a lost connection. This is never a license
     * to copy the old frame to a new socket, and a mutation with an uncertain outcome is never retried by
     * the transport: an operation-specific recovery contract has to reconcile host state first.
     */
    fun mayRetry(method: String, outcome: DispatchOutcome): Boolean = when (outcome) {
        DispatchOutcome.NotSent -> true
        DispatchOutcome.MayHaveBeenSent -> isReadOnly(method)
        DispatchOutcome.ConfirmedResult, DispatchOutcome.ConfirmedRefusal -> false
    }
}
