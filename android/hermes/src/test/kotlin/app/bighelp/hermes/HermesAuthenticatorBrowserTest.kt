package app.bighelp.hermes

import java.net.ConnectException
import java.net.InetAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Browser PKCE end to end with a real loopback listener; the launcher plays the person's browser. */
class HermesAuthenticatorBrowserTest {
    private val host = ScriptedHost("/hermes")
    private val store = InMemoryCredentialStore()
    private val clock = TestClock(java.time.Instant.ofEpochSecond(1_800_000_000))
    private val now = 1_800_000_000L
    private val resources = mutableListOf<AutoCloseable>()

    @After fun stop() {
        resources.forEach { it.close() }
        host.close()
    }

    private fun authenticator(browser: BrowserLauncher?, timings: AuthTimings = AuthTimings()) =
        HermesAuthenticator(host.endpoint, OkHttpHermesHttp(host.endpoint).also { resources += it }, store, browser, clock, timings = timings)
            .also { resources += it }

    private fun kind(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind

    private fun gatedHost(
        token: MockResponse = tokenReply(),
        me: MockResponse = ScriptedHost.json("""{"provider":"basic","user_id":"synthetic-user"}"""),
    ) {
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":true,"auth_flows":["native_pkce"]}"""))
        host.on("GET", "/api/auth/providers", ScriptedHost.json("""{"providers":[{"name":"basic","supports_password":true},{"name":"sso","supports_password":false}]}"""))
        host.on("POST", "/auth/native/token", token)
        host.on("GET", "/api/auth/me", me)
    }

    private fun tokenReply(provider: String = "basic") =
        ScriptedHost.json("""{"token_type":"Bearer","access_token":"access-1","refresh_token":"refresh-1","provider":"$provider","user_id":"synthetic-user","expires_at":${now + 3_600}}""")

    private fun challenge(verifier: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

    /** The "browser": parses the authorize URL and delivers the host's redirect to the loopback listener. */
    private fun browserReturning(code: String = "browser-code", seen: (okhttp3.HttpUrl) -> Unit = {}) = BrowserLauncher { url ->
        val authorize = url.toHttpUrl()
        seen(authorize)
        val callback = authorize.queryParameter("redirect_uri")!!.toHttpUrl()
        val state = authorize.queryParameter("state")!!
        Socket(InetAddress.getByName("127.0.0.1"), callback.port).use { socket ->
            socket.getOutputStream().write("GET ${callback.encodedPath}?state=$state&code=$code HTTP/1.1\r\nHost: 127.0.0.1:${callback.port}\r\n\r\n".toByteArray())
            socket.getInputStream().readBytes()
        }
    }

    @Test fun browserSignInUsesALoopbackRedirectAndExchangesTheCodeOnce() = runBlocking {
        gatedHost()
        var authorize: okhttp3.HttpUrl? = null
        val staged = authenticator(browserReturning { authorize = it }).signIn(SignInInput.Browser(provider = null))

        val url = authorize!!
        assertEquals("/hermes/auth/native/authorize", url.encodedPath)
        assertEquals(setOf("code_challenge", "code_challenge_method", "redirect_uri", "state"), url.queryParameterNames)
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        val redirect = url.queryParameter("redirect_uri")!!.toHttpUrl()
        assertEquals("http", redirect.scheme)
        assertEquals("127.0.0.1", redirect.host)
        assertTrue(redirect.encodedPath.matches(Regex("/loopdy-native-callback/[A-Za-z0-9_-]{43}")))
        assertTrue(Regex("[A-Za-z0-9_-]{43}").matches(url.queryParameter("state")!!))

        val exchange = Json.parseToJsonElement(host.callsTo("/auth/native/token").single().body.readUtf8()).jsonObject
        assertEquals(setOf("code", "code_verifier"), exchange.keys)
        assertEquals("browser-code", exchange["code"]!!.jsonPrimitive.content)
        assertEquals(challenge(exchange["code_verifier"]!!.jsonPrimitive.content), url.queryParameter("code_challenge"))
        assertEquals(listOf("GET /api/status", "GET /api/auth/providers", "POST /auth/native/token", "GET /api/auth/me"), host.calls)
        assertEquals(StoredAuth.Bearer("access-1", "refresh-1", now + 3_600), staged.auth)
        assertNull("Nothing is stored until the gateway is ready", store.load(staged.authority))
        assertFalse("No cookie was ever sent", host.requests.any { it.getHeader("Cookie") != null })
        assertThrows("The listener is gone", ConnectException::class.java) {
            Socket(InetAddress.getByName("127.0.0.1"), redirect.port).close()
        }
        Unit
    }

    @Test fun anExplicitProviderIsPassedAndCheckedAgainstTheToken() = runBlocking {
        gatedHost(token = tokenReply(provider = "basic"))
        var authorize: okhttp3.HttpUrl? = null
        authenticator(browserReturning { authorize = it }).signIn(SignInInput.Browser("basic"))
        assertEquals("basic", authorize!!.queryParameter("provider"))

        gatedHost(token = tokenReply(provider = "other"))
        assertEquals(HermesException.Kind.IdentityChanged, kind { authenticator(browserReturning()).signIn(SignInInput.Browser("basic")) })
        gatedHost(me = ScriptedHost.json("""{"provider":"basic","user_id":"someone-else"}"""))
        assertEquals("/api/auth/me must agree with the token", HermesException.Kind.IdentityChanged, kind { authenticator(browserReturning()).signIn(SignInInput.Browser(null)) })
    }

    @Test fun aProviderThatIsNotPrintableAsciiNeverStartsABrowser() {
        gatedHost()
        var opened = false
        val launcher = BrowserLauncher { opened = true }
        listOf("", "has space", "é", "p".repeat(129)).forEach {
            assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator(launcher).signIn(SignInInput.Browser(it)) })
        }
        assertFalse(opened)
    }

    @Test fun withoutALauncherOrWhenItFailsTheBrowserIsUnavailableAndNothingElseHappens() {
        gatedHost()
        assertEquals(HermesException.Kind.BrowserAuthenticationUnavailable, kind { authenticator(null).signIn(SignInInput.Browser(null)) })
        assertEquals(
            HermesException.Kind.BrowserAuthenticationUnavailable,
            kind { authenticator(BrowserLauncher { throw IllegalStateException("no custom tabs https://secret") }).signIn(SignInInput.Browser(null)) },
        )
        assertTrue(host.callsTo("/auth/native/token").isEmpty())
    }

    @Test fun strayRequestsAreIgnoredUntilTheRealRedirectArrives() = runBlocking {
        gatedHost()
        val launcher = BrowserLauncher { url ->
            val authorize = url.toHttpUrl()
            val callback = authorize.queryParameter("redirect_uri")!!.toHttpUrl()
            fun send(target: String) = runCatching {
                Socket(InetAddress.getByName("127.0.0.1"), callback.port).use {
                    it.getOutputStream().write("GET $target HTTP/1.1\r\nHost: 127.0.0.1:${callback.port}\r\n\r\n".toByteArray())
                    it.getInputStream().readBytes()
                }
            }
            send("/favicon.ico")
            send("${callback.encodedPath}?state=WRONG&code=attacker-code")
            send("${callback.encodedPath}?state=${authorize.queryParameter("state")}&code=real-code")
        }
        authenticator(launcher).signIn(SignInInput.Browser(null))
        assertEquals("real-code", Json.parseToJsonElement(host.callsTo("/auth/native/token").single().body.readUtf8()).jsonObject["code"]!!.jsonPrimitive.content)
    }

    @Test fun cancellingWhileTheBrowserIsOpenClosesTheListenerAndStagesNothing() = runBlocking {
        gatedHost()
        val opened = CompletableDeferred<Int>()
        val launcher = BrowserLauncher { url ->
            opened.complete(url.toHttpUrl().queryParameter("redirect_uri")!!.toHttpUrl().port)
            delay(60_000)
        }
        val authenticator = authenticator(launcher)
        val attempt = async { authenticator.signIn(SignInInput.Browser(null)) }
        val port = opened.await()
        attempt.cancel()
        assertThrows(CancellationException::class.java) { runBlocking { attempt.await() } }
        var refused = false
        repeat(50) { if (!refused) { refused = runCatching { Socket(InetAddress.getByName("127.0.0.1"), port).close() }.isFailure; if (!refused) delay(20) } }
        assertTrue("The port stopped listening", refused)
        assertNull(authenticator.savedConnection)
        assertTrue(host.callsTo("/auth/native/token").isEmpty())
    }

    @Test fun cancelAuthenticationEndsABrowserWait() = runBlocking {
        gatedHost()
        val opened = CompletableDeferred<Unit>()
        val authenticator = authenticator(BrowserLauncher { opened.complete(Unit); delay(60_000) })
        val attempt = async { runCatching { authenticator.signIn(SignInInput.Browser(null)) }.exceptionOrNull() }
        opened.await()
        authenticator.cancelAuthentication()
        assertEquals(HermesException.Kind.Cancelled, (attempt.await() as HermesException).kind)
    }

    @Test fun theWholeSignInIsBoundedByTheBrowserDeadline() {
        gatedHost()
        val timings = AuthTimings(browserSignInMillis = 300)
        assertEquals(HermesException.Kind.TimedOut, kind { authenticator(BrowserLauncher { }, timings).signIn(SignInInput.Browser(null)) })
        assertTrue(host.callsTo("/auth/native/token").isEmpty())
    }

    @Test fun aLostTokenExchangeIsUncertainAndTheCodeIsNeverSentAgain() {
        gatedHost(token = MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        val failure = assertThrows(HermesException::class.java) { runBlocking { authenticator(browserReturning()).signIn(SignInInput.Browser(null)) } }
        assertEquals(HermesException.Kind.NativeTokenExchangeUncertain, failure.kind)
        assertTrue(failure.outcomeUnknown)
        assertEquals(1, host.callsTo("/auth/native/token").size)

        gatedHost(token = ScriptedHost.json("not json"))
        assertEquals("A malformed answer after sending is uncertain too", HermesException.Kind.NativeTokenExchangeUncertain,
            kind { authenticator(browserReturning()).signIn(SignInInput.Browser(null)) })
        gatedHost(token = MockResponse().setResponseCode(401))
        assertEquals("A clear refusal is just a refusal", HermesException.Kind.InvalidCredentials,
            kind { authenticator(browserReturning()).signIn(SignInInput.Browser(null)) })
    }
}
