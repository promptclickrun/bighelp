package app.bighelp.hermes

import java.io.IOException
import java.net.InetAddress
import java.net.URI
import java.net.URISyntaxException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import org.java_websocket.WebSocketImpl
import org.java_websocket.client.DnsResolver
import org.java_websocket.client.WebSocketClient
import org.java_websocket.drafts.Draft
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.exceptions.InvalidHandshakeException
import org.java_websocket.extensions.IExtension
import org.java_websocket.framing.CloseFrame
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.handshake.Handshakedata
import org.java_websocket.handshake.ServerHandshake
import org.java_websocket.protocols.IProtocol
import org.java_websocket.protocols.Protocol

// The gateway's WebSocket I/O. OkHttp stays for bounded HTTP, but OkHttp 4.12 cannot give a WebSocket the
// two things this contract needs: it assembles a whole inbound message before delivering it (so a declared
// length cannot be refused up front) and it repairs malformed UTF-8 instead of rejecting it. Java-WebSocket
// 1.6.0 checks a frame's declared length before allocating, caps the sum of fragments, decodes TEXT strictly
// when a message completes, and turns on HTTPS hostname identification. Everything the library does not do is
// done here: bounded and typed upgrade responses, exact subprotocol negotiation, no extensions, UTF-8 header
// bytes, and no logging (see build.gradle.kts: SLF4J is bound to its no-op provider).

/** One gateway socket as [GatewayClient] sees it. */
internal interface GatewayTransport {
    /**
     * True while frames handed to [send] have not yet been taken by the socket's writer. The sender stops at
     * this signal, so a stalled peer backs the queue up in the sender's own bounded outbox, not in the library.
     */
    val hasBufferedData: Boolean

    /** Queues one TEXT frame in order; false when the socket is not open. */
    fun send(text: String): Boolean

    /** [orderly]: a close handshake. Otherwise the socket is dropped at once. Idempotent. */
    fun close(orderly: Boolean)
}

/** Callbacks of one socket, on its reader thread, in wire order. [failed] is the one terminal event. */
internal interface GatewayTransportListener {
    fun opened(negotiatedSubprotocol: String?)

    /** One whole message (a TEXT message is strict UTF-8, re-encoded; a BINARY message is the bytes as sent). */
    fun message(bytes: ByteArray)

    /** The socket ended for any reason: never called twice, never called after a deliberate [GatewayTransport.close]. */
    fun failed(error: HermesException)
}

internal fun interface GatewayTransportFactory {
    /** @throws HermesException if [request] cannot be sent as it is. Otherwise connecting continues in the background. */
    fun open(request: SocketRequest, listener: GatewayTransportListener): GatewayTransport
}

internal object GatewayWebSockets : GatewayTransportFactory {
    /** The largest inbound frame, and the largest sum of fragments: the contract's 4 MiB message. */
    const val MAXIMUM_MESSAGE_BYTES = HermesWire.MAXIMUM_MESSAGE_BYTES

    /** The upgrade response's header block, counted up to its blank line. */
    const val MAXIMUM_UPGRADE_HEADER_BYTES = 16_384

    private const val CONNECT_TIMEOUT_MILLIS = 20_000
    private const val PROTOCOL_HEADER = "Sec-WebSocket-Protocol"

    override fun open(request: SocketRequest, listener: GatewayTransportListener): GatewayTransport {
        val uri = try {
            URI(request.url)
        } catch (_: URISyntaxException) {
            throw HermesException(HermesException.Kind.InvalidEndpoint)
        }
        if (uri.scheme != "ws" && uri.scheme != "wss" || uri.host.isNullOrEmpty()) throw HermesException(HermesException.Kind.InvalidEndpoint)

        val headers = LinkedHashMap(request.headers)
        val offered = headers.keys.firstOrNull { it.equals(PROTOCOL_HEADER, ignoreCase = true) }
            ?.let { headers.remove(it) }
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        // Nothing may split the request line or header block, whatever the source of a header.
        for ((name, value) in headers) {
            if (name.isEmpty() || name.any { it.code <= 0x20 || it.code >= 0x7f || it == ':' } ||
                value.any { it == '\r' || it == '\n' || it == '\u0000' }
            ) throw HermesException(HermesException.Kind.InvalidAccessCredentials)
        }
        if (offered.any { protocol -> protocol.any { it.code <= 0x20 || it.code >= 0x7f || it == ',' } }) {
            throw HermesException(HermesException.Kind.InvalidEndpoint)
        }

        val observer = HandshakeObserver()
        // No extensions: the draft always adds RFC 6455's default one, and no permessage-deflate is configured.
        val protocols: List<IProtocol> = if (offered.isEmpty()) listOf(Protocol("")) else offered.map { Protocol(it) }
        val draft = GatewayDraft(protocols, observer)
        val client = SocketClient(uri, draft, headers, observer, listener, request.requiredSubprotocol)
        client.connect()
        return JavaWebSocketTransport(client)
    }
}

/** What the upgrade response said, noted before the library turns it into an exception message. */
private class HandshakeObserver {
    @Volatile var status: Int? = null
    @Volatile var headersTooLarge = false
}

/**
 * The library's RFC 6455 draft with the gateway's bounds: 4 MiB frames and fragment sums, upgrade response
 * headers capped (the library otherwise accumulates a never-ending header block without limit), the HTTP
 * status recorded so a 401, 403 or redirect keeps its type, and the request written as UTF-8 bytes so a proxy
 * header value with non-ASCII text arrives as sent (the library would write a question mark).
 */
private class GatewayDraft(
    protocols: List<IProtocol>,
    private val observer: HandshakeObserver,
) : Draft_6455(emptyList<IExtension>(), protocols, GatewayWebSockets.MAXIMUM_MESSAGE_BYTES) {

    override fun translateHandshake(buf: ByteBuffer): Handshakedata {
        val start = buf.position()
        val end = buf.limit()
        var terminator = -1
        var i = start
        while (i + 3 < end) {
            if (buf.get(i) == CR && buf.get(i + 1) == LF && buf.get(i + 2) == CR && buf.get(i + 3) == LF) {
                terminator = i
                break
            }
            i++
        }
        val headerBytes = if (terminator >= 0) terminator + 4 - start else end - start
        if (headerBytes > GatewayWebSockets.MAXIMUM_UPGRADE_HEADER_BYTES) {
            observer.headersTooLarge = true
            throw InvalidHandshakeException("Upgrade response headers are too large")
        }
        statusLine(buf, start, end)?.let { observer.status = it }
        return super.translateHandshake(buf)
    }

    /** The status code of an `HTTP/1.x NNN ...` first line, if the line is complete. */
    private fun statusLine(buf: ByteBuffer, start: Int, end: Int): Int? {
        var lineEnd = start
        while (lineEnd < end && lineEnd - start < 64 && buf.get(lineEnd) != CR && buf.get(lineEnd) != LF) lineEnd++
        if (lineEnd >= end) return null
        val line = ByteArray(lineEnd - start) { buf.get(start + it) }.toString(Charsets.ISO_8859_1)
        val parts = line.split(' ')
        return if (parts.size >= 2 && parts[0].startsWith("HTTP/")) parts[1].toIntOrNull() else null
    }

    override fun createHandshake(handshakedata: Handshakedata, withcontent: Boolean): List<ByteBuffer> {
        val request = handshakedata as? ClientHandshake ?: throw IllegalArgumentException("Client requests only")
        val text = StringBuilder("GET ").append(request.resourceDescriptor).append(" HTTP/1.1\r\n")
        val names = request.iterateHttpFields()
        while (names.hasNext()) {
            val name = names.next()
            text.append(name).append(": ").append(request.getFieldValue(name)).append("\r\n")
        }
        text.append("\r\n")
        return listOf(ByteBuffer.wrap(text.toString().toByteArray(Charsets.UTF_8)))
    }

    override fun copyInstance(): Draft = GatewayDraft(knownProtocols.map { it.copyInstance() }, observer)

    private companion object {
        const val CR: Byte = 13
        const val LF: Byte = 10
    }
}

private class SocketClient(
    uri: URI,
    draft: Draft,
    headers: Map<String, String>,
    private val observer: HandshakeObserver,
    private val listener: GatewayTransportListener,
    private val requiredSubprotocol: String?,
) : WebSocketClient(uri, draft, headers, 20_000) {
    private val ended = AtomicBoolean(false)
    @Volatile private var opened = false
    @Volatile private var firstError: Exception? = null

    init {
        setDaemon(true)
        // The RPC heartbeat is the only liveness check; the library's own ping timer is off.
        setConnectionLostTimeout(0)
        setTcpNoDelay(true)
        // Android's Socket.connect refuses an unresolved address, which is what the library uses by default.
        setDnsResolver(DnsResolver { target -> InetAddress.getByName(target.host) })
    }

    override fun onOpen(handshake: ServerHandshake) {
        val negotiated = handshake.getFieldValue("Sec-WebSocket-Protocol").ifEmpty { null }
        // Nothing was offered, so nothing may be accepted: an extension answer is a protocol violation, and
        // the default extension would otherwise take any answer.
        if (handshake.hasFieldValue("Sec-WebSocket-Extensions") ||
            (requiredSubprotocol != null && negotiated != requiredSubprotocol)
        ) {
            terminate(HermesException(HermesException.Kind.InvalidResponse))
            return
        }
        opened = true
        listener.opened(negotiated)
    }

    override fun onMessage(message: String) {
        if (!ended.get()) listener.message(message.toByteArray(Charsets.UTF_8))
    }

    override fun onMessage(bytes: ByteBuffer) {
        if (ended.get()) return
        val copy = ByteArray(bytes.remaining())
        bytes.duplicate().get(copy)
        listener.message(copy)
    }

    /** The library rejected something (size, UTF-8, framing) and is about to start a close handshake: end it now. */
    override fun onCloseInitiated(code: Int, reason: String?) {
        if (code != CloseFrame.NORMAL && code != CloseFrame.GOING_AWAY) terminate(map(code, remote = false))
    }

    override fun onClose(code: Int, reason: String?, remote: Boolean) {
        terminate(map(code, remote), closeConnection = false)
    }

    override fun onError(ex: Exception) {
        if (firstError == null) firstError = ex
    }

    /** After a deliberate close nothing more is reported: the owner already knows. */
    fun silence() {
        ended.set(true)
    }

    private fun terminate(error: HermesException, closeConnection: Boolean = true) {
        if (!ended.compareAndSet(false, true)) return
        listener.failed(error)
        // A rejected stream must not linger half-closed waiting for a peer that may never answer.
        if (!closeConnection) return
        try {
            (connection as? WebSocketImpl)?.closeConnection(CloseFrame.ABNORMAL_CLOSE, "")
        } catch (_: RuntimeException) {
            // already closed
        }
    }

    private fun map(code: Int, remote: Boolean): HermesException {
        if (!opened) {
            if (observer.headersTooLarge) return HermesException(HermesException.Kind.MessageTooLarge)
            observer.status?.let { status ->
                return HermesException(
                    when {
                        status == 401 || status == 403 -> HermesException.Kind.InvalidCredentials
                        status in 300..399 -> HermesException.Kind.RedirectRefused
                        status != 101 -> HermesException.Kind.ConnectionFailed
                        else -> HermesException.Kind.InvalidResponse
                    },
                )
            }
            firstError?.let { return OkHttpHermesHttp.map(it) }
            return HermesException(
                if (code == CloseFrame.PROTOCOL_ERROR) HermesException.Kind.InvalidResponse else HermesException.Kind.ConnectionFailed,
            )
        }
        // 1006 is the library's word for "the connection went away", not for a rule that was broken.
        if (remote || code == CloseFrame.ABNORMAL_CLOSE) return HermesException(HermesException.Kind.Disconnected)
        return HermesException(if (code == CloseFrame.TOOBIG) HermesException.Kind.MessageTooLarge else HermesException.Kind.InvalidResponse)
    }
}

private class JavaWebSocketTransport(private val client: SocketClient) : GatewayTransport {
    override val hasBufferedData: Boolean get() = client.hasBufferedData()

    override fun send(text: String): Boolean = try {
        client.send(text)
        true
    } catch (_: RuntimeException) {
        false
    }

    override fun close(orderly: Boolean) {
        client.silence()
        try {
            if (orderly) {
                client.close()
            } else {
                (client.connection as? WebSocketImpl)?.closeConnection(CloseFrame.ABNORMAL_CLOSE, "")
                client.socket?.close()
            }
        } catch (_: RuntimeException) {
            // already closed
        } catch (_: IOException) {
            // already closed
        }
    }
}
