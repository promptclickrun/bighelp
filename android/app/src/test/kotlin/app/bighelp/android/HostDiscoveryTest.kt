package app.bighelp.android

import app.bighelp.hermes.HermesEndpoint
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
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
        assertEquals("/hermes/api/status", request.path)
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

    @Test fun malformedOversizedOrNonJsonResponsesStayUnavailable() = runTest {
        listOf(
            json("""{"auth_required":"false"}"""),
            json("""{"auth_required":false,"auth_flows":["native_pkce","native_pkce"]}"""),
            json("""{"auth_required":false,"auth_flows":null}""" + "x".repeat(16_384)),
            MockResponse().setHeader("Content-Type", "text/html").setBody("<html>Private proxy diagnostic</html>"),
        ).forEach { response ->
            host.enqueue(response)
            assertEquals(DiscoveryResult.Unavailable, HostDiscovery().check(endpoint(), true))
        }
    }

    @Test fun discoveryIsNotAnAuthenticatedConnection() = runTest {
        host.enqueue(json("""{"auth_required":false,"auth_flows":null}"""))
        assertEquals(DiscoveryResult.Available(false, false), HostDiscovery().check(endpoint(), true))
        assertEquals(1, host.requestCount)
        assertEquals("/hermes/api/status", host.takeRequest().path)
    }

    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
}
