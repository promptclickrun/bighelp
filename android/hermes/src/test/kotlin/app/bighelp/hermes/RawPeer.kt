package app.bighelp.hermes

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * A hand-written WebSocket peer on raw TCP: it builds frames byte by byte, so a test can send a frame header
 * with no payload, split a code point across fragments, put invalid bytes in a TEXT frame, or answer the
 * upgrade any way it likes. It also answers the few plain HTTP routes a connect needs. Test double only.
 */
class RawPeer : AutoCloseable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort
    val upgrades = LinkedBlockingQueue<Session>()
    val httpPaths = CopyOnWriteArrayList<String>()
    @Volatile var healthBody = """{"ok":true,"auth_required":false}"""
    @Volatile var capabilitiesResult = """{"per_session_exclusive_submit":true}"""
    private val tickets = java.util.concurrent.atomic.AtomicInteger()

    init {
        Thread({
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: IOException) { return@Thread }
                Thread({ serve(socket) }, "raw-peer-connection").also { it.isDaemon = true }.start()
            }
        }, "raw-peer-accept").also { it.isDaemon = true }.start()
    }

    private fun serve(socket: Socket) {
        try {
            socket.soTimeout = 10_000
            val head = readHead(socket) ?: return socket.close()
            val lines = head.split("\r\n")
            val path = lines[0].split(' ').getOrNull(1).orEmpty()
            val headers = lines.drop(1).filter { ':' in it }.associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
            if (headers["upgrade"].equals("websocket", ignoreCase = true) && path.startsWith("/api/ws")) {
                upgrades.add(Session(socket, head, lines[0], headers))
                return
            }
            httpPaths += path.substringBefore('?')
            val body = when (path.substringBefore('?')) {
                "/api/health" -> healthBody
                "/api/status" -> """{"auth_required":false}"""
                "/api/auth/ws-ticket" -> """{"ticket":"raw_ticket_${tickets.incrementAndGet()}","ttl_seconds":30}"""
                else -> null
            }
            val response = if (body == null) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            else "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body"
            socket.getOutputStream().write(response.toByteArray())
            socket.getOutputStream().flush()
            socket.close()
        } catch (_: IOException) {
            runCatching { socket.close() }
        }
    }

    private fun readHead(socket: Socket): String? {
        val buffer = ByteArrayOutputStream()
        val input = socket.getInputStream()
        while (buffer.size() < 65_536) {
            val b = input.read()
            if (b < 0) return null
            buffer.write(b)
            val bytes = buffer.toByteArray()
            if (bytes.size >= 4 && bytes[bytes.size - 4] == 13.toByte() && bytes[bytes.size - 3] == 10.toByte() &&
                bytes[bytes.size - 2] == 13.toByte() && bytes[bytes.size - 1] == 10.toByte()
            ) return String(bytes, Charsets.ISO_8859_1).removeSuffix("\r\n\r\n")
        }
        return null
    }

    fun awaitUpgrade(timeoutMillis: Long = 5_000): Session =
        upgrades.poll(timeoutMillis, TimeUnit.MILLISECONDS) ?: throw AssertionError("The client never asked to upgrade")

    override fun close() {
        runCatching { server.close() }
        upgrades.forEach { runCatching { it.socket.close() } }
    }

    /** A frame the client sent, unmasked. */
    class ClientFrame(val opcode: Int, val fin: Boolean, val payload: ByteArray) {
        val text: String get() = String(payload, Charsets.UTF_8)
    }

    inner class Session(val socket: Socket, val head: String, val requestLine: String, private val headers: Map<String, String>) {
        private val out = socket.getOutputStream()
        private val input = socket.getInputStream()
        val receivedMethods = CopyOnWriteArrayList<String>()
        val receivedFrames = LinkedBlockingQueue<ClientFrame>()
        @Volatile var clientClosed = false

        fun header(name: String): String? = headers[name.lowercase()]
        fun hasHeader(name: String) = headers.containsKey(name.lowercase())
        val path: String get() = requestLine.split(' ').getOrNull(1).orEmpty()

        // Upgrade answers

        fun accept(subprotocol: String? = null, extensions: String? = null, extraHeaders: List<String> = emptyList()) {
            val key = header("sec-websocket-key") ?: error("no key")
            val accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()))
            val reply = buildString {
                append("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n")
                subprotocol?.let { append("Sec-WebSocket-Protocol: $it\r\n") }
                extensions?.let { append("Sec-WebSocket-Extensions: $it\r\n") }
                extraHeaders.forEach { append("$it\r\n") }
                append("\r\n")
            }
            raw(reply.toByteArray())
        }

        fun rawText(text: String) = raw(text.toByteArray(Charsets.ISO_8859_1))

        fun raw(bytes: ByteArray) {
            out.write(bytes)
            out.flush()
        }

        // Frames (server to client: never masked)

        fun frame(opcode: Int, payload: ByteArray, fin: Boolean = true, rsv: Int = 0) = raw(frameHeader(opcode, payload.size.toLong(), fin, rsv) + payload)

        /** The header alone: the declared length with none of the payload. */
        fun frameHeaderOnly(opcode: Int, declaredLength: Long, fin: Boolean = true) = raw(frameHeader(opcode, declaredLength, fin, 0))

        fun text(text: String) = frame(0x1, text.toByteArray(Charsets.UTF_8))
        fun binary(bytes: ByteArray) = frame(0x2, bytes)
        fun event(type: String, payload: String = "{}", seq: Long? = null) = text(ScriptedGateway.eventLine(type, payload, null, seq))
        fun ready(payload: String = """{"heartbeat":true,"replay_epoch":"epoch-raw"}""") = event("gateway.ready", payload)
        fun result(id: String, json: String = "{}") = text("""{"jsonrpc":"2.0","id":${ScriptedGateway.quote(id)},"result":$json}""")

        // Client frames

        fun readFrame(timeoutMillis: Int = 3_000): ClientFrame? {
            socket.soTimeout = timeoutMillis
            return try {
                val b0 = input.read()
                if (b0 < 0) return null.also { clientClosed = true }
                val b1 = input.read()
                var length = (b1 and 0x7f).toLong()
                if (length == 126L) length = (input.read().toLong() shl 8) or input.read().toLong()
                else if (length == 127L) { length = 0; repeat(8) { length = (length shl 8) or input.read().toLong() } }
                val mask = if (b1 and 0x80 != 0) ByteArray(4).also { readFully(it) } else null
                val payload = ByteArray(length.toInt()).also { readFully(it) }
                if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                ClientFrame(b0 and 0x0f, b0 and 0x80 != 0, payload)
            } catch (_: SocketTimeoutException) {
                null
            } catch (_: IOException) {
                clientClosed = true
                null
            }
        }

        private fun readFully(target: ByteArray) {
            var read = 0
            while (read < target.size) {
                val n = input.read(target, read, target.size - read)
                if (n < 0) throw IOException("eof")
                read += n
            }
        }

        /**
         * Answers the connect sequence and records the rest, on a background thread, until the client goes away.
         * `client.capabilities` and `gateway.ping` get an empty result; `gateway.capabilities` the peer's result.
         */
        fun serve(answerPings: Boolean = true) {
            Thread({
                while (true) {
                    val frame = readFrame(60_000) ?: if (clientClosed) return@Thread else continue
                    if (frame.opcode == 0x8) { clientClosed = true; return@Thread }
                    receivedFrames.add(frame)
                    if (frame.opcode != 0x1) continue
                    val json = runCatching { Json.parseToJsonElement(frame.text).jsonObject }.getOrNull() ?: continue
                    val method = json["method"]?.jsonPrimitive?.content ?: continue
                    receivedMethods += method
                    val id = json["id"]?.jsonPrimitive?.content ?: continue
                    when (method) {
                        "client.capabilities" -> runCatching { result(id) }
                        "gateway.ping" -> if (answerPings) runCatching { result(id) }
                        "gateway.capabilities" -> runCatching { result(id, capabilitiesResult) }
                    }
                }
            }, "raw-peer-serve").also { it.isDaemon = true }.start()
        }

        /** True once the client closed the TCP connection or sent a close frame. */
        fun awaitClientGone(timeoutMillis: Long = 5_000): Boolean {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
            while (System.nanoTime() < deadline) {
                if (clientClosed) return true
                val frame = receivedFrames.poll(100, TimeUnit.MILLISECONDS)
                if (frame?.opcode == 0x8) return true
            }
            return clientClosed
        }

        fun close() = runCatching { socket.close() }
    }

    companion object {
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        fun frameHeader(opcode: Int, length: Long, fin: Boolean, rsv: Int): ByteArray {
            val first = ((if (fin) 0x80 else 0) or (rsv shl 4) or opcode).toByte()
            return when {
                length < 126 -> byteArrayOf(first, length.toByte())
                length <= 0xFFFF -> byteArrayOf(first, 126, (length shr 8).toByte(), length.toByte())
                else -> byteArrayOf(first, 127) + ByteArray(8) { (length shr (56 - 8 * it)).toByte() }
            }
        }
    }
}
