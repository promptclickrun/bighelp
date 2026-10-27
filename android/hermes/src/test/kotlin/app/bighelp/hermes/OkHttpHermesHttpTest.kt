package app.bighelp.hermes

import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Real HTTP to a loopback server: headers on the wire, no redirects/cookies/retries, byte budgets, cancellation. */
class OkHttpHermesHttpTest {
    private val server = MockWebServer()
    private val opened = mutableListOf<OkHttpHermesHttp>()

    @After fun stop() {
        opened.forEach { it.close() }
        server.shutdown()
    }

    private fun http(prefix: String = "/hermes", access: AccessHeaders = AccessHeaders.none): OkHttpHermesHttp {
        server.start()
        val endpoint = HermesEndpoint.parse("http://127.0.0.1:${server.port}$prefix", allowPrivateHttp = true)
        return OkHttpHermesHttp(endpoint, access).also { opened += it }
    }

    private fun kind(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind
    private fun json(body: String = "{}") = MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    // Wire shape

    @Test fun getCarriesTheContractHeadersAndTheDeploymentPrefixAndNothingElse() = runBlocking {
        val http = http()
        server.enqueue(json("""{"auth_required":false}"""))
        val result = http.send(HermesHttpRequest("/api/status", query = listOf("q" to "a b&c=d+é")))
        assertEquals(200, result.status)
        assertEquals("""{"auth_required":false}""", result.text())
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("GET", request.method)
        assertEquals("/hermes/api/status?q=a%20b%26c%3Dd%2B%C3%A9", request.path)
        assertEquals("application/json", request.getHeader("Accept"))
        assertEquals("no-store", request.getHeader("Cache-Control"))
        assertEquals("close", request.getHeader("Connection"))
        assertNull(request.getHeader("Authorization"))
        assertNull(request.getHeader("X-Hermes-Session-Token"))
        assertNull(request.getHeader("Cookie"))
        assertNull(request.getHeader("Origin"))
        assertNull(request.getHeader("Content-Type"))
    }

    @Test fun bearerAndDashboardCredentialsUseTheirOwnHeader() = runBlocking {
        val http = http()
        server.enqueue(json())
        server.enqueue(json())
        http.send(HermesHttpRequest("/api/auth/me", auth = HttpAuth.Bearer("access.token-1")))
        http.send(HermesHttpRequest("/api/sessions", auth = HttpAuth.DashboardSession("dash~token")))
        val bearer = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("Bearer access.token-1", bearer.getHeader("Authorization"))
        assertNull(bearer.getHeader("X-Hermes-Session-Token"))
        val dashboard = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("dash~token", dashboard.getHeader("X-Hermes-Session-Token"))
        assertNull(dashboard.getHeader("Authorization"))
    }

    @Test fun anInvalidTokenIsRefusedBeforeAnythingIsSent() {
        val http = http()
        listOf("", "has space", "tab\t", "é", "x".repeat(16_385)).forEach {
            assertEquals(it, HermesException.Kind.InvalidCredentials, kind { http.send(HermesHttpRequest("/x", auth = HttpAuth.Bearer(it))) })
            assertEquals(HermesException.Kind.InvalidCredentials, kind { http.send(HermesHttpRequest("/x", auth = HttpAuth.DashboardSession(it))) })
        }
        assertEquals("Nothing reached the host", 0, server.requestCount)
    }

    @Test fun jsonBodiesAreBoundedAndSentWithTheirContentType() = runBlocking {
        val http = http()
        server.enqueue(json())
        http.send(HermesHttpRequest("/auth/native/token", "POST", body = buildJsonObject { put("code", "c"); put("code_verifier", "v") }))
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals("application/json", request.getHeader("Content-Type"))
        assertEquals("""{"code":"c","code_verifier":"v"}""", request.body.readUtf8())

        val tooBig = buildJsonObject { put("x", "y".repeat(HermesHttpLimits.MAXIMUM_BODY_BYTES)) }
        assertEquals(HermesException.Kind.MessageTooLarge, kind { http.send(HermesHttpRequest("/x", "POST", body = tooBig)) })
        assertEquals("The oversize body was never sent", 1, server.requestCount)
    }

    @Test fun gateHeadersAreSentAndAHermesBearerReplacesAProxyBasicAuthorization() = runBlocking {
        val access = AccessHeaders.of(
            HermesEndpoint.parse("http://127.0.0.1:1", allowPrivateHttp = true),
            AccessCredential.proxyBasic("user", "pass"),
            listOf(CustomHeader.of("X-Gate", "g")),
        )
        val http = http(access = access)
        server.enqueue(json())
        server.enqueue(json())
        http.send(HermesHttpRequest("/api/status"))
        http.send(HermesHttpRequest("/api/auth/me", auth = HttpAuth.Bearer("tok")))
        val plain = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("Basic dXNlcjpwYXNz", plain.getHeader("Authorization"))
        assertEquals("g", plain.getHeader("X-Gate"))
        val bearer = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("There is only one Authorization header", "Bearer tok", bearer.headers.values("Authorization").single())
        assertEquals("g", bearer.getHeader("X-Gate"))
    }

    @Test fun theCookieHeaderExistsOnlyWhenTheCallerSuppliesOne() = runBlocking {
        val http = http()
        server.enqueue(json().addHeader("Set-Cookie", "session=server-cookie; Path=/"))
        server.enqueue(json())
        server.enqueue(json())
        http.send(HermesHttpRequest("/a"))
        http.send(HermesHttpRequest("/b"))
        http.send(HermesHttpRequest("/c", cookie = "hermes_session_pkce=abc"))
        server.takeRequest(5, TimeUnit.SECONDS)
        assertNull("No jar remembers a Set-Cookie", server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Cookie"))
        assertEquals("hermes_session_pkce=abc", server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Cookie"))
    }

    @Test fun nativeGuardHeadersOnlyOnPluginPostsWithExactlyOneCredential() = runBlocking {
        val http = http()
        val guard = NativeGuard("\"etag-1\"", "123e4567-e89b-42d3-a456-426614174000")
        val session = HttpAuth.DashboardSession("t")
        val route = "/api/plugins/loopdy/native/goals"
        repeat(2) { server.enqueue(json()) }
        http.send(HermesHttpRequest(route, "POST", body = buildJsonObject {}, auth = session, nativeGuard = guard))
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("\"etag-1\"", request.getHeader("If-Match"))
        assertEquals("123e4567-e89b-42d3-a456-426614174000", request.getHeader("X-Loopdy-Request-ID"))
        http.send(HermesHttpRequest("/api/plugins/loopdy/native/telemetry", "PUT", body = buildJsonObject {}, auth = session, nativeGuard = guard))
        assertEquals("PUT", server.takeRequest(5, TimeUnit.SECONDS)!!.method)

        fun refused(request: HermesHttpRequest) = assertEquals(HermesException.Kind.InvalidResponse, kind { http.send(request) })
        refused(HermesHttpRequest("/api/sessions", "POST", body = buildJsonObject {}, auth = session, nativeGuard = guard))
        refused(HermesHttpRequest(route, "POST", body = buildJsonObject {}, auth = session,
            nativeGuard = NativeGuard("\"e\"", "NOT-A-LOWERCASE-UUID")))
        refused(HermesHttpRequest(route, "GET", auth = session, nativeGuard = guard))
        refused(HermesHttpRequest(route, "POST", body = buildJsonObject {}, nativeGuard = guard))
        refused(HermesHttpRequest(route, "POST", body = buildJsonObject {}, auth = session, cookie = "a=b", nativeGuard = guard))
        assertEquals("Every refusal happened before sending", 2, server.requestCount)
    }

    // Redirects

    @Test fun noRedirectIsFollowedAndTheTargetIsNeverContacted() {
        val http = http()
        listOf(301, 302, 303, 307, 308).forEach { code ->
            server.enqueue(MockResponse().setResponseCode(code).setHeader("Location", "/hermes/elsewhere"))
            assertEquals(code.toString(), HermesException.Kind.RedirectRefused, kind { http.send(HermesHttpRequest("/api/status")) })
        }
        assertEquals(5, server.requestCount)
        repeat(5) { assertEquals("/hermes/api/status", server.takeRequest(5, TimeUnit.SECONDS)!!.path) }
    }

    @Test fun onlyTheAuthorizeCallMayReturnItsOwn302Unfollowed() = runBlocking {
        val http = http()
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/hermes/login"))
        val result = http.send(HermesHttpRequest("/auth/native/authorize", allowAuthorizeRedirect = true))
        assertEquals(302, result.status)
        assertEquals("/hermes/login", result.header("Location"))
        server.enqueue(MockResponse().setResponseCode(301).setHeader("Location", "/hermes/login"))
        assertEquals(HermesException.Kind.RedirectRefused, kind {
            http.send(HermesHttpRequest("/auth/native/authorize", allowAuthorizeRedirect = true))
        })
        assertEquals("Neither Location was followed", 2, server.requestCount)
    }

    @Test fun aCloudflareAccessLoginRedirectIsADenialNotAGenericRedirect() {
        val http = http()
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://team.cloudflareaccess.com/cdn-cgi/access/login"))
        assertEquals(HermesException.Kind.CloudflareAccessDenied, kind { http.send(HermesHttpRequest("/api/status")) })
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://evilcloudflareaccess.com/x"))
        assertEquals("Only the real domain counts", HermesException.Kind.RedirectRefused, kind { http.send(HermesHttpRequest("/api/status")) })
    }

    @Test fun aServiceTokenRejectionPageIsCloudflareAccessDeniedOnlyWhenATokenWasSent() = runBlocking {
        val credentialed = AccessHeaders.of(
            HermesEndpoint.parse("https://127.0.0.1:1"), AccessCredential.cloudflareAccess("id", "secret"), emptyList(),
        )
        // The service token is HTTPS only, so prove the page rule through the HTTP-capable check directly.
        val page = MockResponse().setResponseCode(403).setHeader("Content-Type", "text/html; charset=utf-8")
            .setHeader("CF-RAY", "abc123-AMS").setBody("<html>blocked</html>")
        val http = http()
        server.enqueue(page)
        val plain = http.send(HermesHttpRequest("/api/status"))
        assertEquals("Without a token this is just a 403 page", 403, plain.status)
        assertTrue(credentialed.values.containsKey("CF-Access-Client-Id"))
        assertTrue(OkHttpHermesHttp.isCloudflareAccessDenial(403, "text/html", hasRay = true, sentAccessToken = true))
        assertFalse(OkHttpHermesHttp.isCloudflareAccessDenial(403, "application/json", hasRay = true, sentAccessToken = true))
        assertFalse(OkHttpHermesHttp.isCloudflareAccessDenial(403, "text/html", hasRay = false, sentAccessToken = true))
        assertFalse(OkHttpHermesHttp.isCloudflareAccessDenial(200, "text/html", hasRay = true, sentAccessToken = true))
    }

    // Response budgets

    @Test fun aDeclaredLengthOverTheBudgetFailsWithoutReadingTheBody() {
        val http = http()
        server.enqueue(MockResponse().setBody("x".repeat(200)))
        assertEquals(HermesException.Kind.MessageTooLarge, kind { http.send(HermesHttpRequest("/x", maximumResponseBytes = 100)) })
    }

    @Test fun bytesAreCountedWhileReadingSoAnUndeclaredLengthCannotOverflow() = runBlocking {
        val http = http()
        val body = "z".repeat(1_000)
        server.enqueue(MockResponse().setChunkedBody(body, 64))
        assertEquals(HermesException.Kind.MessageTooLarge, kind { http.send(HermesHttpRequest("/x", maximumResponseBytes = 999)) })
        server.enqueue(MockResponse().setChunkedBody(body, 64))
        assertEquals("Exactly the budget is allowed", 1_000, http.send(HermesHttpRequest("/x", maximumResponseBytes = 1_000)).body.size)
    }

    @Test fun theBudgetCountsDecodedBytesSoACompressedBombIsRefused() {
        val http = http()
        val bomb = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(ByteArray(2_000_000) { 'a'.code.toByte() }) } }
        assertTrue("The bomb is small on the wire", bomb.size() < 10_000)
        server.enqueue(MockResponse().setHeader("Content-Encoding", "gzip").setBody(Buffer().write(bomb.toByteArray())))
        assertEquals(HermesException.Kind.MessageTooLarge, kind { http.send(HermesHttpRequest("/x", maximumResponseBytes = 1_000_000)) })
    }

    @Test fun aBudgetBeyondTheRouteCeilingIsRefusedBeforeSending() {
        val http = http()
        assertEquals(HermesException.Kind.MessageTooLarge, kind { http.send(HermesHttpRequest("/api/status", maximumResponseBytes = 0)) })
        assertEquals(HermesException.Kind.MessageTooLarge, kind {
            http.send(HermesHttpRequest("/api/status", maximumResponseBytes = HermesWire.MAXIMUM_MESSAGE_BYTES + 1))
        })
        assertEquals(0, server.requestCount)
        assertEquals(4 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/sessions", "GET", emptyList()))
        assertEquals(25 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/sessions/abc/export", "GET", emptyList()))
        assertEquals(4 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/sessions/a/b/export", "GET", emptyList()))
        assertEquals(12 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/plugins/loopdy/native/board/media", "POST", emptyList()))
        assertEquals(4 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/plugins/loopdy/native/board/media", "POST", listOf("x" to "y")))
        assertEquals(
            HermesHttpLimits.MAXIMUM_MEDIA_RESPONSE_BYTES,
            HermesHttpLimits.responseCeiling("/api/media", "GET", listOf("path" to "/out/a.png")),
        )
        assertEquals(4 * 1_024 * 1_024, HermesHttpLimits.responseCeiling("/api/media", "GET", listOf("path" to "/out/../a.png")))
        assertEquals(1_000L, HermesHttpLimits.clampTimeoutMillis(1))
        assertEquals(75_000L, HermesHttpLimits.clampTimeoutMillis(10_000_000))
    }

    @Test fun responseBodiesDecodeStrictly() = runBlocking {
        val http = http()
        server.enqueue(MockResponse().setBody(Buffer().write(byteArrayOf('{'.code.toByte(), 0xC3.toByte(), '}'.code.toByte()))))
        val bad = http.send(HermesHttpRequest("/x"))
        assertEquals(HermesException.Kind.InvalidResponse, kind { bad.json() })
        server.enqueue(json("""{"a":1,"a":2}"""))
        assertEquals("A duplicate key is not guessed", HermesException.Kind.InvalidResponse, kind { http.send(HermesHttpRequest("/x")).json() })
        server.enqueue(json("[1]"))
        assertEquals(HermesException.Kind.InvalidResponse, kind { http.send(HermesHttpRequest("/x")).jsonObject() })
    }

    // Status mapping

    @Test fun statusMappingFollowsTheGenericContract() {
        fun status(code: Int) = HttpResult(code, emptyList(), ByteArray(0))
        listOf(200, 204, 299).forEach { status(it).requireSuccess() }
        mapOf(
            401 to HermesException.Kind.InvalidCredentials, 403 to HermesException.Kind.InvalidCredentials,
            404 to HermesException.Kind.UnsupportedAuthentication, 405 to HermesException.Kind.UnsupportedAuthentication,
            429 to HermesException.Kind.RateLimited, 500 to HermesException.Kind.ServerUnavailable,
            503 to HermesException.Kind.ServerUnavailable, 418 to HermesException.Kind.InvalidResponse,
            302 to HermesException.Kind.InvalidResponse,
        ).forEach { (code, expected) -> assertEquals(code.toString(), expected, kind { status(code).requireSuccess() }) }
    }

    @Test fun hostNameRefusalAndWebPagesAreRecognizedWithoutShowingTheBody() {
        fun result(code: Int, type: String, body: String, vararg extra: Pair<String, String>) =
            HttpResult(code, listOf("Content-Type" to type) + extra, body.toByteArray())
        assertEquals(
            HermesException.Kind.HostNameRefused,
            kind { result(400, "application/json", """{"detail":"Invalid Host header: evil.example"}""").requireHermesAnswer() },
        )
        val page = assertThrows(HermesException::class.java) { result(200, "text/html", "<p>SECRET</p>").requireHermesAnswer() }
        assertEquals(HermesException.Kind.WebPageInsteadOfHermes, page.kind)
        assertFalse(page.throughCloudflare)
        assertFalse("SECRET" in page.message.orEmpty() || "SECRET" in page.toString())
        assertTrue(assertThrows(HermesException::class.java) {
            result(400, "text/html", "x", "CF-RAY" to "1-AMS").requireHermesAnswer()
        }.throughCloudflare)
        result(401, "text/html", "x").requireHermesAnswer()
        result(503, "text/html", "x").requireHermesAnswer()
        result(200, "application/json", "{}").requireHermesAnswer()
    }

    // No retry, no stale pooled socket

    @Test fun aDroppedRequestIsNeverSentAgain() = runBlocking {
        val http = http()
        // The canary stays queued if (and only if) nothing was resent.
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(json())
        assertEquals(HermesException.Kind.ConnectionFailed, kind {
            http.send(HermesHttpRequest("/auth/native/token", "POST", body = buildJsonObject { put("code", "once") }))
        })
        assertEquals("A one-use code reached the host exactly once", 1, server.requestCount)
        assertEquals("The canary was still waiting", 200, http.send(HermesHttpRequest("/api/status")).status)

        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(json())
        assertEquals(HermesException.Kind.ConnectionFailed, kind { http.send(HermesHttpRequest("/api/status")) })
        assertEquals("Not even a GET is retried by the transport", 3, server.requestCount)
    }

    @Test fun aHostThatClosesAfterEachKeepAliveReplyNeverBreaksTheNextRequest() = runBlocking {
        val http = http()
        repeat(4) { server.enqueue(json().setSocketPolicy(SocketPolicy.DISCONNECT_AT_END)) }
        repeat(4) { assertEquals(200, http.send(HermesHttpRequest("/api/status")).status) }
        repeat(4) {
            assertEquals("Each request opened its own connection", 0, server.takeRequest(5, TimeUnit.SECONDS)!!.sequenceNumber)
        }
    }

    @Test fun errorsNameNoUrlTokenOrBody() {
        val http = http()
        server.shutdown()
        val e = assertThrows(HermesException::class.java) {
            runBlocking { http.send(HermesHttpRequest("/api/x", query = listOf("secret" to "QUERY-SECRET"), auth = HttpAuth.Bearer("BEARER-SECRET"))) }
        }
        assertEquals(HermesException.Kind.ConnectionFailed, e.kind)
        assertNull("No cause that could carry the URL", e.cause)
        val text = e.message.orEmpty() + e.toString()
        listOf("QUERY-SECRET", "BEARER-SECRET", "127.0.0.1", "/api/x").forEach { assertFalse(it, it in text) }
    }

    @Test fun aTlsHandshakeAgainstAPlainHostIsATlsFailure() {
        // A host that answers the ClientHello with plain HTTP text, as a misconfigured proxy would.
        val plain = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val thread = Thread {
            runCatching {
                plain.accept().use { socket ->
                    socket.getInputStream().read(ByteArray(512))
                    socket.getOutputStream().write("HTTP/1.1 400 Bad Request\r\n\r\n".toByteArray())
                }
            }
        }.also { it.start() }
        val http = OkHttpHermesHttp(HermesEndpoint.parse("https://127.0.0.1:${plain.localPort}")).also { opened += it }
        try {
            assertEquals(HermesException.Kind.TlsRequired, kind { http.send(HermesHttpRequest("/api/status", timeoutMillis = 5_000)) })
        } finally {
            plain.close()
            thread.join(2_000)
        }
    }

    // Time and cancellation

    @Test fun aSlowHostTimesOutAtTheRequestBudget() {
        val http = http()
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val start = System.nanoTime()
        assertEquals(HermesException.Kind.TimedOut, kind { http.send(HermesHttpRequest("/x", timeoutMillis = 1_000)) })
        assertTrue("Failed near one second, not five", System.nanoTime() - start < TimeUnit.SECONDS.toNanos(3))
    }

    @Test fun cancellingTheCallerCancelsTheRealCallPromptly() = runBlocking {
        val http = http()
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val call = async { http.send(HermesHttpRequest("/x")) }
        var waited = 0
        while (http.activeCalls == 0 && waited++ < 200) delay(10)
        assertEquals(1, http.activeCalls)
        call.cancel()
        val start = System.nanoTime()
        assertThrows(CancellationException::class.java) { runBlocking { withTimeout(3_000) { call.await() } } }
        waited = 0
        while (http.activeCalls != 0 && waited++ < 200) delay(10)
        assertEquals("The underlying call was cancelled, not abandoned", 0, http.activeCalls)
        assertTrue(System.nanoTime() - start < TimeUnit.SECONDS.toNanos(3))
    }

    @Test fun closingTheClientCancelsRunningCallsAndRefusesNewOnes() {
        val http = http()
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val running = Thread {
            runCatching { runBlocking { http.send(HermesHttpRequest("/x")) } }
        }.also { it.start() }
        var waited = 0
        while (http.activeCalls == 0 && waited++ < 200) Thread.sleep(10)
        http.close()
        running.join(3_000)
        assertFalse(running.isAlive)
        assertEquals(HermesException.Kind.NotConnected, kind { http.send(HermesHttpRequest("/y")) })
        assertNotNull(http)
    }
}
