package app.bighelp.hermes

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The gated gateway authenticates with `Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.<t>`
 * and the host answers with the negotiated `hermes-gateway-v1`. These tests prove the platform
 * WebSocket (OkHttp) really sends a hand-set two-value header, lets proxy headers ride the upgrade,
 * sends no cookies, and exposes the negotiated value, before any client code depends on it.
 */
class OkHttpWebSocketNegotiationTest {
    private val server = MockWebServer()

    @After fun stop() = server.shutdown()

    private fun upgrade(negotiated: String?, onOpen: (WebSocket) -> Unit = {}) {
        val response = MockResponse()
        if (negotiated != null) response.setHeader("Sec-WebSocket-Protocol", negotiated)
        server.enqueue(response.withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = onOpen(webSocket)
        }))
        server.start()
    }

    private fun open(request: Request): Pair<WebSocket, Response> {
        val opened = CompletableFuture<Response>()
        val socket = OkHttpClient.Builder().build().newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { opened.complete(response) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                opened.completeExceptionally(t)
            }
        })
        return socket to opened.get(10, TimeUnit.SECONDS)
    }

    @Test fun aHandSetTwoValueSubprotocolHeaderReachesTheHostAndTheNegotiatedValueIsReadable() {
        upgrade(negotiated = "hermes-gateway-v1")
        val offered = "hermes-gateway-v1, hermes-gateway-ticket.synthetic_Ticket-1"
        val (socket, response) = open(
            Request.Builder().url(server.url("/api/ws")).header("Sec-WebSocket-Protocol", offered).build(),
        )
        val received = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/api/ws", received.path)
        assertEquals(offered, received.getHeader("Sec-WebSocket-Protocol"))
        assertEquals("hermes-gateway-v1", response.header("Sec-WebSocket-Protocol"))
        socket.cancel()
    }

    @Test fun proxyHeadersRideTheUpgradeAndNoCookieIsSent() {
        upgrade(negotiated = null)
        val (socket, response) = open(
            Request.Builder().url(server.url("/hermes/api/ws"))
                .header("CF-Access-Client-Id", "id").header("X-Session-Gate", "g")
                .header("X-Hermes-Session-Token", "dashboard-token").build(),
        )
        val received = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("id", received.getHeader("CF-Access-Client-Id"))
        assertEquals("g", received.getHeader("X-Session-Gate"))
        assertEquals("dashboard-token", received.getHeader("X-Hermes-Session-Token"))
        assertNull(received.getHeader("Cookie"))
        assertNull("A dashboard upgrade offers no subprotocol", received.getHeader("Sec-WebSocket-Protocol"))
        assertNull(response.header("Sec-WebSocket-Protocol"))
        socket.cancel()
    }
}
