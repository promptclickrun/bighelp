package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.GatewayEvent
import app.bighelp.hermes.GatewayState
import app.bighelp.hermes.HermesAuthenticator
import app.bighelp.hermes.HermesHttpLimits
import app.bighelp.hermes.HermesHttpRequest
import app.bighelp.hermes.ServerRequestHandler
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * What the chat layer needs from the gateway. [GatewayClient] satisfies it through [GatewayClientAdapter]; a
 * test substitutes a scripted host that behaves like Hermes (a `prompt.submit` answers `streaming` and the
 * reply arrives later as events). The repository never touches a socket directly.
 */
internal interface ChatGateway {
    val state: StateFlow<GatewayState>
    val events: Flow<GatewayEvent>

    /**
     * One JSON-RPC call; failures are `HermesException`, a cancelled caller gets `RequestCancelledException`.
     * [generation] is the socket generation a runtime-addressed call was planned on: on any other socket the call
     * fails `NotConnected` and nothing is written.
     */
    suspend fun request(method: String, params: JsonObject, timeoutMillis: Long? = null, generation: Long? = null): JsonElement

    suspend fun prepareForAdmission()
    suspend fun verifyLiveness()
    suspend fun reconnect(): GatewayState
    suspend fun adoptOpenRequests(rows: JsonElement, runtimeId: String, generation: Long)
    fun setServerRequestHandler(method: String, handler: ServerRequestHandler?)
}

internal class GatewayClientAdapter(private val client: GatewayClient) : ChatGateway {
    override val state get() = client.state
    override val events get() = client.events

    override suspend fun request(method: String, params: JsonObject, timeoutMillis: Long?, generation: Long?): JsonElement =
        if (timeoutMillis == null) client.request(method, params, generation = generation)
        else client.request(method, params, timeoutMillis, generation = generation)

    override suspend fun prepareForAdmission() = client.prepareForAdmission()
    override suspend fun verifyLiveness() = client.verifyLiveness()
    override suspend fun reconnect(): GatewayState = client.reconnect()
    override suspend fun adoptOpenRequests(rows: JsonElement, runtimeId: String, generation: Long) =
        client.adoptOpenRequests(rows, runtimeId, generation)

    override fun setServerRequestHandler(method: String, handler: ServerRequestHandler?) =
        client.setServerRequestHandler(method, handler)
}

/** The authenticated REST reads of the session catalog and history. Read-only: nothing here mutates the host. */
internal interface ChatRest {
    suspend fun get(route: String, query: List<Pair<String, String>>): JsonElement
}

internal class AuthenticatedRest(private val authenticator: HermesAuthenticator) : ChatRest {
    override suspend fun get(route: String, query: List<Pair<String, String>>): JsonElement = authenticator.authenticatedJson(
        HermesHttpRequest(
            route = route, query = query,
            maximumResponseBytes = HermesHttpLimits.responseCeiling(route, "GET", query),
        ),
    )
}
