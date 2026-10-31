package app.bighelp.hermes

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * The device-local half of browser sign-in. It binds `127.0.0.1` on an OS-chosen port **before** the
 * browser is opened, and only a validated HTTP request received here supplies the one-use code: browser
 * completion URLs are never consulted and no browser cookie is read. There is no custom URL scheme.
 *
 * Bad requests (a favicon, a stray probe, a wrong path or state, a slow client) close their own connection
 * without consuming the sign-in. At most four connections are served at once, each has
 * [AuthTimings.callbackRequestMillis] to deliver its request, and the whole wait is bounded by
 * [AuthTimings.browserSignInMillis]. After the code is captured every other connection is closed, a static
 * no-store page is flushed (within [AuthTimings.callbackResponseFlushMillis]), and the code is delivered once.
 */
internal class LoopbackCallbackListener private constructor(
    private val server: ServerSocket,
    private val path: String,
    private val state: String,
    private val timings: AuthTimings,
) : AutoCloseable {
    val port: Int = server.localPort
    val callbackUrl: String = "http://127.0.0.1:$port$path"
    val boundAddress: String get() = server.inetAddress.hostAddress.orEmpty()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val result = CompletableDeferred<String>()
    private val connections = ConcurrentHashMap.newKeySet<Socket>()
    private val captured = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    init {
        scope.launch { acceptLoop() }
    }

    /**
     * Runs [open] (the browser launch) while waiting for the validated code. A launch that fails before
     * any code arrived ends the wait with [HermesException.Kind.BrowserAuthenticationUnavailable]; one that
     * fails or is cancelled later cannot erase a captured code. Returns the code after the success page
     * has been flushed.
     */
    suspend fun awaitCode(open: suspend () -> Unit): String {
        try {
            return coroutineScope {
                val opener = launch {
                    try {
                        open()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        if (!captured.get()) result.completeExceptionally(HermesException(HermesException.Kind.BrowserAuthenticationUnavailable))
                    }
                }
                try {
                    withTimeout(timings.browserSignInMillis) { result.await() }
                } catch (_: TimeoutCancellationException) {
                    throw HermesException(HermesException.Kind.TimedOut)
                } finally {
                    opener.cancel()
                }
            }
        } finally {
            close()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        result.completeExceptionally(HermesException(HermesException.Kind.Cancelled))
        closeQuietly(server)
        connections.forEach(::closeQuietly)
        scope.cancel()
    }

    private fun acceptLoop() {
        while (!closed.get() && !captured.get()) {
            val socket = try {
                server.accept()
            } catch (_: IOException) {
                return
            }
            if (captured.get() || connections.size >= MAXIMUM_CONNECTIONS) {
                closeQuietly(socket)
                continue
            }
            connections.add(socket)
            scope.launch { handle(socket) }
        }
    }

    private suspend fun handle(socket: Socket) {
        val deadline = scope.launch { delay(timings.callbackRequestMillis); closeQuietly(socket) }
        try {
            socket.soTimeout = timings.callbackRequestMillis.toInt()
            val request = readRequest(socket) ?: return
            val code = try {
                validate(request, port, path, state)
            } catch (_: HermesException) {
                return
            }
            if (!captured.compareAndSet(false, true)) return
            deadline.cancel()
            // Other readers stop; a static page is flushed before the code is handed over.
            connections.filter { it !== socket }.forEach(::closeQuietly)
            closeQuietly(server)
            val flushDeadline = scope.launch { delay(timings.callbackResponseFlushMillis); closeQuietly(socket) }
            try {
                socket.getOutputStream().apply { write(SUCCESS_RESPONSE); flush() }
                socket.shutdownOutput()
            } catch (_: IOException) {
                // The code is already ours; a browser that went away early changes nothing.
            }
            flushDeadline.cancel()
            result.complete(code)
        } catch (_: IOException) {
            // A reset or timed-out connection never consumes the sign-in.
        } finally {
            deadline.cancel()
            connections.remove(socket)
            closeQuietly(socket)
        }
    }

    /** Reads up to the header terminator; refuses oversize input and anything after the terminator. */
    private fun readRequest(socket: Socket): ByteArray? {
        val input = socket.getInputStream()
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(4_096)
        while (true) {
            val count = input.read(chunk)
            if (count <= 0 || count > MAXIMUM_REQUEST_BYTES - buffer.size()) return null
            buffer.write(chunk, 0, count)
            val bytes = buffer.toByteArray()
            val end = indexOfTerminator(bytes)
            if (end >= 0) return if (end + 4 == bytes.size) bytes else null
        }
    }

    companion object {
        const val MAXIMUM_REQUEST_BYTES = 16_384
        private const val MAXIMUM_CONNECTIONS = 4
        private const val MAXIMUM_TOKEN_BYTES = 4_096

        private val SUCCESS_RESPONSE: ByteArray = run {
            val body = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><title>bighelp</title>" +
                "<p>Sign-in received. Return to bighelp.</p>"
            ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.toByteArray().size}\r\n" +
                "Cache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\n" +
                "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\n" +
                "Connection: close\r\n\r\n$body").toByteArray(Charsets.US_ASCII)
        }

        /** Binds `127.0.0.1` on an OS-chosen port; never a wildcard address. */
        fun bind(callbackPath: String, state: String, timings: AuthTimings): LoopbackCallbackListener {
            require(isValidPath(callbackPath) && isUrlToken(state)) { "Invalid callback" }
            val server = try {
                ServerSocket(0, 4, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            } catch (_: IOException) {
                throw HermesException(HermesException.Kind.BrowserAuthenticationUnavailable)
            }
            return LoopbackCallbackListener(server, callbackPath, state, timings)
        }

        /**
         * Exactly one `GET <path>?state=<state>&code=<code> HTTP/1.1` with strict CRLF framing, the exact
         * `Host: 127.0.0.1:<port>`, unique headers, no body or upgrade, and two token-valued query fields.
         * @return the code
         * @throws HermesException InvalidResponse (or MessageTooLarge) for anything else.
         */
        fun validate(request: ByteArray, port: Int, path: String, state: String): String {
            fun invalid(): Nothing = throw HermesException(HermesException.Kind.InvalidResponse)
            if (request.size > MAXIMUM_REQUEST_BYTES) throw HermesException(HermesException.Kind.MessageTooLarge)
            if (!request.all { val b = it.toInt() and 0xff; b in 32..126 || b == 9 || b == 10 || b == 13 }) invalid()
            val text = String(request, Charsets.US_ASCII)
            if (!text.endsWith("\r\n\r\n")) invalid()
            val lines = text.split("\r\n")
            if (lines.size !in 4..68 || lines.takeLast(2).any { it.isNotEmpty() } ||
                lines.dropLast(2).any { it.isEmpty() || '\r' in it || '\n' in it }
            ) invalid()
            val requestLine = lines[0].split(' ')
            if (requestLine.size != 3 || requestLine[0] != "GET" || requestLine[2] != "HTTP/1.1") invalid()

            val headers = HashMap<String, String>()
            for (line in lines.subList(1, lines.size - 2)) {
                val colon = line.indexOf(':')
                if (colon < 0) invalid()
                val name = line.substring(0, colon)
                if (name.isEmpty() || !name.all(::isHeaderToken)) invalid()
                if (headers.putIfAbsent(name.lowercase(), line.substring(colon + 1).trim(' ', '\t')) != null) invalid()
            }
            if (headers["host"] != "127.0.0.1:$port" || "transfer-encoding" in headers || "expect" in headers ||
                "upgrade" in headers || "trailer" in headers || headers["content-length"]?.let { it != "0" } == true
            ) invalid()

            val target = requestLine[1].split('?')
            if (target.size != 2 || target[0] != path) invalid()
            val fields = target[1].split('&')
            if (fields.size != 2) invalid()
            val query = HashMap<String, String>()
            for (field in fields) {
                val pair = field.split('=')
                if (pair.size != 2) invalid()
                val key = decodeToken(pair[0])
                val value = decodeToken(pair[1])
                if ((key != "state" && key != "code") || query.put(key, value) != null) invalid()
            }
            val code = query["code"]
            if (code == null || !MessageDigest.isEqual((query["state"] ?: invalid()).toByteArray(), state.toByteArray())) invalid()
            return code
        }

        /** Strict percent-decoding: `+` is not a space, and every decoded byte must be a URL-safe token character. */
        private fun decodeToken(encoded: String): String {
            val result = StringBuilder()
            var index = 0
            while (index < encoded.length) {
                val byte: Int
                if (encoded[index] == '%') {
                    if (index + 2 >= encoded.length) throw HermesException(HermesException.Kind.InvalidResponse)
                    val high = Character.digit(encoded[index + 1], 16)
                    val low = Character.digit(encoded[index + 2], 16)
                    if (high < 0 || low < 0) throw HermesException(HermesException.Kind.InvalidResponse)
                    byte = high * 16 + low
                    index += 3
                } else {
                    byte = encoded[index].code
                    index += 1
                }
                if (byte > 0x7f || !isUrlToken(byte.toChar()) || result.length >= MAXIMUM_TOKEN_BYTES) {
                    throw HermesException(HermesException.Kind.InvalidResponse)
                }
                result.append(byte.toChar())
            }
            if (result.isEmpty()) throw HermesException(HermesException.Kind.InvalidResponse)
            return result.toString()
        }

        private fun isUrlToken(c: Char) = c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_'
        private fun isUrlToken(text: String) = text.isNotEmpty() && text.length <= MAXIMUM_TOKEN_BYTES && text.all(::isUrlToken)
        private fun isHeaderToken(c: Char) = isUrlToken(c) || c in "!#$%&'*+.^`|~"

        private fun isValidPath(path: String) = path.startsWith("/") && !path.startsWith("//") && path.length <= 1_024 &&
            "//" !in path && path.all { isUrlToken(it) || it == '/' || it == '.' } &&
            path.split('/').none { it == "." || it == ".." }

        private fun indexOfTerminator(bytes: ByteArray): Int {
            for (i in 0..bytes.size - 4) {
                if (bytes[i] == 13.toByte() && bytes[i + 1] == 10.toByte() && bytes[i + 2] == 13.toByte() && bytes[i + 3] == 10.toByte()) return i
            }
            return -1
        }

        private fun closeQuietly(socket: Socket) {
            try { socket.close() } catch (_: IOException) { }
        }

        private fun closeQuietly(server: ServerSocket) {
            try { server.close() } catch (_: IOException) { }
        }
    }
}
