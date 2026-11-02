package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Rule
import org.junit.rules.Timeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows

/** Shared fixture: a scripted gateway, a dashboard or bearer authenticator on it, and fast timings. */
abstract class GatewayTestSupport {
    protected val gateway = ScriptedGateway("/hermes")
    protected val store = InMemoryCredentialStore()
    protected val now = System.currentTimeMillis() / 1_000
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val resources = mutableListOf<AutoCloseable>()

    protected val fast = GatewayTimings(
        readyMillis = 2_000, advertiseMillis = 1_000, requestMillis = 3_000, heartbeatMillis = 60_000, pingMillis = 60_000,
        pingReplyMillis = 500, livenessMillis = 500, admissionMillis = 500, reconnectDelaysMillis = listOf(0, 50, 50),
    )

    init {
        gateway.host.on("GET", "/api/status") { ScriptedHost.json(if (bearerMode) """{"auth_required":true}""" else """{"auth_required":false}""") }
        gateway.host.on("GET", "/api/auth/me") { ScriptedHost.json("""{"provider":"basic","user_id":"synthetic-user"}""") }
    }

    @Volatile protected var bearerMode = false

    /** A hung gateway test must fail, not stall the suite: it also turns a regression that hangs into a failure. */
    @get:Rule val testTimeout: Timeout = Timeout.seconds(45)

    @After fun stopGateway() {
        scope.cancel()
        resources.forEach { runCatching { it.close() } }
        gateway.close()
    }

    protected fun authenticator(bearer: Boolean = false, access: AccessHeaders = AccessHeaders.none): HermesAuthenticator {
        bearerMode = bearer
        val http = OkHttpHermesHttp(gateway.host.endpoint, access)
        val ownStore = InMemoryCredentialStore()
        val authenticator = HermesAuthenticator(gateway.host.endpoint, http, ownStore)
        resources += authenticator
        val saved = if (bearer) {
            SavedConnection(gateway.host.endpoint, StoredAuth.Bearer("access-1", "refresh-1", now + 3_600), "basic", "synthetic-user")
        } else {
            SavedConnection(gateway.host.endpoint, StoredAuth.DashboardSession("dash-token", automatic = false), null, null)
        }
        runBlocking { ownStore.replace(null, saved) }
        authenticator.adoptForTest(saved, persisted = true)
        return authenticator
    }

    protected fun client(bearer: Boolean = false, timings: GatewayTimings = fast, access: AccessHeaders = AccessHeaders.none): GatewayClient =
        GatewayClient(authenticator(bearer, access), scope, timings)

    /** Collects every event the client publishes, from before the first connect. */
    protected inner class EventLog(client: GatewayClient) {
        val events = CopyOnWriteArrayList<GatewayEvent>()

        init {
            scope.launch { client.events.collect { events += it } }
            runBlocking { eventually { client.subscriberCount == 1 } }
        }

        fun types() = events.map { it.event.type }
    }

    protected suspend fun eventually(timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        withTimeout(timeoutMillis) { while (!condition()) delay(10) }
    }

    protected fun kind(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind

    protected fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    protected fun params(vararg pairs: Pair<String, String>) = buildJsonObject { pairs.forEach { put(it.first, it.second) } }

    protected fun assertKind(expected: HermesException.Kind, block: suspend () -> Unit) = assertEquals(expected, kind(block))

    protected fun ok(body: String = "{}") = ScriptedHost.json(body)
    protected fun refuse(code: Int) = MockResponse().setResponseCode(code)
}
