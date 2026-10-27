package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * An in-memory gateway socket whose "unwritten data" flag the test controls, so sender backpressure is
 * deterministic: no kernel buffer sizes, no timing. It answers the connect sequence and records every frame.
 */
internal class FakeTransports : GatewayTransportFactory {
    private val replies = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fake-transport").also { it.isDaemon = true } }
    @Volatile var current: Fake? = null

    inner class Fake(val listener: GatewayTransportListener) : GatewayTransport {
        val sent = CopyOnWriteArrayList<String>()
        @Volatile var buffered = false

        /** When true every frame leaves the socket "unwritten" until the test lets it drain. */
        @Volatile var stallAfterEachSend = false
        @Volatile var closed = false

        /** How often the sender asked whether the socket had taken its data (a stalled writer must not spin). */
        val bufferedReads = java.util.concurrent.atomic.AtomicLong()

        override val hasBufferedData: Boolean get() { bufferedReads.incrementAndGet(); return buffered }

        override fun send(text: String): Boolean {
            if (closed) return false
            sent += text
            if (stallAfterEachSend) buffered = true
            val json = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return true
            val id = json["id"]?.jsonPrimitive?.content ?: return true
            val result = when (json["method"]?.jsonPrimitive?.content) {
                "client.capabilities", "gateway.ping" -> "{}"
                "gateway.capabilities" -> """{"per_session_exclusive_submit":true}"""
                else -> return true
            }
            deliver("""{"jsonrpc":"2.0","id":${ScriptedGateway.quote(id)},"result":$result}""")
            return true
        }

        override fun close(orderly: Boolean) { closed = true }

        /** Delivers a line as if the host sent it, from another thread (the reader thread of a real socket). */
        fun deliver(line: String) {
            replies.execute { runCatching { listener.message(line.toByteArray(Charsets.UTF_8)) } }
        }

        fun methods(): List<String> = sent.mapNotNull { runCatching { Json.parseToJsonElement(it).jsonObject["method"]?.jsonPrimitive?.content }.getOrNull() }
        fun sentWithMethod(method: String) = sent.filter { it.contains("\"method\":\"$method\"") }
    }

    override fun open(request: SocketRequest, listener: GatewayTransportListener): GatewayTransport {
        val fake = Fake(listener)
        current = fake
        replies.execute {
            listener.opened(null)
            listener.message(ScriptedGateway.eventLine("gateway.ready", """{"heartbeat":false}""").toByteArray())
        }
        return fake
    }
}
