package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest
import okio.ByteString

/**
 * A scripted Hermes gateway on loopback: real HTTP upgrade and real WebSocket frames, answered by lambdas.
 * It is a test double for the client's transport rules; it is not Hermes.
 */
class ScriptedGateway(prefix: String = "") : AutoCloseable {
    val host = ScriptedHost(prefix)

    /** One accepted upgrade. */
    inner class Conn(val request: RecordedRequest, val index: Int) {
        val frames = LinkedBlockingQueue<String>()
        val allFrames = CopyOnWriteArrayList<String>()
        @Volatile lateinit var socket: WebSocket
        @Volatile var closedByClient = false
        @Volatile var closeCode: Int? = null
        @Volatile var readySentNanos = 0L
        @Volatile var firstFrameNanos = 0L

        fun send(text: String) { socket.send(text) }
        fun sendBinary(text: String) { socket.send(ByteString.of(*text.toByteArray())) }
        fun event(type: String, payload: String = "{}", session: String? = null, seq: Long? = null) {
            send(eventLine(type, payload, session, seq))
        }
        fun result(id: String, json: String = "{}") = send("""{"jsonrpc":"2.0","id":${quote(id)},"result":$json}""")
        fun failure(id: String, code: Long, message: String = "no", data: String? = null) =
            send("""{"jsonrpc":"2.0","id":${quote(id)},"error":{"code":$code,"message":${quote(message)}${data?.let { ",\"data\":$it" } ?: ""}}}""")
        fun close(code: Int = 1000) { socket.close(code, null) }
        /** The host ends the connection (a server-initiated close). */
        fun drop() { socket.close(1011, null) }

        fun nextFrame(timeoutMillis: Long = 5_000): JsonObject {
            val text = frames.poll(timeoutMillis, TimeUnit.MILLISECONDS) ?: throw AssertionError("No frame within ${timeoutMillis}ms on connection $index")
            return Json.parseToJsonElement(text).jsonObject
        }

        fun nextFrame(method: String, timeoutMillis: Long = 5_000): JsonObject {
            val frame = nextFrame(timeoutMillis)
            check(frame["method"]?.jsonPrimitive?.content == method) { "Expected $method but got ${frame["method"]}" }
            return frame
        }

        /** Discards frames until one matches; the handshake RPCs are answered automatically and queued too. */
        fun awaitFrame(timeoutMillis: Long = 5_000, predicate: (JsonObject) -> Boolean): JsonObject {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
            while (true) {
                val left = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                val frame = nextFrame(left.coerceAtLeast(1))
                if (predicate(frame)) return frame
            }
        }

        fun awaitMethod(method: String, timeoutMillis: Long = 5_000) =
            awaitFrame(timeoutMillis) { it["method"]?.jsonPrimitive?.content == method }

        fun framesWithMethod(method: String) = allFrames.map { Json.parseToJsonElement(it).jsonObject }
            .filter { it["method"]?.jsonPrimitive?.content == method }

        fun hasFrame(): Boolean = frames.isNotEmpty()
    }

    val connections = LinkedBlockingQueue<Conn>()
    val all = CopyOnWriteArrayList<Conn>()

    /** Global order of what the host saw: `"ws:<method>"`, `"http:<path>"`, `"upgrade"`. */
    val log = CopyOnWriteArrayList<String>()

    /** Called for every client frame on a connection (after it is queued). Default: answer the handshake RPCs. */
    @Volatile var responder: (Conn, JsonObject) -> Unit = { conn, frame -> defaultResponse(conn, frame) }
    @Volatile var readyPayload: String = """{"heartbeat":true,"replay_epoch":"epoch-1"}"""
    @Volatile var sendReady: Boolean = true
    @Volatile var readyDelayMillis: Long = 0
    @Volatile var capabilitiesResult: String = """{"per_session_exclusive_submit":true}"""
    @Volatile var healthBody: String = """{"ok":true,"auth_required":false}"""
    @Volatile var negotiatedSubprotocol: String? = null

    /** Connections after this many are refused (HTTP 503), to exhaust recovery. */
    @Volatile var acceptLimit: Int = Int.MAX_VALUE
    private val upgrades = AtomicInteger()
    private val tickets = AtomicInteger()
    val ticketRequests = CopyOnWriteArrayList<String>()

    init {
        host.on("GET", "/api/ws") { request ->
            log += "upgrade"
            if (upgrades.incrementAndGet() > acceptLimit) {
                MockResponse().setResponseCode(503)
            } else {
                val conn = Conn(request, all.size)
                all += conn
                val response = MockResponse().withWebSocketUpgrade(listener(conn))
                negotiatedSubprotocol?.let { response.setHeader("Sec-WebSocket-Protocol", it) }
                response
            }
        }
        host.on("GET", "/api/health") { log += "http:/api/health"; ScriptedHost.json(healthBody) }
        host.on("POST", "/api/auth/ws-ticket") { request ->
            log += "http:/api/auth/ws-ticket"
            ticketRequests += request.getHeader("Authorization").orEmpty()
            ScriptedHost.json("""{"ticket":"ticket_${tickets.incrementAndGet()}","ttl_seconds":30}""")
        }
    }

    private fun listener(conn: Conn) = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            conn.socket = webSocket
            connections.add(conn)
            if (sendReady) {
                if (readyDelayMillis > 0) {
                    Thread { Thread.sleep(readyDelayMillis); runCatching { conn.readySentNanos = System.nanoTime(); conn.event("gateway.ready", readyPayload) } }.start()
                } else {
                    conn.readySentNanos = System.nanoTime()
                    conn.event("gateway.ready", readyPayload)
                }
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val method = runCatching { Json.parseToJsonElement(text).jsonObject["method"]?.jsonPrimitive?.content }.getOrNull()
            log += "ws:$method"
            if (conn.firstFrameNanos == 0L) conn.firstFrameNanos = System.nanoTime()
            conn.frames.add(text)
            conn.allFrames.add(text)
            runCatching { responder(conn, Json.parseToJsonElement(text).jsonObject) }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            conn.closedByClient = true
            conn.closeCode = code
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            conn.closedByClient = true
            conn.closeCode = code
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            conn.closedByClient = true
        }
    }

    fun defaultResponse(conn: Conn, frame: JsonObject) {
        val id = frame["id"]?.jsonPrimitive?.content ?: return
        when (frame["method"]?.jsonPrimitive?.content) {
            "client.capabilities", "gateway.ping" -> conn.result(id)
            "gateway.capabilities" -> conn.result(id, capabilitiesResult)
        }
    }

    fun awaitConnection(timeoutMillis: Long = 5_000): Conn =
        connections.poll(timeoutMillis, TimeUnit.MILLISECONDS) ?: throw AssertionError("No gateway connection within ${timeoutMillis}ms")

    override fun close() {
        all.forEach { runCatching { it.socket.cancel() } }
        host.close()
    }

    companion object {
        fun quote(text: String): String = kotlinx.serialization.json.JsonPrimitive(text).toString()

        fun eventLine(type: String, payload: String = "{}", session: String? = null, seq: Long? = null) =
            """{"jsonrpc":"2.0","method":"event","params":{"type":${quote(type)},"payload":$payload${session?.let { ",\"session_id\":${quote(it)}" } ?: ""}${seq?.let { ",\"seq\":$it" } ?: ""}}}"""

        fun requestLine(id: String, method: String, params: String = "{}") =
            """{"jsonrpc":"2.0","id":${quote(id)},"method":${quote(method)},"params":$params}"""
    }
}
