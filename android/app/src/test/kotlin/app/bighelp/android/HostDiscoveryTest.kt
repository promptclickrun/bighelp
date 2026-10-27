package app.bighelp.android

import app.bighelp.hermes.HermesEndpoint
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class HostDiscoveryTest {
    private lateinit var host: MockWebServer

    @Before fun start() { host = MockWebServer(); host.start() }
    @After fun stop() { host.shutdown() }
    private fun endpoint() = HermesEndpoint.parse(host.url("/hermes").toString(), allowPrivateHttp = true)

    @Test fun consentIsRequiredBeforeAnyRequest() = runTest {
        val result = HostDiscovery().check(endpoint(), consentGranted = false)
        assertEquals(DiscoveryResult.ConsentRequired, result)
        assertEquals(0, host.requestCount)
    }

    @Test fun discoversCapabilitiesWithoutSendingCredentialsAndKeepsPrefix() = runTest {
        host.enqueue(json("""{"auth_required":true,"auth_flows":["cookie","native_pkce","future"]}"""))
        val result = HostDiscovery().check(endpoint(), consentGranted = true)
        assertEquals(DiscoveryResult.Available(authRequired = true, browserSignIn = true), result)
        val request = host.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/hermes/api/status", request.path)
        assertEquals("application/json", request.getHeader("Accept"))
        assertEquals("no-store", request.getHeader("Cache-Control"))
        assertNull(request.getHeader("Authorization"))
        assertNull(request.getHeader("Cookie"))
        assertNull(request.getHeader("X-Hermes-Session-Token"))
    }

    @Test fun neverFollowsRedirectsOrPublishesWebPageBodies() = runTest {
        host.enqueue(MockResponse().setResponseCode(302).addHeader("Location", host.url("/other")))
        host.enqueue(json("""{"auth_required":false}"""))
        assertEquals(DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
        assertEquals(1, host.requestCount)
    }

    @Test fun onlyAnHttp200CountsEvenWhenTheBodyIsAValidStatus() = runTest {
        listOf(201, 404, 500).forEach { code ->
            host.enqueue(json("""{"auth_required":false}""").setResponseCode(code))
            assertEquals("HTTP $code", DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
        }
        assertEquals(3, host.requestCount)
    }

    @Test fun malformedOrNonJsonResponsesStayUnavailable() = runTest {
        listOf(
            json("""{"auth_required":"false"}"""),
            json("""{"auth_required":false,"auth_flows":["native_pkce","native_pkce"]}"""),
            MockResponse().setHeader("Content-Type", "text/html").setBody("<html>Private proxy diagnostic</html>"),
        ).forEach { response ->
            host.enqueue(response)
            assertEquals(DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
        }
    }

    // The budget is 16,384 decoded bytes. Each body below is valid JSON padded with spaces, so size is the
    // only thing that can make the answer differ.

    @Test fun aStatusExactlyAtTheSizeBudgetIsAccepted() = runTest {
        host.enqueue(json(statusPaddedTo(HostStatus.MAXIMUM_BYTES)))
        assertEquals(DiscoveryResult.Available(false, false), HostDiscovery().check(endpoint(), true))
    }

    @Test fun aStatusOneByteOverTheSizeBudgetIsRefused() = runTest {
        host.enqueue(json(statusPaddedTo(HostStatus.MAXIMUM_BYTES + 1)))
        assertEquals(DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
    }

    @Test fun theSizeBudgetAlsoHoldsWhenTheLengthIsNotDeclared() = runTest {
        // A chunked body has no Content-Length, so only reading the stream can tell it is too large.
        host.enqueue(chunkedJson(statusPaddedTo(HostStatus.MAXIMUM_BYTES)))
        assertEquals(DiscoveryResult.Available(false, false), HostDiscovery().check(endpoint(), true))

        host.enqueue(chunkedJson(statusPaddedTo(HostStatus.MAXIMUM_BYTES + 1)))
        assertEquals(DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
    }

    @Test fun discoveryIsNotAnAuthenticatedConnection() = runTest {
        host.enqueue(json("""{"auth_required":false,"auth_flows":null}"""))
        assertEquals(DiscoveryResult.Available(false, false), HostDiscovery().check(endpoint(), true))
        assertEquals(1, host.requestCount)
        assertEquals("/hermes/api/status", host.takeRequest().path)
    }

    /** Real time and a real socket: the server reads the request and never answers, then the caller cancels. */
    @Test fun cancellingTheCheckCancelsTheRealCall() = runBlocking {
        host.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val cancelled = CompletableDeferred<Unit>()
        val client = OkHttpClient.Builder()
            .eventListener(object : EventListener() {
                override fun canceled(call: Call) { cancelled.complete(Unit) }
            })
            .build()

        val check = launch(Dispatchers.Default) { HostDiscovery(client).check(endpoint(), true) }
        assertNotNull("the request never reached the server", host.takeRequest(5, TimeUnit.SECONDS))
        check.cancel()
        withTimeout(5_000) { cancelled.await() }
        check.join()
    }

    private fun statusPaddedTo(bytes: Int): String {
        val status = """{"auth_required":false}"""
        return status + " ".repeat(bytes - status.length)
    }

    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    private fun chunkedJson(body: String) =
        MockResponse().setHeader("Content-Type", "application/json").setChunkedBody(body, 1_000)
}
