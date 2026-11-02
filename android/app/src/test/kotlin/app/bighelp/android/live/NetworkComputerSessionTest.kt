package app.bighelp.android.live

import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.InMemoryCredentialStore
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.chat.MemoryChatStore
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The real authenticator, gateway and chat repository of one computer, against a scripted loopback host. */
class NetworkComputerSessionTest {
    private val server = MockWebServer()
    private val requests = java.util.Collections.synchronizedList(mutableListOf<String>())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Before fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request.path.orEmpty().substringBefore('?')
                return if (request.path == "/api/status") {
                    MockResponse().setHeader("Content-Type", "application/json").setBody("{\"auth_required\":false,\"auth_flows\":[]}")
                } else MockResponse().setResponseCode(404)
            }
        }
        server.start()
    }

    @After fun stop() { scope.cancel(); server.shutdown() }

    private fun session() = NetworkComputerSession(
        UUID.randomUUID(), HermesEndpoint.parse("http://127.0.0.1:${server.port}", allowPrivateHttp = true), AccessSetup.None,
        InMemoryCredentialStore(), scope, null, MemoryChatStore(),
    )

    @Test fun theChatRepositoryExistsFromTheSignInSoItsHandlersAreReadyBeforeAnySocketOpens() = runBlocking {
        val session = session()
        assertNull("No sign-in yet, so no principal to scope chat records by", session.chatOrNull)
        assertEquals(ComputerLink.Connecting, session.link.value)

        session.signIn(SignInInput.Token("synthetic-session-token-000111"))

        assertNotNull(session.chatOrNull)
        assertEquals(GatewayConnection.Idle, session.chat.connection.value.gateway)
        assertFalse("No socket was attempted by sign-in", requests.any { it == "/api/ws" })
        session.close()
    }

    @Test fun aFailedConnectIsTypedAndTheLinkSaysOfflineNotConnecting() = runBlocking {
        val session = session()
        session.signIn(SignInInput.Token("synthetic-session-token-000111"))
        val failure = runCatching { session.connect() }.exceptionOrNull()
        assertTrue("connect() failed with a typed error: $failure", failure is HermesException)
        withTimeout(10_000) { session.link.first { it == ComputerLink.Offline || it == ComputerLink.SignInRequired } }
        session.close()
    }

    @Test fun signingInAgainAsTheSamePrincipalKeepsOneRepository() = runBlocking {
        val session = session()
        session.signIn(SignInInput.Token("synthetic-session-token-000111"))
        val first = session.chat
        session.signIn(SignInInput.Token("synthetic-session-token-000111"))
        assertTrue(first === session.chat)
        session.close()
    }

    @Test fun comingBackToTheFrontReconnectsADroppedGatewayAndAHostProblemIsNotThrownAtTheScreen() = runBlocking {
        val session = session()
        session.signIn(SignInInput.Token("synthetic-session-token-000111"))
        runCatching { session.connect() }
        withTimeout(10_000) { session.link.first { it == ComputerLink.Offline || it == ComputerLink.SignInRequired } }
        requests.clear()

        session.resume()

        assertTrue("resume() asked the host again: $requests", requests.contains("/api/status") && requests.contains("/api/ws"))
        session.close()
    }

    @Test fun theExplicitReconnectReachesTheHostAndFailsWithATypedError() = runBlocking {
        val session = session()
        session.signIn(SignInInput.Token("synthetic-session-token-000111"))
        runCatching { session.connect() }
        withTimeout(10_000) { session.link.first { it == ComputerLink.Offline || it == ComputerLink.SignInRequired } }
        requests.clear()

        val failure = runCatching { session.reconnect() }.exceptionOrNull()

        assertTrue("A typed chat error, not a raw one: $failure", failure is app.bighelp.hermes.chat.ChatException)
        assertTrue(requests.contains("/api/ws"))
        session.close()
    }
}
