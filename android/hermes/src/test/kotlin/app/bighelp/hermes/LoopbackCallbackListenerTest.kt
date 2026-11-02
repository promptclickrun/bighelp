package app.bighelp.hermes

import java.net.ConnectException
import java.net.InetAddress
import java.net.Socket
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The device-local loopback callback of browser sign-in: strict single-request validation on a real socket. */
class LoopbackCallbackListenerTest {
    private val path = "/loopdy-native-callback/rnd_Path-1"
    private val state = "state_1-Z"
    private val listeners = mutableListOf<LoopbackCallbackListener>()

    @After fun stop() = listeners.forEach { it.close() }

    private fun bind(timings: AuthTimings = AuthTimings(callbackRequestMillis = 400)) =
        LoopbackCallbackListener.bind(path, state, timings).also { listeners += it }

    private fun request(port: Int, target: String = "$path?state=$state&code=code-1", host: String? = "127.0.0.1:$port", vararg extra: String, method: String = "GET", version: String = "HTTP/1.1") =
        buildString {
            append("$method $target $version\r\n")
            if (host != null) append("Host: $host\r\n")
            extra.forEach { append("$it\r\n") }
            append("\r\n")
        }

    /** Sends raw bytes and returns what came back: empty when the listener closed without an answer. */
    private fun exchange(port: Int, raw: String, waitMillis: Int = 2_000): String = try {
        Socket(InetAddress.getByName("127.0.0.1"), port).use { socket ->
            socket.soTimeout = waitMillis
            socket.getOutputStream().apply { write(raw.toByteArray()); flush() }
            socket.getInputStream().readBytes().toString(Charsets.US_ASCII)
        }
    } catch (_: java.net.SocketException) {
        "" // reset or closed by the listener
    } catch (_: java.net.SocketTimeoutException) {
        "<timeout>"
    }

    private fun validate(raw: String, port: Int = 4242) = LoopbackCallbackListener.validate(raw.toByteArray(), port, path, state)
    private fun refused(raw: String, port: Int = 4242) = assertThrows(raw, HermesException::class.java) { validate(raw, port) }.kind

    // Pure validation

    @Test fun aWellFormedCallbackYieldsTheCodeWithEitherFieldOrder() {
        assertEquals("code-1", validate(request(4242)))
        assertEquals("code-1", validate(request(4242, "$path?code=code-1&state=$state")))
        assertEquals("Content-Length 0 and ordinary headers are fine", "code-1",
            validate(request(4242, extra = arrayOf("Content-Length: 0", "User-Agent: Mozilla/5.0", "Accept: text/html"))))
        assertEquals("Percent-encoded token characters decode strictly", "a-b_C", validate(request(4242, "$path?state=$state&code=a%2Db%5FC")))
        assertEquals("c".repeat(4_096), validate(request(4242, "$path?state=$state&code=${"c".repeat(4_096)}")))
    }

    @Test fun everyDeviationIsRefused() {
        val invalid = HermesException.Kind.InvalidResponse
        fun bad(raw: String) = assertEquals(raw.take(80), invalid, refused(raw))
        bad(request(4242, "/other?state=$state&code=c"))
        bad(request(4242, "$path/x?state=$state&code=c"))
        bad(request(4242, "$path?state=WRONG&code=c"))
        bad(request(4242, "$path?state=$state&code=c&x=1"))
        bad(request(4242, "$path?state=$state"))
        bad(request(4242, "$path?state=$state&state=$state"))
        bad(request(4242, "$path?state=$state&code=a&code=b"))
        bad(request(4242, "$path?state=$state&code="))
        bad(request(4242, "$path?state=$state&code=a b"))
        bad(request(4242, "$path?state=$state&code=a+b"))
        bad(request(4242, "$path?state=$state&code=a.b"))
        bad(request(4242, "$path?state=$state&code=a%2Bb"))
        bad(request(4242, "$path?state=$state&code=a%2"))
        bad(request(4242, "$path?state=$state&code=a%zz"))
        bad(request(4242, "$path?state=$state&code=${"c".repeat(4_097)}"))
        bad(request(4242, "$path?state=$state&code=a?b"))
        bad(request(4242, "$path?state=$state&code"))
        bad(request(4242, "$path"))
        bad(request(4242, "$path?"))
        bad(request(4242, "$path#frag?state=$state&code=c"))
        bad(request(4242, method = "POST"))
        bad(request(4242, method = "HEAD"))
        bad(request(4242, method = "get"))
        bad(request(4242, version = "HTTP/1.0"))
        bad(request(4242, host = "localhost:4242"))
        bad(request(4242, host = "127.0.0.1:4243"))
        bad(request(4242, host = "127.0.0.1"))
        bad(request(4242, host = null))
        bad(request(4242, extra = arrayOf("Host: 127.0.0.1:4242")))
        bad(request(4242, extra = arrayOf("host: 127.0.0.1:4242")))
        bad(request(4242, extra = arrayOf("Transfer-Encoding: chunked")))
        bad(request(4242, extra = arrayOf("Expect: 100-continue")))
        bad(request(4242, extra = arrayOf("Upgrade: websocket")))
        bad(request(4242, extra = arrayOf("Trailer: X")))
        bad(request(4242, extra = arrayOf("Content-Length: 5")))
        bad(request(4242, extra = arrayOf(" folded: continuation")))
        bad(request(4242, extra = arrayOf("Bad Name: v")))
        bad(request(4242, extra = arrayOf("NoColon")))
        bad(request(4242, extra = arrayOf("")))
        bad("GET $path?state=$state&code=c HTTP/1.1\nHost: 127.0.0.1:4242\n\n")
        bad("GET $path?state=$state&code=c HTTP/1.1\r\nHost: 127.0.0.1:4242\r\n\r\nGET / HTTP/1.1\r\n\r\n")
        bad("GET $path?state=$state&code=c HTTP/1.1  \r\nHost: 127.0.0.1:4242\r\n\r\n")
        bad("GET  $path?state=$state&code=c HTTP/1.1\r\nHost: 127.0.0.1:4242\r\n\r\n")
        bad("GET $path?state=é&code=c HTTP/1.1\r\nHost: 127.0.0.1:4242\r\n\r\n")
        bad(request(4242, extra = arrayOf("X: a\u0001b")))
        assertEquals(HermesException.Kind.MessageTooLarge, refused(request(4242, extra = arrayOf("X: ${"v".repeat(16_400)}"))))
        // 4–68 lines in total including the final two empty ones.
        validate(request(4242, extra = Array(64) { "X-H$it: v" }))
        bad(request(4242, extra = Array(66) { "X-H$it: v" }))
    }

    // Real socket

    @Test fun itListensOnlyOnLoopbackAtAnOsChosenPortAndSuppliesAnExactCallbackUrl() {
        val listener = bind()
        assertTrue(listener.port in 1024..65_535)
        assertEquals("http://127.0.0.1:${listener.port}$path", listener.callbackUrl)
        assertEquals("127.0.0.1", listener.boundAddress)
        assertTrue("Two sign-ins never share a port", bind().port != listener.port)
    }

    @Test fun aValidRequestIsAnsweredWithAStaticNoStorePageAndDeliversTheCodeOnce() = runBlocking {
        val listener = bind()
        val waiting = async { listener.awaitCode { } }
        val reply = exchange(listener.port, request(listener.port, "$path?state=$state&code=secret-code-9"))
        assertEquals("secret-code-9", withTimeout(5_000) { waiting.await() })
        assertTrue(reply.startsWith("HTTP/1.1 200 OK\r\n"))
        listOf("Cache-Control: no-store", "Pragma: no-cache", "Referrer-Policy: no-referrer", "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'", "Connection: close", "Content-Type: text/html; charset=utf-8")
            .forEach { assertTrue(it, it in reply) }
        assertFalse("The page never reflects the code or state", "secret-code-9" in reply || state in reply)
        val body = reply.substringAfter("\r\n\r\n")
        assertEquals(body.length, Regex("Content-Length: (\\d+)").find(reply)!!.groupValues[1].toInt())
        assertTrue("Sign-in received" in body)
    }

    @Test fun badRequestsCloseWithoutConsumingTheSignIn() = runBlocking {
        val listener = bind()
        val waiting = async { listener.awaitCode { } }
        listOf(
            request(listener.port, "/favicon.ico"),
            request(listener.port, "$path?state=WRONG&code=c"),
            request(listener.port, method = "POST"),
            request(listener.port, host = "evil.example"),
            request(listener.port, extra = arrayOf("Transfer-Encoding: chunked")),
            "garbage\r\n\r\n",
        ).forEach { assertEquals("No answer for ${it.take(40)}", "", exchange(listener.port, it)) }
        assertFalse("Still waiting for the real callback", waiting.isCompleted)
        exchange(listener.port, request(listener.port, "$path?state=$state&code=real"))
        assertEquals("real", withTimeout(5_000) { waiting.await() })
    }

    @Test fun anOversizeOrIncompleteOrSlowRequestIsClosedWithoutAnAnswer() = runBlocking {
        val listener = bind(AuthTimings(callbackRequestMillis = 300))
        val waiting = async { listener.awaitCode { } }
        assertEquals("", exchange(listener.port, "GET /x HTTP/1.1\r\nX: ${"v".repeat(17_000)}\r\n\r\n"))
        val started = System.nanoTime()
        assertEquals("A request that never finishes is dropped at the deadline", "", exchange(listener.port, "GET $path?state=$state&code=c HTTP/1.1\r\nHost: 127.0.0.1:${listener.port}\r\n"))
        assertTrue("Dropped near 300 ms, not the client's 2 s wait", System.nanoTime() - started < 1_500_000_000)
        assertFalse(waiting.isCompleted)
        exchange(listener.port, request(listener.port))
        assertEquals("code-1", withTimeout(5_000) { waiting.await() })
    }

    @Test fun atMostFourConnectionsAreServedAtOnce() = runBlocking {
        val listener = bind(AuthTimings(callbackRequestMillis = 1_500))
        val waiting = async { listener.awaitCode { } }
        val idle = List(4) { Socket(InetAddress.getByName("127.0.0.1"), listener.port) }
        delay(100)
        val fifth = Socket(InetAddress.getByName("127.0.0.1"), listener.port).apply { soTimeout = 1_000 }
        assertEquals("The fifth is closed at once", -1, runCatching { fifth.getInputStream().read() }.getOrDefault(-1))
        fifth.close()
        idle.forEach { it.close() }
        delay(150)
        exchange(listener.port, request(listener.port))
        assertEquals("code-1", withTimeout(5_000) { waiting.await() })
    }

    @Test fun onceTheCodeIsCapturedLaterRequestsAreIgnoredAndTheCodeIsDeliveredExactlyOnce() = runBlocking {
        val listener = bind()
        val waiting = async { listener.awaitCode { } }
        exchange(listener.port, request(listener.port, "$path?state=$state&code=first"))
        assertEquals("first", withTimeout(5_000) { waiting.await() })
        val second = runCatching { exchange(listener.port, request(listener.port, "$path?state=$state&code=second")) }
        assertTrue("Nothing answers a second callback: ${second.getOrNull()}", second.isFailure || second.getOrNull() == "")
    }

    @Test fun closingStopsListeningAndCancellingTheWaiterClosesThePort() = runBlocking {
        val listener = bind()
        val port = listener.port
        val waiting = async { listener.awaitCode { } }
        delay(50)
        waiting.cancel()
        assertThrows(CancellationException::class.java) { runBlocking { waiting.await() } }
        listener.close()
        listener.close() // idempotent
        assertThrows(ConnectException::class.java) { Socket(InetAddress.getByName("127.0.0.1"), port).close() }
        Unit
    }

    @Test fun theWholeSignInHasADeadlineThatClosesTheListener() = runBlocking {
        val listener = bind(AuthTimings(browserSignInMillis = 250))
        val port = listener.port
        val failure = assertThrows(HermesException::class.java) { runBlocking { listener.awaitCode { } } }
        assertEquals(HermesException.Kind.TimedOut, failure.kind)
        listener.close()
        assertThrows(ConnectException::class.java) { Socket(InetAddress.getByName("127.0.0.1"), port).close() }
        Unit
    }

    @Test fun aBrowserThatCannotOpenFailsTheWaitUnlessACodeWasAlreadyCaptured() = runBlocking {
        val failing = bind()
        assertEquals(
            HermesException.Kind.BrowserAuthenticationUnavailable,
            assertThrows(HermesException::class.java) { runBlocking { failing.awaitCode { throw IllegalStateException("no browser /secret") } } }.kind,
        )
        val late = bind()
        val code = late.awaitCode {
            exchange(late.port, request(late.port, "$path?state=$state&code=kept"))
            delay(50)
            throw IllegalStateException("the tab was dismissed afterwards")
        }
        assertEquals("A late browser cancellation never erases a captured code", "kept", code)
    }
}
