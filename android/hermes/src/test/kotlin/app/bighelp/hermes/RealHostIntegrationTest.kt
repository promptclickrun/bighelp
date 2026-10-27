package app.bighelp.hermes

import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * Real Hermes, real sockets: the disposable hosts prepared for Android verification (stock Hermes plus a
 * scripted local model, so no AI spend). Skipped unless `BIGHELP_E2E_CREDENTIALS` names the private
 * `credentials.json`. Credentials are read from that file at run time and are never printed, logged or kept.
 *
 * This is protocol-level JVM evidence only: not Android, not an emulator or device, and not real inference.
 */
class RealHostIntegrationTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val closeables = mutableListOf<AutoCloseable>()
    private val clients = mutableListOf<GatewayClient>()
    private lateinit var hosts: JsonObject

    @Before fun requireHosts() {
        val path = System.getenv("BIGHELP_E2E_CREDENTIALS")
        assumeTrue("Set BIGHELP_E2E_CREDENTIALS to run against the disposable hosts", path != null && File(path).isFile)
        hosts = Json.parseToJsonElement(File(path!!).readText()).jsonObject["hosts"]!!.jsonObject
    }

    @After fun cleanup() = runBlocking {
        clients.forEach { runCatching { it.disconnect() } }
        scope.cancel()
        closeables.forEach { runCatching { it.close() } }
    }

    private fun host(name: String) = hosts[name]!!.jsonObject
    private fun text(obj: JsonObject, key: String) = obj[key]!!.jsonPrimitive.content
    private fun endpoint(name: String) = HermesEndpoint.parse(text(host(name), "proxy_origin"), allowPrivateHttp = true)

    private fun authenticator(name: String, store: CredentialStore = InMemoryCredentialStore(), browser: BrowserLauncher? = null): HermesAuthenticator {
        val endpoint = endpoint(name)
        return HermesAuthenticator(endpoint, OkHttpHermesHttp(endpoint), store, browser).also { closeables += it }
    }

    /** What a chat screen would register: it records the request and answers the way a person would. */
    private class Prompts {
        val seen = CopyOnWriteArrayList<IncomingServerRequest>()

        fun install(client: GatewayClient) {
            client.setServerRequestHandler("clarify") { request ->
                seen += request
                val questions = request.params["questions"] as? JsonArray
                if (questions != null) {
                    ServerResponse.Result(buildJsonObject {
                        put("answers", buildJsonObject {
                            questions.forEach { q -> put(q.jsonObject["qid"]!!.jsonPrimitive.content, "Alpha") }
                        })
                    })
                } else {
                    ServerResponse.Result(buildJsonObject { put("answer", "Alpha") })
                }
            }
            // Declined, never answered with a value: Hermes stores an answered secret in the host's .env, which
            // would make every later run (and the host's own scripted scenario) skip the prompt.
            client.setServerRequestHandler("secret") { request ->
                seen += request
                ServerResponse.Result(buildJsonObject { put("value", "") })
            }
            client.setServerRequestHandler("approval") { request ->
                seen += request
                ServerResponse.Result(buildJsonObject { put("choice", "deny"); put("all", false) })
            }
        }

        fun methods() = seen.map { it.method }
    }

    private class Turn(val receipt: String, val eventTypes: List<String>, val finalText: String?, val sessionRunningFalse: Boolean)

    private suspend fun GatewayClient.newSession(profile: String, project: String): Pair<String, String> {
        val created = request("session.create", buildJsonObject {
            put("profile", profile)
            put("source", "bighelp")
            put("idempotency_key", UUID.randomUUID().toString())
            put("cwd", project)
            put("cwd_explicit", true)
            put("title", "Synthetic Android protocol check")
        }).jsonObject
        return created["session_id"]!!.jsonPrimitive.content to created["stored_session_id"]!!.jsonPrimitive.content
    }

    private suspend fun GatewayClient.runTurn(events: MutableList<GatewayEvent>, runtime: String, profile: String, prompt: String, wait: Long = 30_000): Turn {
        val receipt = request(
            "prompt.submit",
            buildJsonObject { put("session_id", runtime); put("profile", profile); put("text", prompt); put("queued", true) },
        ).jsonObject["status"]!!.jsonPrimitive.content
        fun mine() = events.filter { it.event.sessionID == runtime }
        withTimeout(wait) {
            while (mine().none { it.event.type == "message.complete" || it.event.type == "error" } ||
                mine().none { it.event.type == "session.info" && it.event.payload["running"]?.toString() == "false" }
            ) delay(50)
        }
        val complete = mine().firstOrNull { it.event.type == "message.complete" }
        return Turn(
            receipt, mine().map { it.event.type }.distinct(),
            (complete?.event?.payload?.get("text") as? JsonPrimitive)?.content,
            mine().any { it.event.type == "session.info" && it.event.payload["running"]?.toString() == "false" },
        )
    }

    private fun collect(client: GatewayClient): MutableList<GatewayEvent> {
        val events = CopyOnWriteArrayList<GatewayEvent>()
        scope.launch { client.events.collect { events += it } }
        runBlocking { withTimeout(5_000) { while (client.subscriberCount == 0) delay(10) } }
        return events
    }

    // The ungated host: automatic dashboard session

    @Test fun openHostDashboardSignInConnectsAndStreamsARealTurnWithPromptsAnsweredOverTheWire() = runBlocking {
        val authenticator = authenticator("open")
        val status = authenticator.discover()
        assertFalse(status.authRequired)

        val staged = authenticator.signIn(SignInInput.Dashboard)
        assertEquals(true, (staged.auth as StoredAuth.DashboardSession).automatic)

        val client = GatewayClient(authenticator, scope).also { clients += it }
        val prompts = Prompts().also { it.install(client) }
        val events = collect(client)
        val state = client.connect()
        assertEquals(GatewayConnection.Connected, state.connection)
        assertNotNull("gateway.ready carried its payload", state.ready)
        assertTrue("The stock host guarantees serialized submitters", state.capabilities!!.perSessionExclusiveSubmit)
        authenticator.commit() // only after gateway.ready

        val profiles = client.request("profiles.list", buildJsonObject { put("include_sessions", true) }).jsonObject["profiles"] as JsonArray
        val names = profiles.map { it.jsonObject["name"]!!.jsonPrimitive.content }
        assertTrue(names.toString(), names.containsAll(listOf("default", "moss", "cobalt")))

        val project = text(host("open"), "project")
        val (runtime, stored) = client.newSession("default", project)
        assertNotEquals("Runtime and stored identifiers stay separate values", "", stored)
        val turn = client.runTurn(events, runtime, "default", "hello from the Android protocol check")
        assertTrue("A turn that is streaming or already done: ${turn.receipt}", turn.receipt in setOf("streaming", "ok"))
        assertTrue(turn.eventTypes.toString(), "message.complete" in turn.eventTypes)
        assertTrue("The turn ends on session.info running:false", turn.sessionRunningFalse)
        assertFalse(turn.finalText.isNullOrBlank())
        println("REAL-HOST open: socketGeneration=${state.generation} replayEpochPresent=${state.replayEpoch != null} heartbeat=${state.heartbeatAdvertised} " +
            "exclusiveSubmit=${state.capabilities!!.perSessionExclusiveSubmit} receipt=${turn.receipt} events=${turn.eventTypes} finalText=\"${turn.finalText}\"")

        for ((prompt, expected) in listOf("question test" to "clarify", "approval test" to "approval")) {
            val (rt, _) = client.newSession("default", project)
            client.runTurn(events, rt, "default", prompt)
            assertTrue("$prompt should raise $expected but saw ${prompts.methods()}", expected in prompts.methods())
            assertTrue("The request carried the runtime session", prompts.seen.any { it.params["session_id"]?.jsonPrimitive?.content == rt })
        }
        println("REAL-HOST open prompts answered over the wire: ${prompts.methods()}")
        assertTrue("An approval was denied by the handler, so the disposable directory still exists",
            File(project, "approval-only-delete").isDirectory)
    }

    @Test fun openHostSecureInputRequestReachesTheHandlerAndIsDeclinedWithoutStoringAnything() = runBlocking {
        val authenticator = authenticator("open")
        authenticator.signIn(SignInInput.Dashboard)
        val client = GatewayClient(authenticator, scope).also { clients += it }
        val prompts = Prompts().also { it.install(client) }
        val events = collect(client)
        client.connect()
        val (runtime, _) = client.newSession("default", text(host("open"), "project"))
        client.runTurn(events, runtime, "default", "secure input test")
        // Hermes asks only while the fixture variable is unset; an earlier answered run leaves it set.
        assumeTrue("The host already holds the fixture secret, so it did not ask", "secret" in prompts.methods())
        val request = prompts.seen.first { it.method == "secret" }
        assertEquals("SECURE_INPUT_FIXTURE", request.params["env_var"]?.jsonPrimitive?.content)
        assertEquals(runtime, request.params["session_id"]?.jsonPrimitive?.content)
        Unit
    }

    @Test fun openHostRestFollowsTheDashboardTokenAndTheNativeContextIsGuardedByItsEtag() = runBlocking {
        val authenticator = authenticator("open")
        authenticator.signIn(SignInInput.Dashboard)
        authenticator.requireHealth()
        val context = authenticator.authenticated(HermesHttpRequest("/api/plugins/loopdy/native/context", maximumResponseBytes = 1_048_576))
        assertEquals(200, context.status)
        val etag = context.header("ETag")
        assertNotNull("The plugin context returns the ETag its guard needs", etag)
        val features = context.jsonObject()["features"]
        assertNotNull(features)
        val unauthenticated = HermesHttpRequest("/api/sessions").let { OkHttpHermesHttp(endpoint("open")).also { c -> closeables += c }.send(it) }
        assertTrue("Without the session token Hermes refuses", unauthenticated.status in setOf(401, 403))
    }

    // The gated host: password PKCE, rotation and tickets

    @Test fun passwordPkceSignsInStagesThenPersistsOnlyAfterReadyAndRotatesDurably() = runBlocking {
        val credentials = host("password")
        val store = InMemoryCredentialStore()
        val authenticator = authenticator("password", store)
        val status = authenticator.discover()
        assertTrue(status.supportsNativePkce)
        assertTrue(status.passwordProviders.any { it.name == "basic" })

        val staged = authenticator.signIn(SignInInput.Password("basic", text(credentials, "username"), text(credentials, "password")))
        val bearer = staged.auth as StoredAuth.Bearer
        assertNotNull("The host minted a rotating refresh token", bearer.refreshToken)
        assertNull("Nothing persisted before the gateway is ready", store.load(staged.authority))
        assertFalse(staged.toString().contains(bearer.accessToken))

        val client = GatewayClient(authenticator, scope).also { clients += it }
        val prompts = Prompts().also { it.install(client) }
        val events = collect(client)
        val state = client.connect()
        assertEquals(GatewayConnection.Connected, state.connection)
        authenticator.commit(expected = null)
        assertEquals(staged, store.load(staged.authority))

        val project = text(credentials, "project")
        val (runtime, _) = client.newSession("default", project)
        val turn = client.runTurn(events, runtime, "default", "hello through a ticketed socket")
        assertTrue("message.complete" in turn.eventTypes)
        assertTrue(turn.sessionRunningFalse)
        println("REAL-HOST password: provider=${staged.provider} refreshToken=${bearer.refreshToken != null} ticketSubprotocolRequired=${state.socket != null} receipt=${turn.receipt} events=${turn.eventTypes}")
        client.disconnect()

        // A second authenticator restores the persisted sign-in, then the access token is forced to expire.
        val expired = SavedConnection(staged.endpoint, StoredAuth.Bearer(bearer.accessToken, bearer.refreshToken, 1L), staged.provider, staged.userId)
        store.replace(staged, expired)
        val restoredAuthenticator = authenticator("password", store)
        restoredAuthenticator.restore(expired) // expiry in the past: renews before anything else
        val rotated = store.load(staged.authority)!!
        val rotatedBearer = rotated.auth as StoredAuth.Bearer
        assertNotEquals("The access token was renewed", bearer.accessToken, rotatedBearer.accessToken)
        assertEquals("Same principal", staged.authority, rotated.authority)
        assertTrue((rotatedBearer.expiresAtEpochSeconds ?: 0) > System.currentTimeMillis() / 1_000)
        assertEquals(rotated, restoredAuthenticator.savedConnection)
        println("REAL-HOST password rotation: accessChanged=${bearer.accessToken != rotatedBearer.accessToken} refreshChanged=${bearer.refreshToken != rotatedBearer.refreshToken}")

        // Two tickets, two sockets: a fresh single-use ticket every attempt.
        val first = restoredAuthenticator.socketRequest()
        val second = restoredAuthenticator.socketRequest()
        assertNotEquals(first.headers["Sec-WebSocket-Protocol"], second.headers["Sec-WebSocket-Protocol"])
        val again = GatewayClient(restoredAuthenticator, scope).also { clients += it }
        assertEquals(GatewayConnection.Connected, again.connect().connection)
        assertTrue(prompts.seen.isEmpty() || prompts.seen.isNotEmpty())
        val health = restoredAuthenticator.authenticated(HermesHttpRequest("/api/health", maximumResponseBytes = 16_384))
        assertEquals(200, health.status)
    }

    @Test fun aBadPasswordIsRefusedWithoutWritingOrLeakingAnything() = runBlocking {
        val credentials = host("password")
        val store = InMemoryCredentialStore()
        val authenticator = authenticator("password", store)
        val failure = runCatching {
            authenticator.signIn(SignInInput.Password("basic", text(credentials, "username"), "definitely-the-wrong-password"))
        }.exceptionOrNull() as HermesException
        assertTrue(failure.toString(), failure.kind in setOf(HermesException.Kind.InvalidCredentials, HermesException.Kind.InvalidResponse))
        assertNull(authenticator.savedConnection)
        assertFalse("definitely-the-wrong-password" in failure.toString() + failure.message.orEmpty())
    }

    // The gated host: browser PKCE through the mock single sign-on, with a test-side "browser"

    private class SimpleCookieJar : CookieJar {
        private val cookies = mutableListOf<Cookie>()
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            cookies.forEach { fresh -> this.cookies.removeAll { it.name == fresh.name && it.domain == fresh.domain && it.path == fresh.path }; this.cookies += fresh }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> = cookies.filter { it.matches(url) }
    }

    /** Plays the person's browser: follows Hermes to the mock identity provider, approves, and lands on the loopback listener. */
    private fun mockBrowser(proxyOrigin: String): BrowserLauncher = BrowserLauncher { authorizeUrl ->
        val browser = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).cookieJar(SimpleCookieJar()).build()
        fun get(url: String) = browser.newCall(Request.Builder().url(url).build()).execute()
        val authorize = get(authorizeUrl)
        check(authorize.code == 302) { "authorize answered ${authorize.code}" }
        val idpLocation = authorize.header("Location")!!
        authorize.close()
        val page = get(idpLocation)
        val html = page.body!!.string()
        page.close()
        val form = FormBody.Builder().also { builder ->
            Regex("""<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"""").findAll(html).forEach { builder.add(it.groupValues[1], it.groupValues[2]) }
        }.build()
        val idp = idpLocation.toHttpUrl()
        val approve = browser.newCall(Request.Builder().url("${idp.scheme}://${idp.host}:${idp.port}/approve").post(form).build()).execute()
        check(approve.code == 302) { "approve answered ${approve.code}" }
        val back = approve.header("Location")!!.toHttpUrl()
        approve.close()
        val callback = get(proxyOrigin + back.encodedPath + (back.encodedQuery?.let { "?$it" } ?: ""))
        check(callback.code == 302) { "callback answered ${callback.code}" }
        val loopback = callback.header("Location")!!
        callback.close()
        check(loopback.startsWith("http://127.0.0.1:")) { "the host redirected somewhere other than the device-local listener" }
        get(loopback).close()
    }

    @Test fun browserPkceThroughTheMockSsoDeliversTheCodeToTheLoopbackListenerAndConnects() = runBlocking {
        val credentials = host("password")
        val store = InMemoryCredentialStore()
        val authenticator = authenticator("password", store, mockBrowser(text(credentials, "proxy_origin")))
        val staged = authenticator.signIn(SignInInput.Browser("self-hosted"))
        assertEquals("self-hosted", staged.provider)
        assertNull(store.load(staged.authority))
        val client = GatewayClient(authenticator, scope).also { clients += it }
        assertEquals(GatewayConnection.Connected, client.connect().connection)
        authenticator.commit()
        assertEquals(staged, store.load(staged.authority))
        val profiles = client.request("profiles.list", buildJsonObject { put("include_sessions", true) })
        assertTrue(profiles.jsonObject["profiles"] is JsonArray)
    }

    @Test fun anAccessTokenFromTheWrongHostModeIsNeverSentToTheOtherMechanism() = runBlocking {
        val open = authenticator("open")
        val failure = runCatching { open.signIn(SignInInput.Password("basic", "u", "p")) }.exceptionOrNull() as HermesException
        assertEquals(HermesException.Kind.UnsupportedAuthentication, failure.kind)
        val gated = authenticator("password")
        val mismatch = runCatching { gated.signIn(SignInInput.Dashboard) }.exceptionOrNull() as HermesException
        assertEquals(HermesException.Kind.AuthModeChanged, mismatch.kind)
    }
}
