package app.bighelp.hermes

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout

/**
 * Real TLS to the gateway socket. The platform default trust is used and nothing is relaxed: a certificate
 * that chains to the trusted root but names another host, and one that chains to nothing trusted, both fail
 * as TLS errors before any WebSocket byte is read. The only thing the test changes is which root the
 * *default* SSL context trusts (a test authority), the way a device trusts its certificate authorities.
 */
class GatewayTransportTlsTest {
    @get:Rule val testTimeout: Timeout = Timeout.seconds(60)

    private val root = HeldCertificate.Builder().certificateAuthority(0).commonName("Bighelp Test Root").build()
    private val servers = mutableListOf<MockWebServer>()
    private val transports = mutableListOf<GatewayTransport>()
    private var originalContext: SSLContext? = null

    private class Recorder : GatewayTransportListener {
        val opened = LinkedBlockingQueue<String>()
        val messages = LinkedBlockingQueue<String>()
        val failures = CopyOnWriteArrayList<HermesException>()
        val failed = LinkedBlockingQueue<HermesException>()
        override fun opened(negotiatedSubprotocol: String?) { opened.add(negotiatedSubprotocol.orEmpty()) }
        override fun message(bytes: ByteArray) { messages.add(String(bytes, Charsets.UTF_8)) }
        override fun failed(error: HermesException) { failures += error; failed.add(error) }
    }

    @Before fun trustOnlyTheTestRoot() {
        originalContext = SSLContext.getDefault()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(root.certificate).build()
        SSLContext.setDefault(SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust.trustManager), null) })
    }

    @After fun restore() {
        transports.forEach { runCatching { it.close(orderly = false) } }
        servers.forEach { runCatching { it.shutdown() } }
        SSLContext.setDefault(originalContext)
    }

    private fun tlsServer(certificate: HeldCertificate, greeting: String = "hello over tls"): MockWebServer {
        val identity = HandshakeCertificates.Builder().heldCertificate(certificate, root.certificate).build()
        return MockWebServer().also {
            it.useHttps(identity.sslSocketFactory(), false)
            it.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { webSocket.send(greeting) }
            }))
            it.start()
            servers += it
        }
    }

    private fun certificate(vararg names: String, signedByRoot: Boolean = true) =
        HeldCertificate.Builder().apply {
            names.forEach { addSubjectAlternativeName(it) }
            if (signedByRoot) signedBy(root)
        }.build()

    private fun connect(server: MockWebServer, recorder: Recorder): GatewayTransport =
        GatewayWebSockets.open(SocketRequest("wss://127.0.0.1:${server.port}/api/ws?token=t", emptyMap(), null), recorder)
            .also { transports += it }

    @Test fun aCertificateForTheHostFromATrustedAuthorityConnectsAndCarriesMessages() {
        val recorder = Recorder()
        connect(tlsServer(certificate("127.0.0.1")), recorder)
        assertNotNull("The socket opened over TLS", recorder.opened.poll(10, TimeUnit.SECONDS))
        assertEquals("hello over tls", recorder.messages.poll(10, TimeUnit.SECONDS))
        assertTrue(recorder.failures.isEmpty())
    }

    @Test fun aTrustedCertificateForAnotherHostIsRefusedByHostnameVerification() {
        val recorder = Recorder()
        connect(tlsServer(certificate("other.example")), recorder)
        val failure = recorder.failed.poll(10, TimeUnit.SECONDS)
        assertEquals(HermesException.Kind.TlsRequired, failure?.kind)
        assertNull("Not one byte of the upgrade was accepted", recorder.opened.poll(200, TimeUnit.MILLISECONDS))
        assertNull(recorder.messages.poll(200, TimeUnit.MILLISECONDS))
    }

    @Test fun aCertificateThatChainsToNothingTrustedIsRefusedEvenWhenItNamesTheHost() {
        val recorder = Recorder()
        val stranger = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build() // self-signed
        val identity = HandshakeCertificates.Builder().heldCertificate(stranger).build()
        val server = MockWebServer().also {
            it.useHttps(identity.sslSocketFactory(), false)
            it.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {}))
            it.start()
            servers += it
        }
        connect(server, recorder)
        assertEquals(HermesException.Kind.TlsRequired, recorder.failed.poll(10, TimeUnit.SECONDS)?.kind)
        assertNull(recorder.opened.poll(200, TimeUnit.MILLISECONDS))
    }

    @Test fun anExpiredCertificateIsRefused() {
        val recorder = Recorder()
        val expired = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").signedBy(root)
            .validityInterval(System.currentTimeMillis() - 2 * 86_400_000L, System.currentTimeMillis() - 86_400_000L).build()
        connect(tlsServer(expired), recorder)
        assertEquals(HermesException.Kind.TlsRequired, recorder.failed.poll(10, TimeUnit.SECONDS)?.kind)
    }

    @Test fun theHttpClientAlsoRefusesACertificateThatChainsToNothingTheDeviceTrusts() {
        val stranger = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build()
        val identity = HandshakeCertificates.Builder().heldCertificate(stranger).build()
        val server = MockWebServer().also {
            it.useHttps(identity.sslSocketFactory(), false)
            it.enqueue(MockResponse().setBody("{}"))
            it.start()
            servers += it
        }
        val http = OkHttpHermesHttp(HermesEndpoint.parse("https://127.0.0.1:${server.port}"))
        try {
            val failure = kotlin.runCatching { kotlinx.coroutines.runBlocking { http.send(HermesHttpRequest("/api/status", timeoutMillis = 5_000)) } }.exceptionOrNull()
            assertEquals(HermesException.Kind.TlsRequired, (failure as? HermesException)?.kind)
            assertEquals("Nothing reached the application layer", 0, server.requestCount)
        } finally {
            http.close()
        }
    }
}
