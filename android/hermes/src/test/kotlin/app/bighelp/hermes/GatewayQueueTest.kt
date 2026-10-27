package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout

/**
 * The outbound queue ceilings with a deterministic stalled peer: ordinary requests 8 MiB, one attachment of up
 * to 12 MiB counted apart, server replies 4 MiB. The socket's "unwritten data" flag is the test's to flip, so
 * no kernel buffer size or timing decides anything.
 */
class GatewayQueueTest {
    @get:Rule val testTimeout: Timeout = Timeout.seconds(90)

    private val host = ScriptedHost()
    private val transports = FakeTransports()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val resources = mutableListOf<AutoCloseable>()
    private val mebibyte = 1_048_576

    private val timings = GatewayTimings(
        readyMillis = 3_000, advertiseMillis = 2_000, requestMillis = 60_000, heartbeatMillis = 600_000, pingMillis = 600_000,
        pingReplyMillis = 5_000, reconnectDelaysMillis = emptyList(),
    )

    @After fun stop() {
        scope.cancel()
        resources.forEach { runCatching { it.close() } }
        host.close()
    }

    /** Handlers go in before connecting: the advertisement then happens inside the handshake, not mid-test. */
    private fun connected(register: (GatewayClient) -> Unit = {}): Pair<GatewayClient, FakeTransports.Fake> {
        host.on("GET", "/api/health", ScriptedHost.json("""{"ok":true,"auth_required":false}"""))
        val authenticator = HermesAuthenticator(host.endpoint, OkHttpHermesHttp(host.endpoint), InMemoryCredentialStore())
        resources += authenticator
        authenticator.adoptForTest(SavedConnection(host.endpoint, StoredAuth.DashboardSession("dash-token", false), null, null), persisted = false)
        val client = GatewayClient(authenticator, scope, timings, transports)
        register(client)
        runBlocking { client.connect() }
        return client to transports.current!!
    }

    private suspend fun eventually(timeoutMillis: Long = 10_000, condition: suspend () -> Boolean) {
        withTimeout(timeoutMillis) { while (!condition()) delay(5) }
    }

    /** Frame bytes of `{"jsonrpc","id","method","params":{"blob":...}}` with a 36-character ID. */
    private fun frameBytes(method: String, blobChars: Int) = utf8Length(
        buildJsonObject {
            put("jsonrpc", "2.0"); put("id", "0".repeat(36)); put("method", method)
            put("params", buildJsonObject { put("blob", "x".repeat(blobChars)) })
        }.toString(),
    )

    private fun blob(method: String, targetFrameBytes: Int): JsonObject {
        val chars = targetFrameBytes - frameBytes(method, 0)
        require(chars >= 0)
        return buildJsonObject { put("blob", "x".repeat(chars)) }
    }

    private fun request(client: GatewayClient, method: String, frameBytes: Int, maximum: Int = GatewayClient.DEFAULT_FRAME_BYTES): Deferred<Result<*>> =
        scope.async { runCatching { client.request(method, blob(method, frameBytes), maximumFrameBytes = maximum) } }

    private fun kindOf(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind

    /** Queues [count] ordinary frames of [size] bytes and waits until each is in the queue. */
    private fun fill(client: GatewayClient, count: Int, size: Int): List<Deferred<Result<*>>> {
        val calls = ArrayList<Deferred<Result<*>>>()
        repeat(count) { index ->
            calls += request(client, "profiles.list", size)
            runBlocking { eventually { client.queueSnapshot().frames == index + 1 } }
        }
        return calls
    }

    @Test fun ordinaryRequestsAreHeldToEightMebibytesExactlyAndReleasedInOrder() = runBlocking {
        val (client, socket) = connected()
        val before = socket.sent.size
        socket.buffered = true // the peer stopped reading

        fill(client, 8, mebibyte - 64)
        assertEquals(8 * (mebibyte - 64), client.queueSnapshot().ordinary)
        val remaining = 8 * mebibyte - client.queueSnapshot().ordinary // 512 bytes of room
        request(client, "profiles.list", remaining) // exactly fills the queue
        eventually { client.queueSnapshot().frames == 9 }
        assertEquals("Exactly eight mebibytes", 8 * mebibyte, client.queueSnapshot().ordinary)
        assertEquals(HermesException.Kind.TooManyRequests, kindOf { client.request("profiles.list") })
        assertEquals("Nothing left the socket while it was stalled", before, socket.sent.size)

        socket.buffered = false
        eventually { socket.sentWithMethod("profiles.list").size == 9 }
        val frames = socket.sentWithMethod("profiles.list")
        assertEquals("The last queued frame went last", remaining, utf8Length(frames.last()))
        assertTrue(frames.dropLast(1).all { utf8Length(it) == mebibyte - 64 })
        eventually { client.queueSnapshot().frames == 0 }
        assertEquals(0, client.queueSnapshot().ordinary)
        request(client, "profiles.list", 300) // the queue accepts again, and the new frame goes straight out
        eventually { socket.sentWithMethod("profiles.list").size == 10 }
        client.disconnect()
    }

    @Test fun anAttachmentFrameUpToTwelveMebibytesIsNotBlockedByAFullOrdinaryQueue() = runBlocking {
        val (client, socket) = connected()
        socket.buffered = true
        fill(client, 8, mebibyte)
        assertEquals(8 * mebibyte, client.queueSnapshot().ordinary)
        assertEquals("The ordinary queue is full", HermesException.Kind.TooManyRequests, kindOf { client.request("profiles.list") })

        val twelve = GatewayClient.ATTACHMENT_FRAME_BYTES
        val attach = request(client, "file.attach", twelve, maximum = twelve)
        eventually { client.queueSnapshot().attachment == twelve }
        assertEquals("Counted apart from the ordinary queue", 8 * mebibyte, client.queueSnapshot().ordinary)
        assertEquals("Only one attachment RPC at a time", HermesException.Kind.TooManyRequests, kindOf {
            client.request("image.attach_bytes", blob("image.attach_bytes", 1_000), maximumFrameBytes = twelve)
        })
        assertEquals("Twelve mebibytes is the ceiling", HermesException.Kind.MessageTooLarge, kindOf {
            client.request("file.attach", blob("file.attach", twelve + 1), maximumFrameBytes = twelve)
        })
        assertEquals("An ordinary frame never gets the attachment allowance", HermesException.Kind.MessageTooLarge, kindOf {
            client.request("profiles.list", blob("profiles.list", GatewayClient.DEFAULT_FRAME_BYTES + 1))
        })

        socket.buffered = false
        eventually(30_000) { socket.sentWithMethod("file.attach").size == 1 && socket.sentWithMethod("profiles.list").size == 8 }
        assertEquals(twelve, utf8Length(socket.sentWithMethod("file.attach").single()))
        assertEquals(0, client.queueSnapshot().attachment)
        assertTrue(attach.isActive) // still waiting for its reply
        client.disconnect()
    }

    @Test fun aLoneTwelveMebibyteAttachmentIsAcceptedOnAnEmptyQueue() = runBlocking {
        val (client, socket) = connected()
        socket.buffered = true
        request(client, "file.attach", GatewayClient.ATTACHMENT_FRAME_BYTES, maximum = GatewayClient.ATTACHMENT_FRAME_BYTES)
        eventually { client.queueSnapshot().attachment == GatewayClient.ATTACHMENT_FRAME_BYTES }
        client.disconnect()
    }

    @Test fun serverRepliesAreHeldToFourMebibytesAndAreIndependentOfTheOrdinaryQueue() = runBlocking {
        val (client, socket) = connected { client ->
            client.setServerRequestHandler("approval") { ServerResponse.Result(buildJsonObject { put("v", JsonPrimitive("r".repeat(900_000))) }) }
        }
        socket.buffered = true
        fill(client, 8, mebibyte) // the ordinary queue is full
        repeat(5) { socket.deliver(ScriptedGateway.requestLine("approval-$it", "approval", """{"session_id":"s"}""")) }
        val framesBefore = 8
        eventually { client.queueSnapshot().frames == framesBefore + 5 }
        val queued = client.queueSnapshot()
        assertTrue("At most four mebibytes of replies: ${queued.server}", queued.server <= 4 * mebibyte)
        assertTrue("The four that fit are really queued", queued.server >= 4 * 900_000)
        assertEquals("The ordinary queue was never touched by replies", 8 * mebibyte, queued.ordinary)

        socket.buffered = false
        eventually(30_000) { socket.sent.count { it.contains("\"approval-") } == 5 }
        val replies = socket.sent.filter { it.contains("\"id\":\"approval-") }.map { Json.parseToJsonElement(it).jsonObject }
        val errors = replies.filter { it.containsKey("error") }
        assertEquals("Four full replies and one constant 'queue is full' answer", 4, replies.count { it.containsKey("result") })
        assertEquals(1, errors.size)
        assertEquals("-32603", errors.single()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        assertEquals("Client response queue is full", errors.single()["error"]!!.jsonObject["message"]!!.jsonPrimitive.content)
        client.disconnect()
    }

    @Test fun theWriterSendsOneFrameAtATimeWhileTheSocketHoldsUnwrittenData() = runBlocking {
        val (client, socket) = connected()
        socket.stallAfterEachSend = true
        repeat(3) { request(client, "profiles.list", 200) }
        eventually { socket.sentWithMethod("profiles.list").size == 1 && client.queueSnapshot().frames == 2 }
        delay(150)
        assertEquals("No second frame while the first sits unwritten", 1, socket.sentWithMethod("profiles.list").size)
        socket.buffered = false
        eventually { socket.sentWithMethod("profiles.list").size == 2 }
        delay(100)
        assertEquals(2, socket.sentWithMethod("profiles.list").size)
        socket.buffered = false
        eventually { socket.sentWithMethod("profiles.list").size == 3 && client.queueSnapshot().frames == 0 }
        client.disconnect()
    }

    @Test fun aQueuedServerReplyCanStillBeCancelledWhileThePeerStalls() = runBlocking {
        val (client, socket) = connected { client ->
            client.setServerRequestHandler("approval") { ServerResponse.Result(JsonObject(emptyMap())) }
        }
        socket.buffered = true
        socket.deliver(ScriptedGateway.requestLine("stalled-1", "approval", """{"session_id":"s"}"""))
        eventually { client.queueSnapshot().server > 0 }
        socket.deliver(ScriptedGateway.eventLine("request.cancel", """{"id":"stalled-1","method":"approval","reason":"expired"}"""))
        eventually { client.queueSnapshot().server == 0 }
        socket.buffered = false
        delay(300)
        assertTrue("The cancelled reply never left", socket.sent.none { it.contains("stalled-1") })
        client.disconnect()
    }

    @Test fun aRequestCancelledBeforeItLeftIsNotSentAndSaysSo() = runBlocking {
        val (client, socket) = connected()
        socket.buffered = true
        var seen: Throwable? = null
        val call = scope.async {
            try {
                client.request("prompt.submit", params("text" to "hello"))
            } catch (e: CancellationException) {
                seen = e
                throw e
            }
        }
        eventually { client.queueSnapshot().frames == 1 }
        call.cancel()
        eventually { seen != null }
        assertEquals(DispatchOutcome.NotSent, (seen as RequestCancelledException).dispatch)
        eventually { client.queueSnapshot().frames == 0 }
        socket.buffered = false
        delay(300)
        assertTrue("A frame that never left is never sent", socket.sentWithMethod("prompt.submit").isEmpty())
        client.disconnect()
    }

    private fun params(vararg pairs: Pair<String, String>) = buildJsonObject { pairs.forEach { put(it.first, it.second) } }
}
