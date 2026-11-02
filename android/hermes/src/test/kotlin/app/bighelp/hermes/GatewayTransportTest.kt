package app.bighelp.hermes

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout

/** The socket layer on its own, so each of its protections is proven without the client's second line of defense. */
class GatewayTransportTest {
    @get:Rule val testTimeout: Timeout = Timeout.seconds(60)

    private val peer = RawPeer()
    private val transports = mutableListOf<GatewayTransport>()

    private class Recorder : GatewayTransportListener {
        val opened = LinkedBlockingQueue<String>()
        val messages = LinkedBlockingQueue<ByteArray>()
        val failed = LinkedBlockingQueue<HermesException>()
        override fun opened(negotiatedSubprotocol: String?) { opened.add(negotiatedSubprotocol.orEmpty()) }
        override fun message(bytes: ByteArray) { messages.add(bytes) }
        override fun failed(error: HermesException) { failed.add(error) }
    }

    @After fun stop() {
        transports.forEach { runCatching { it.close(orderly = false) } }
        peer.close()
    }

    private fun open(
        required: String? = null,
        headers: Map<String, String> = emptyMap(),
        recorder: Recorder = Recorder(),
        path: String = "/api/ws",
    ): Pair<GatewayTransport, Recorder> {
        val transport = GatewayWebSockets.open(SocketRequest("ws://127.0.0.1:${peer.port}$path", headers, required), recorder)
        transports += transport
        return transport to recorder
    }

    private val ticketed = mapOf("Sec-WebSocket-Protocol" to "hermes-gateway-v1, hermes-gateway-ticket.t1")

    @Test fun aTicketedSocketOpensOnlyWhenTheMainProtocolAloneIsNegotiated() {
        val (_, ok) = open(required = "hermes-gateway-v1", headers = ticketed)
        val session = peer.awaitUpgrade()
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.t1", session.header("sec-websocket-protocol"))
        session.accept(subprotocol = "hermes-gateway-v1")
        assertEquals("hermes-gateway-v1", ok.opened.poll(5, TimeUnit.SECONDS))
        assertTrue(ok.failed.isEmpty())
    }

    @Test fun theTransportItselfRefusesTheTicketEchoedBackAndEverythingElseThatIsNotTheMainProtocol() {
        for (answer in listOf("hermes-gateway-ticket.t1", "hermes-gateway-v1, hermes-gateway-ticket.t1", "hermes-gateway-v2", null)) {
            val (_, recorder) = open(required = "hermes-gateway-v1", headers = ticketed)
            peer.awaitUpgrade().accept(subprotocol = answer)
            assertEquals(answer ?: "none", HermesException.Kind.InvalidResponse, recorder.failed.poll(5, TimeUnit.SECONDS)?.kind)
            assertNull("It never reported an open socket", recorder.opened.poll(100, TimeUnit.MILLISECONDS))
        }
    }

    @Test fun aSocketThatOffersNoProtocolAcceptsAnUnadornedUpgrade() {
        val (_, recorder) = open()
        val session = peer.awaitUpgrade()
        assertNull(session.header("sec-websocket-protocol"))
        session.accept()
        assertEquals("", recorder.opened.poll(5, TimeUnit.SECONDS))
    }

    @Test fun headersThatCouldSplitTheRequestAreRefusedBeforeAnyConnection() {
        val bad = listOf(
            mapOf("X-Gate" to "ok\r\nInjected: 1"), mapOf("X-Gate" to "ok\nInjected: 1"), mapOf("X-Gate" to "nul\u0000"),
            mapOf("Bad Name" to "v"), mapOf("Bad:Name" to "v"), mapOf("" to "v"), mapOf("X\r\nY" to "v"),
        )
        for (headers in bad) {
            val failure = assertThrows(HermesException::class.java) { open(headers = headers) }
            assertEquals(headers.toString(), HermesException.Kind.InvalidAccessCredentials, failure.kind)
        }
        for (offer in listOf("hermes-gateway-v1, bad\r\nprotocol", "has space, other", "a,,b\u007f")) {
            assertThrows(HermesException::class.java) { open(headers = mapOf("Sec-WebSocket-Protocol" to offer)) }
        }
        assertThrows(HermesException::class.java) { GatewayWebSockets.open(SocketRequest("http://127.0.0.1:1/api/ws", emptyMap(), null), Recorder()) }
        assertThrows(HermesException::class.java) { GatewayWebSockets.open(SocketRequest("not a url", emptyMap(), null), Recorder()) }
        assertNull("No connection was ever made", peer.upgrades.poll(300, TimeUnit.MILLISECONDS))
    }

    @Test fun aDeliberateCloseEndsTheSocketAndReportsNothingMore() {
        val (transport, recorder) = open()
        val session = peer.awaitUpgrade()
        session.accept()
        session.serve() // a reader, so the peer can see the connection end
        assertEquals("", recorder.opened.poll(5, TimeUnit.SECONDS))
        transport.close(orderly = false)
        assertTrue("The peer sees the connection end", session.awaitClientGone(5_000))
        assertNull("and the owner is told nothing further", recorder.failed.poll(500, TimeUnit.MILLISECONDS))
        transport.close(orderly = false) // idempotent
        assertEquals(false, transport.send("{}"))
    }

    @Test fun closingWhileTheUpgradeIsStillPendingAbortsTheConnectAttempt() {
        val (transport, recorder) = open()
        val session = peer.awaitUpgrade() // the peer never answers
        session.serve()
        transport.close(orderly = false)
        assertTrue("The half-made connection was dropped", session.awaitClientGone(5_000))
        assertNull(recorder.failed.poll(500, TimeUnit.MILLISECONDS))
    }

    @Test fun framesAreSentInOrderAsMaskedTextAndTheWriteBufferSignalDrains() {
        val (transport, recorder) = open()
        val session = peer.awaitUpgrade()
        session.accept()
        recorder.opened.poll(5, TimeUnit.SECONDS)
        val texts = (1..50).map { """{"n":$it,"pad":"${"é".repeat(it)}"}""" }
        texts.forEach { assertTrue(transport.send(it)) }
        val received = (1..50).map { session.readFrame(5_000) }
        assertTrue(received.all { it != null && it.opcode == 0x1 && it.fin })
        assertEquals("Same order, UTF-8 intact", texts, received.map { it!!.text })
        val deadline = System.nanoTime() + 5_000_000_000L
        while (transport.hasBufferedData && System.nanoTime() < deadline) Thread.sleep(5)
        assertEquals("Everything handed over was taken by the writer", false, transport.hasBufferedData)
    }
}
