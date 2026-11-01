package app.bighelp.hermes

import java.io.ByteArrayOutputStream
import java.io.PrintStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.java_websocket.drafts.Draft_6455
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout
import org.slf4j.LoggerFactory

/**
 * The WebSocket library logs frames and handshakes at trace level and errors with their exceptions. SLF4J is
 * bound to its no-op provider, so none of that can reach a log, whatever a frame or the socket URL (which
 * carries a dashboard token) contains.
 */
class GatewayLoggingTest {
    @get:Rule val testTimeout: Timeout = Timeout.seconds(60)

    @Test fun theBoundSlf4jProviderIsTheNoOpOneAndNoLevelIsEnabled() {
        assertEquals("org.slf4j.helpers.NOPLoggerFactory", LoggerFactory.getILoggerFactory().javaClass.name)
        val library = LoggerFactory.getLogger(Draft_6455::class.java)
        assertFalse(library.isTraceEnabled || library.isDebugEnabled || library.isInfoEnabled || library.isWarnEnabled || library.isErrorEnabled)
    }

    @Test fun aWholeSocketLifeWithTokensAndRejectedFramesWritesNothingToTheProcessOutput() {
        val outBytes = ByteArrayOutputStream()
        val errBytes = ByteArrayOutputStream()
        val originalOut = System.out
        val originalErr = System.err
        System.setOut(PrintStream(outBytes, true))
        System.setErr(PrintStream(errBytes, true))
        val peer = RawPeer()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val endpoint = HermesEndpoint.parse("http://127.0.0.1:${peer.port}", allowPrivateHttp = true)
            val authenticator = HermesAuthenticator(endpoint, OkHttpHermesHttp(endpoint), InMemoryCredentialStore())
            authenticator.adoptForTest(SavedConnection(endpoint, StoredAuth.DashboardSession("secret-dashboard-token", false), null, null), false)
            val client = GatewayClient(
                authenticator, scope,
                GatewayTimings(readyMillis = 3_000, requestMillis = 3_000, heartbeatMillis = 60_000, pingMillis = 60_000, reconnectDelaysMillis = emptyList()),
            )
            val connecting = scope.async { client.connect() }
            val session = peer.awaitUpgrade()
            session.accept()
            session.ready()
            session.serve()
            runBlocking { connecting.await() }
            session.frame(0x1, byteArrayOf('{'.code.toByte(), 0xFF.toByte(), '}'.code.toByte())) // rejected: malformed UTF-8
            session.frameHeaderOnly(0x1, 1L shl 40)                                              // and an oversized one, after
            Thread.sleep(500)
            runBlocking { client.disconnect() }
            authenticator.close()
        } finally {
            System.setOut(originalOut)
            System.setErr(originalErr)
            scope.cancel()
            peer.close()
        }
        val output = outBytes.toString() + errBytes.toString()
        assertTrue("Nothing at all was written: <$output>", output.isEmpty())
    }
}
