package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout

/**
 * The gateway against a peer that writes raw WebSocket frames byte by byte. These are the inbound-contract
 * tests: nothing larger than 4 MiB is accepted or even waited for, UTF-8 is strict for TEXT frames whole or
 * fragmented, upgrade headers are bounded, and upgrade refusals keep their types.
 */
class GatewayRawPeerTest {
    private val peer = RawPeer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val resources = mutableListOf<AutoCloseable>()

    @get:Rule val testTimeout: Timeout = Timeout.seconds(60)

    private val timings = GatewayTimings(
        readyMillis = 3_000, advertiseMillis = 1_000, requestMillis = 3_000, heartbeatMillis = 60_000, pingMillis = 60_000,
        pingReplyMillis = 500, livenessMillis = 500, admissionMillis = 500, reconnectDelaysMillis = emptyList(),
    )

    @After fun stop() {
        scope.cancel()
        resources.forEach { runCatching { it.close() } }
        peer.close()
    }

    private fun endpoint() = HermesEndpoint.parse("http://127.0.0.1:${peer.port}", allowPrivateHttp = true)

    private fun client(access: AccessHeaders = AccessHeaders.none, bearer: Boolean = false, timings: GatewayTimings = this.timings): GatewayClient {
        val endpoint = endpoint()
        val authenticator = HermesAuthenticator(endpoint, OkHttpHermesHttp(endpoint, access), InMemoryCredentialStore())
        resources += authenticator
        authenticator.adoptForTest(
            if (bearer) SavedConnection(endpoint, StoredAuth.Bearer("access-1", "refresh-1", System.currentTimeMillis() / 1_000 + 3_600), "basic", "u")
            else SavedConnection(endpoint, StoredAuth.DashboardSession("dash-token", automatic = false), null, null),
            persisted = false,
        )
        return GatewayClient(authenticator, scope, timings)
    }

    private class Connected(val client: GatewayClient, val session: RawPeer.Session, val events: CopyOnWriteArrayList<GatewayEvent>)

    private fun GatewayClient.collectEvents(): CopyOnWriteArrayList<GatewayEvent> {
        val events = CopyOnWriteArrayList<GatewayEvent>()
        scope.launch { this@collectEvents.events.collect { events += it } }
        runBlocking { eventually { subscriberCount == 1 } }
        return events
    }

    private suspend fun eventually(timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        withTimeout(timeoutMillis) { while (!condition()) delay(10) }
    }

    /** A fully connected client over a peer that answers the connect sequence. */
    private fun connect(access: AccessHeaders = AccessHeaders.none, timings: GatewayTimings = this.timings): Connected {
        val client = client(access, timings = timings)
        val events = client.collectEvents()
        val connecting = scope.async { client.connect() }
        val session = peer.awaitUpgrade()
        session.accept()
        session.ready()
        session.serve()
        runBlocking { connecting.await() }
        return Connected(client, session, events)
    }

    /** Starts a connect, lets [answer] play the upgrade, and returns how it ended. */
    private fun connectAttempt(client: GatewayClient = client(), answer: (RawPeer.Session) -> Unit): Throwable? {
        val connecting: Deferred<Result<GatewayState>> = scope.async { runCatching { client.connect() } }
        answer(peer.awaitUpgrade())
        return runBlocking { withTimeout(10_000) { connecting.await() } }.exceptionOrNull()
    }

    private fun kindOf(failure: Throwable?) = (failure as? HermesException)?.kind

    // Oversized declared length, no body

    @Test fun aFrameHeaderDeclaringTooBigABodyIsRejectedWithoutItsBodyEverArriving() {
        val limit = HermesWire.MAXIMUM_MESSAGE_BYTES.toLong()
        for (declared in listOf(limit + 1, 64L * 1_024 * 1_024, 0x7FFF_FFF0L, 1L shl 40)) {
            val connected = connect()
            val pending = scope.async { runCatching { connected.client.request("profiles.list") } }
            connected.session.awaitMethodSent("profiles.list")
            connected.session.frameHeaderOnly(opcode = 0x1, declaredLength = declared)   // and then nothing
            val failure = runBlocking { withTimeout(3_000) { pending.await() } }.exceptionOrNull()
            assertEquals("declared $declared", HermesException.Kind.MessageTooLarge, kindOf(failure))
            runBlocking { eventually(3_000) { connected.client.state.value.lastFailure?.kind == HermesException.Kind.MessageTooLarge } }
            assertTrue("The client dropped the connection", connected.session.awaitClientGone(3_000))
            runBlocking { connected.client.disconnect() }
        }
    }

    @Test fun aBodyExactlyAtTheLimitIsStillAwaitedNotRejected() {
        val connected = connect()
        connected.session.frameHeaderOnly(opcode = 0x1, declaredLength = HermesWire.MAXIMUM_MESSAGE_BYTES.toLong())
        Thread.sleep(700)
        assertEquals(GatewayConnection.Connected, connected.client.state.value.connection)
        runBlocking { connected.client.disconnect() }
    }

    @Test fun fragmentsWhoseSumPassesTheLimitAreRejectedAsTheyAccumulate() {
        for (shape in listOf(listOf(3, 2), listOf(1, 1, 1, 1, 1), listOf(4, 1))) {
            val connected = connect()
            val pending = scope.async { runCatching { connected.client.request("profiles.list") } }
            connected.session.awaitMethodSent("profiles.list")
            shape.forEachIndexed { index, mebibytes ->
                val payload = ByteArray(mebibytes * 1_024 * 1_024) { 'a'.code.toByte() }
                runCatching { connected.session.frame(if (index == 0) 0x1 else 0x0, payload, fin = index == shape.lastIndex) }
            }
            val failure = runBlocking { withTimeout(5_000) { pending.await() } }.exceptionOrNull()
            assertEquals(shape.toString(), HermesException.Kind.MessageTooLarge, kindOf(failure))
            assertTrue("Nothing was published", connected.events.none { it.event.type != "gateway.ready" })
            runBlocking { connected.client.disconnect() }
        }
    }

    // Strict UTF-8

    private val eventJson = """{"jsonrpc":"2.0","method":"event","params":{"type":"héllo wörld 😀 日本語","payload":{}}}"""

    @Test fun aCodePointSplitAnywhereAcrossFragmentsIsDeliveredIntact() {
        val connected = connect()
        val bytes = eventJson.toByteArray(Charsets.UTF_8)
        for (cut in 1 until bytes.size) {
            connected.session.frame(0x1, bytes.copyOfRange(0, cut), fin = false)
            connected.session.frame(0x0, bytes.copyOfRange(cut, bytes.size), fin = true)
        }
        runBlocking { eventually { connected.events.count { it.event.type == "héllo wörld 😀 日本語" } == bytes.size - 1 } }
        assertEquals(GatewayConnection.Connected, connected.client.state.value.connection)
        runBlocking { connected.client.disconnect() }
    }

    @Test fun everyByteAsItsOwnFragmentWithAPingBetweenIsDeliveredAndThePingAnswered() {
        val connected = connect()
        val bytes = eventJson.toByteArray(Charsets.UTF_8)
        bytes.forEachIndexed { index, byte ->
            connected.session.frame(if (index == 0) 0x1 else 0x0, byteArrayOf(byte), fin = index == bytes.lastIndex)
            if (index % 11 == 0 && index < bytes.lastIndex) connected.session.frame(0x9, byteArrayOf(1, 2, 3))
        }
        runBlocking { eventually { connected.events.any { it.event.type == "héllo wörld 😀 日本語" } } }
        val pong = generateSequence { connected.session.receivedFrames.poll(2, java.util.concurrent.TimeUnit.SECONDS) }.firstOrNull { it.opcode == 0xA }
        assertTrue("The library answers a ping between fragments", pong != null)
        runBlocking { connected.client.disconnect() }
    }

    private fun malformed(vararg bytes: Int) = ByteArray(bytes.size) { bytes[it].toByte() }

    private val invalidSequences = mapOf(
        "lone continuation byte" to malformed(0x80),
        "0xFF" to malformed(0xFF),
        "truncated lead" to malformed(0xC3),
        "overlong slash" to malformed(0xC0, 0xAF),
        "encoded surrogate" to malformed(0xED, 0xA0, 0x80),
        "five byte form" to malformed(0xF8, 0x88, 0x80, 0x80, 0x80),
        "beyond U+10FFFF" to malformed(0xF4, 0x90, 0x80, 0x80),
        "truncated four byte" to malformed(0xF0, 0x9F, 0x98),
    )

    private fun jsonWithRaw(middle: ByteArray): ByteArray =
        """{"jsonrpc":"2.0","method":"event","params":{"type":"x""".toByteArray() + middle + """y","payload":{}}}""".toByteArray()

    @Test fun malformedUtf8InATextFrameIsRejectedNotRepairedToAReplacementCharacter() {
        for ((name, bad) in invalidSequences) {
            val connected = connect()
            val pending = scope.async { runCatching { connected.client.request("profiles.list") } }
            connected.session.awaitMethodSent("profiles.list")
            connected.session.frame(0x1, jsonWithRaw(bad))
            val failure = runBlocking { withTimeout(5_000) { pending.await() } }.exceptionOrNull()
            assertEquals(name, HermesException.Kind.InvalidResponse, kindOf(failure))
            assertTrue("$name: no event, least of all one with U+FFFD, was published", connected.events.none { it.event.type != "gateway.ready" })
            runBlocking { connected.client.disconnect() }
        }
    }

    @Test fun malformedUtf8InAnyFragmentOrAtTheEndOfAMessageIsRejected() {
        val shapes: Map<String, (RawPeer.Session) -> Unit> = mapOf(
            "bad bytes in the final fragment" to { s ->
                s.frame(0x1, jsonWithRaw(malformed()).copyOfRange(0, 60), fin = false)
                s.frame(0x0, malformed(0xFF) + """y","payload":{}}}""".toByteArray(), fin = true)
            },
            "bad bytes in a middle fragment" to { s ->
                val head = """{"jsonrpc":"2.0","method":"event","params":{"type":"x""".toByteArray()
                s.frame(0x1, head, fin = false)
                s.frame(0x0, malformed(0xC0, 0xAF), fin = false)
                s.frame(0x0, """y","payload":{}}}""".toByteArray(), fin = true)
            },
            "message ends inside a code point" to { s ->
                s.frame(0x1, """{"jsonrpc":"2.0","method":"event","params":{"type":"x""".toByteArray() + malformed(0xE6, 0x97), fin = false)
                s.frame(0x0, malformed(), fin = true)
            },
        )
        for ((name, send) in shapes) {
            val connected = connect()
            val pending = scope.async { runCatching { connected.client.request("profiles.list") } }
            connected.session.awaitMethodSent("profiles.list")
            send(connected.session)
            val failure = runBlocking { withTimeout(5_000) { pending.await() } }.exceptionOrNull()
            assertEquals(name, HermesException.Kind.InvalidResponse, kindOf(failure))
            assertTrue(name, connected.events.none { it.event.type != "gateway.ready" })
            runBlocking { connected.client.disconnect() }
        }
    }

    @Test fun binaryFramesKeepTheirMeaningValidJsonIsDeliveredAndInvalidUtf8IsStillRefused() {
        val ok = connect()
        ok.session.binary(eventJson.toByteArray(Charsets.UTF_8))
        runBlocking { eventually { ok.events.any { it.event.type == "héllo wörld 😀 日本語" } } }
        runBlocking { ok.client.disconnect() }

        val bad = connect()
        val pending = scope.async { runCatching { bad.client.request("profiles.list") } }
        bad.session.awaitMethodSent("profiles.list")
        bad.session.binary(jsonWithRaw(malformed(0xFF)))
        assertEquals(HermesException.Kind.InvalidResponse, kindOf(runBlocking { withTimeout(5_000) { pending.await() } }.exceptionOrNull()))
        runBlocking { bad.client.disconnect() }
    }

    @Test fun compressionBitsAndUnofferedExtensionsAreRefused() {
        val connected = connect()
        val pending = scope.async { runCatching { connected.client.request("profiles.list") } }
        connected.session.awaitMethodSent("profiles.list")
        connected.session.frame(0x1, eventJson.toByteArray(), rsv = 4) // RSV1
        assertEquals(HermesException.Kind.InvalidResponse, kindOf(runBlocking { withTimeout(5_000) { pending.await() } }.exceptionOrNull()))
        assertTrue(connected.events.none { it.event.type != "gateway.ready" })
        runBlocking { connected.client.disconnect() }

        var offered = true
        val failure = connectAttempt {
            offered = it.hasHeader("sec-websocket-extensions")
            it.accept(extensions = "permessage-deflate")
        }
        assertEquals(HermesException.Kind.InvalidResponse, kindOf(failure))
        assertFalse("No extension was ever offered", offered)
    }

    // Upgrade headers

    @Test fun anUpgradeResponseWithOversizedHeadersIsRefusedWhetherOrNotItEnds() {
        val padding = (1..2_000).joinToString("") { "X-Pad-$it: ${"p".repeat(20)}\r\n" } // about 50 KB
        val terminated = connectAttempt { it.accept(extraHeaders = padding.trimEnd().split("\r\n")) }
        assertEquals(HermesException.Kind.MessageTooLarge, kindOf(terminated))

        val endless = connectAttempt { session ->
            session.rawText("HTTP/1.1 101 Switching Protocols\r\n")
            Thread {
                runCatching { repeat(200) { session.rawText("X-Never-Ends-$it: ${"e".repeat(1_000)}\r\n") } }
            }.start()
        }
        assertEquals(HermesException.Kind.MessageTooLarge, kindOf(endless))
    }

    @Test fun aLargeButAllowedUpgradeHeaderBlockStillConnects() {
        val client = client()
        val connecting = scope.async { runCatching { client.connect() } }
        val session = peer.awaitUpgrade()
        val padding = (1..300).map { "X-Pad-$it: ${"p".repeat(30)}" } // about 12 KB
        session.accept(extraHeaders = padding)
        session.ready()
        session.serve()
        assertTrue(runBlocking { connecting.await() }.isSuccess)
        runBlocking { client.disconnect() }
    }

    @Test fun upgradeRefusalsKeepTheirTypes() {
        fun refuse(status: String, vararg headers: String) = connectAttempt { it.rawText("HTTP/1.1 $status\r\n${headers.joinToString("") { h -> "$h\r\n" }}Content-Length: 0\r\nConnection: close\r\n\r\n") }
        assertEquals(HermesException.Kind.InvalidCredentials, kindOf(refuse("401 Unauthorized")))
        assertEquals(HermesException.Kind.InvalidCredentials, kindOf(refuse("403 Forbidden")))
        assertEquals(HermesException.Kind.RedirectRefused, kindOf(refuse("301 Moved Permanently", "Location: /elsewhere")))
        assertEquals(HermesException.Kind.RedirectRefused, kindOf(refuse("302 Found", "Location: https://example.invalid/")))
        assertEquals(HermesException.Kind.RedirectRefused, kindOf(refuse("307 Temporary Redirect", "Location: /x")))
        assertEquals(HermesException.Kind.ConnectionFailed, kindOf(refuse("503 Service Unavailable")))
        assertEquals(HermesException.Kind.ConnectionFailed, kindOf(refuse("200 OK")))
        assertEquals("A 101 that does not prove the key is not an upgrade", HermesException.Kind.InvalidResponse, kindOf(connectAttempt {
            it.rawText("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n")
        }))
        assertTrue("No redirect target was ever contacted", peer.httpPaths.none { it == "/elsewhere" || it == "/x" })
    }

    // What the client sends

    @Test fun theUpgradeRequestCarriesExactlyTheContractedHeaders() {
        val access = AccessHeaders.of(endpoint(), AccessCredential.proxyBasic("gate-user", "gate-pass"), listOf(CustomHeader.of("X-Gate", "é-ü")))
        val connected = connect(access)
        val session = connected.session
        assertEquals("GET /api/ws?token=dash-token HTTP/1.1", session.requestLine)
        assertEquals("127.0.0.1:${peer.port}", session.header("host"))
        assertEquals("websocket", session.header("upgrade")?.lowercase())
        assertEquals("upgrade", session.header("connection")?.lowercase())
        assertEquals("13", session.header("sec-websocket-version"))
        assertEquals(24, session.header("sec-websocket-key")?.length)
        assertEquals("dash-token", session.header("x-hermes-session-token"))
        assertEquals("Basic Z2F0ZS11c2VyOmdhdGUtcGFzcw==", session.header("authorization"))
        assertTrue("A non-ASCII proxy header value is sent as UTF-8, not turned into ?", session.head.contains("X-Gate: Ã©-Ã¼"))
        for (absent in listOf("cookie", "origin", "sec-websocket-extensions", "sec-websocket-protocol")) {
            assertNull(absent, session.header(absent))
        }
        runBlocking { connected.client.disconnect() }
    }

    @Test fun aTicketedUpgradeOffersTheTwoProtocolsInOrderCarriesNoQueryOrProviderTokenAndInsistsOnTheFirstBeingNegotiated() {
        val client = client(bearer = true)
        val connecting = scope.async { runCatching { client.connect() } }
        val session = peer.awaitUpgrade()
        assertEquals("GET /api/ws HTTP/1.1", session.requestLine)
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.raw_ticket_1", session.header("sec-websocket-protocol"))
        assertNull("The provider token never rides the gateway request", session.header("authorization"))
        assertFalse("nor does it leak into the target", session.requestLine.contains("access-1"))
        session.accept(subprotocol = "hermes-gateway-v1")
        session.ready()
        session.serve()
        assertTrue(runBlocking { connecting.await() }.isSuccess)
        runBlocking { client.disconnect() }
    }

    @Test fun anythingButTheMainProtocolNegotiatedBackIsRefusedForATicketedUpgrade() {
        for (answer in listOf("hermes-gateway-ticket.raw_ticket_1", "hermes-gateway-v1, hermes-gateway-ticket.raw_ticket_2", "hermes-gateway-v2", null)) {
            val failure = connectAttempt(client(bearer = true)) { it.accept(subprotocol = answer) }
            assertEquals(answer ?: "no protocol", HermesException.Kind.InvalidResponse, kindOf(failure))
        }
    }

    private fun RawPeer.Session.awaitMethodSent(method: String, timeoutMillis: Long = 5_000) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (method !in receivedMethods) {
            check(System.nanoTime() < deadline) { "The client never sent $method" }
            Thread.sleep(10)
        }
    }
}
