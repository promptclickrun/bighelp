package app.bighelp.hermes

import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Discovery and every sign-in mode against a scripted loopback host. The credential store is never written. */
class HermesAuthenticatorSignInTest {
    private val host = ScriptedHost("/hermes")
    private val store = InMemoryCredentialStore()
    private val clock = TestClock(java.time.Instant.ofEpochSecond(1_800_000_000))
    private val resources = mutableListOf<AutoCloseable>()
    private val now = 1_800_000_000L

    @After fun stop() {
        resources.forEach { it.close() }
        host.close()
    }

    private fun authenticator(browser: BrowserLauncher? = null, access: AccessHeaders = AccessHeaders.none): HermesAuthenticator {
        val http = OkHttpHermesHttp(host.endpoint, access)
        return HermesAuthenticator(host.endpoint, http, store, browser, clock).also { resources += it }
    }

    private fun kind(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind

    private fun body(request: RecordedRequest): JsonObject = Json.parseToJsonElement(request.body.readUtf8()).jsonObject

    private fun status(authRequired: Boolean, flows: String = "[]") =
        ScriptedHost.json("""{"auth_required":$authRequired,"auth_flows":$flows}""")

    private fun tokenReply(access: String = "access-1", refresh: String? = "refresh-1", provider: String = "basic", user: String = "synthetic-user", expires: Long = now + 3_600) =
        ScriptedHost.json(
            """{"token_type":"Bearer","access_token":"$access","refresh_token":${refresh?.let { "\"$it\"" } ?: "null"},"provider":"$provider","user_id":"$user","expires_at":$expires}""",
        )

    private fun me(provider: String = "basic", user: String = "synthetic-user", expires: Long = now + 3_600) =
        ScriptedHost.json("""{"provider":"$provider","user_id":"$user","expires_at":$expires}""")

    // Discovery

    @Test fun discoveryAsksStatusWithoutAnyCredential() = runBlocking {
        host.on("GET", "/api/status", status(false))
        val found = authenticator(access = AccessHeaders.of(host.endpoint, AccessCredential.proxyBasic("u", "p"), emptyList())).discover()
        assertFalse(found.authRequired)
        assertEquals(emptyList<AuthProvider>(), found.providers)
        val request = host.requests.single()
        assertEquals("Basic dTpw", request.getHeader("Authorization"))
        assertNull(request.getHeader("X-Hermes-Session-Token"))
        assertNull(request.getHeader("Cookie"))
        assertEquals(listOf("GET /api/status"), host.calls)
    }

    @Test fun discoveryFetchesProvidersOnlyForNativePkceAndNeverLetsThemDisableTheFlow() = runBlocking {
        host.on("GET", "/api/status", status(true, """["cookie","native_pkce"]"""))
        host.on("GET", "/api/auth/providers", ScriptedHost.json("""{"providers":[{"name":"basic","display_name":"Password","supports_password":true},{"name":"sso","supports_password":false}]}"""))
        val found = authenticator().discover()
        assertTrue(found.supportsNativePkce)
        assertEquals(listOf("basic"), found.passwordProviders.map { it.name })
        assertEquals(listOf("basic", "sso"), found.browserProviders.map { it.name })
        assertEquals(listOf("GET /api/status", "GET /api/auth/providers"), host.calls)

        host.on("GET", "/api/auth/providers", ScriptedHost.json("""{"providers":"broken"}"""))
        val degraded = authenticator().discover()
        assertTrue("A malformed list never disables the advertised flow", degraded.supportsNativePkce)
        assertTrue(degraded.providers.isEmpty())
        host.on("GET", "/api/auth/providers") { MockResponse().setResponseCode(503) }
        assertTrue(authenticator().discover().supportsNativePkce)
    }

    @Test fun discoveryDoesNotAskForProvidersWithoutNativePkce() = runBlocking {
        host.on("GET", "/api/status", status(true, """["cookie"]"""))
        authenticator().discover()
        host.on("GET", "/api/status", status(false, """["native_pkce"]"""))
        authenticator().discover()
        assertEquals(listOf("GET /api/status", "GET /api/status"), host.calls)
    }

    @Test fun discoveryRecognizesAWebPageAHostNameRefusalAndBadStatuses() {
        val html = ScriptedHost.html("<html>nope</html>")
        host.on("GET", "/api/status", html)
        assertEquals(HermesException.Kind.WebPageInsteadOfHermes, kind { authenticator().discover() })
        host.on("GET", "/api/status", ScriptedHost.json("""{"detail":"Invalid Host header"}""", 400))
        assertEquals(HermesException.Kind.HostNameRefused, kind { authenticator().discover() })
        host.on("GET", "/api/status", MockResponse().setResponseCode(503))
        assertEquals(HermesException.Kind.ServerUnavailable, kind { authenticator().discover() })
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":"maybe"}"""))
        assertEquals(HermesException.Kind.InvalidResponse, kind { authenticator().discover() })
    }

    // Ungated modes

    @Test fun automaticDashboardSignInReadsTheBootstrapTokenAndWritesNothing() = runBlocking {
        host.on("GET", "/api/status", status(false))
        host.on("GET", "/", ScriptedHost.dashboardPage("dash-token-1"))
        val authenticator = authenticator()
        val staged = authenticator.signIn(SignInInput.Dashboard)
        assertEquals(StoredAuth.DashboardSession("dash-token-1", automatic = true), staged.auth)
        assertNull(staged.provider)
        assertEquals(staged, authenticator.savedConnection)
        assertFalse("A sign-in is staged, not persisted", authenticator.isPersisted)
        assertNull(store.load(staged.authority))
        assertEquals(listOf("GET /api/status", "GET /"), host.calls)
        assertEquals("text/html", host.callsTo("/").single().getHeader("Accept"))
        assertNull("The page is read without credentials", host.callsTo("/").single().getHeader("X-Hermes-Session-Token"))
    }

    @Test fun anEnteredTokenOnAnUngatedHostIsAManualDashboardSessionWithoutReadingThePage() = runBlocking {
        host.on("GET", "/api/status", status(false))
        val staged = authenticator().signIn(SignInInput.Token("manual-token"))
        assertEquals(StoredAuth.DashboardSession("manual-token", automatic = false), staged.auth)
        assertEquals(listOf("GET /api/status"), host.calls)
        assertEquals(HermesException.Kind.InvalidCredentials, kind { authenticator().signIn(SignInInput.Token("has space")) })
    }

    @Test fun aGatedTokenIsVerifiedByMeAndNeverGainsARefreshToken() = runBlocking {
        host.on("GET", "/api/status", status(true))
        host.on("GET", "/api/auth/me") { request ->
            if (request.getHeader("Authorization") == "Bearer entered-access") me(expires = now + 900) else MockResponse().setResponseCode(401)
        }
        val staged = authenticator().signIn(SignInInput.Token("entered-access"))
        assertEquals(StoredAuth.Bearer("entered-access", null, now + 900), staged.auth)
        assertEquals("basic", staged.provider)
        assertEquals("synthetic-user", staged.userId)
        assertEquals(CredentialAuthority(host.endpoint.canonical, "basic\u001fsynthetic-user"), staged.authority)

        assertEquals(HermesException.Kind.InvalidCredentials, kind { authenticator().signIn(SignInInput.Token("rejected")) })
        assertTrue("The rejected token is not retried under another mechanism", host.callsTo("/").isEmpty())
        assertTrue(host.requests.none { it.getHeader("X-Hermes-Session-Token") != null })
    }

    @Test fun aMeAnswerWithoutAnIdentityIsRefusedAndAnExpiryIsOptional() = runBlocking {
        host.on("GET", "/api/status", status(true))
        host.on("GET", "/api/auth/me", ScriptedHost.json("""{"provider":"basic","user_id":""}"""))
        assertEquals(HermesException.Kind.InvalidResponse, kind { authenticator().signIn(SignInInput.Token("t")) })
        host.on("GET", "/api/auth/me", ScriptedHost.json("""{"provider":"basic","user_id":"u"}"""))
        assertNull((authenticator().signIn(SignInInput.Token("t")).auth as StoredAuth.Bearer).expiresAtEpochSeconds)
    }

    @Test fun modesThatDoNotMatchTheHostAreRefusedWithoutSendingTheCredential() {
        host.on("GET", "/api/status", status(true, """["native_pkce"]"""))
        assertEquals(HermesException.Kind.AuthModeChanged, kind { authenticator().signIn(SignInInput.Dashboard) })
        host.on("GET", "/api/status", status(false))
        assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) })
        assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator().signIn(SignInInput.Browser(null)) })
        assertTrue(host.requests.none { it.path.orEmpty().contains("/auth/") })
        assertTrue(host.requests.none { it.method == "POST" })
    }

    // Password PKCE

    private fun b64(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    private fun challenge(verifier: String) = b64(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
    private val callback = "http://127.0.0.1:49152/loopdy-native-callback"
    private val cookie = "hermes_session_pkce=cookie_value-1="

    private fun passwordHost(
        providers: String = """[{"name":"basic","display_name":"Password","supports_password":true}]""",
        authorize: (RecordedRequest) -> MockResponse = { MockResponse().setResponseCode(302).setHeader("Location", "/hermes/login").addHeader("Set-Cookie", "$cookie; Path=/hermes; HttpOnly; Max-Age=600") },
        login: (RecordedRequest, String) -> MockResponse = { _, state ->
            ScriptedHost.json("""{"ok":true,"next":"$callback?state=$state&code=one-use-code"}""")
        },
        token: (RecordedRequest) -> MockResponse = { tokenReply() },
        meReply: MockResponse = me(),
    ) {
        host.on("GET", "/api/status", status(true, """["native_pkce"]"""))
        host.on("GET", "/api/auth/providers", ScriptedHost.json("""{"providers":$providers}"""))
        var state = ""
        host.on("GET", "/auth/native/authorize") { request ->
            state = request.requestUrl!!.queryParameter("state")!!
            authorize(request)
        }
        host.on("POST", "/auth/password-login") { login(it, state) }
        host.on("POST", "/auth/native/token", token)
        host.on("GET", "/api/auth/me", meReply)
    }

    @Test fun passwordSignInFollowsTheDocumentedWireExactly() = runBlocking {
        passwordHost()
        val authenticator = authenticator()
        val staged = authenticator.signIn(SignInInput.Password(null, "synthetic-user", "synthetic password"))

        assertEquals(
            listOf(
                "GET /api/status", "GET /api/auth/providers", "GET /auth/native/authorize",
                "POST /auth/password-login", "POST /auth/native/token", "GET /api/auth/me",
            ),
            host.calls,
        )
        val authorize = host.callsTo("/auth/native/authorize").single().requestUrl!!
        assertEquals(setOf("provider", "code_challenge", "code_challenge_method", "redirect_uri", "state"), authorize.queryParameterNames)
        assertEquals("basic", authorize.queryParameter("provider"))
        assertEquals("S256", authorize.queryParameter("code_challenge_method"))
        assertEquals(callback, authorize.queryParameter("redirect_uri"))
        val state = authorize.queryParameter("state")!!
        assertTrue(Regex("[A-Za-z0-9_-]{43}").matches(state))

        val login = host.callsTo("/auth/password-login").single()
        assertEquals("Only the one cookie goes back", cookie, login.getHeader("Cookie"))
        assertEquals("""{"provider":"basic","username":"synthetic-user","password":"synthetic password","next":""}""", login.body.readUtf8())

        val exchange = body(host.callsTo("/auth/native/token").single())
        assertEquals(setOf("code", "code_verifier"), exchange.keys)
        assertEquals("one-use-code", exchange["code"]!!.jsonPrimitive.content)
        val verifier = exchange["code_verifier"]!!.jsonPrimitive.content
        assertEquals("The challenge is S256 of the verifier sent at exchange", challenge(verifier), authorize.queryParameter("code_challenge"))
        assertTrue(verifier != state)
        assertEquals("Bearer access-1", host.callsTo("/api/auth/me").single().getHeader("Authorization"))

        assertEquals(StoredAuth.Bearer("access-1", "refresh-1", now + 3_600), staged.auth)
        assertNull("Nothing is stored until the gateway is ready", store.load(staged.authority))
        listOf(staged.toString(), authenticator.toString()).forEach { assertFalse("synthetic password" in it) }
        assertTrue("No later request carries the password", host.requests.drop(4).none { it.body.size > 0 && "synthetic password" in it.body.snapshot().utf8() })
    }

    @Test fun passwordSignInPicksAnExplicitProviderAndRefusesAmbiguityOrNone() = runBlocking {
        val two = """[{"name":"a","supports_password":true},{"name":"b","supports_password":true},{"name":"sso","supports_password":false}]"""
        passwordHost(providers = two, meReply = me(provider = "b"), token = { tokenReply(provider = "b") })
        assertEquals(HermesException.Kind.AmbiguousPasswordProvider, kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) })
        assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator().signIn(SignInInput.Password("sso", "u", "p")) })
        assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator().signIn(SignInInput.Password("unknown", "u", "p")) })
        assertTrue("No sign-in attempt before the provider is certain", host.callsTo("/auth/native/authorize").isEmpty())
        assertEquals("b", authenticator().signIn(SignInInput.Password("b", "u", "p")).provider)

        passwordHost(providers = """[{"name":"sso","supports_password":false}]""")
        assertEquals(HermesException.Kind.UnsupportedAuthentication, kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) })
    }

    @Test fun passwordCredentialsAreBoundedBeforeAnyRequest() {
        passwordHost()
        listOf("" to "p", "u" to "", "u".repeat(1_025) to "p", "u" to "p".repeat(16_385)).forEach {
            assertEquals(HermesException.Kind.InvalidCredentials, kind { authenticator().signIn(SignInInput.Password(null, it.first, it.second)) })
        }
        assertTrue(host.callsTo("/auth/native/authorize").isEmpty())
        runBlocking { authenticator().signIn(SignInInput.Password(null, "u".repeat(1_024), "p".repeat(16_384))) }
    }

    @Test fun theAuthorizeAnswerMustBeTheExactLoginRedirectWithAnExpectedCookie() {
        fun reply(response: MockResponse) { passwordHost(authorize = { response }) }
        fun attempt() = kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) }
        val cookieHeader = "$cookie; Path=/hermes; Max-Age=600"
        reply(MockResponse().setResponseCode(200).addHeader("Set-Cookie", cookieHeader))
        assertEquals(HermesException.Kind.UnsupportedAuthentication, attempt())
        reply(MockResponse().setResponseCode(302).setHeader("Location", "/login").addHeader("Set-Cookie", cookieHeader))
        assertEquals("The prefix is part of /login", HermesException.Kind.UnsupportedAuthentication, attempt())
        reply(MockResponse().setResponseCode(302).setHeader("Location", "https://evil.example/hermes/login").addHeader("Set-Cookie", cookieHeader))
        assertEquals(HermesException.Kind.UnsupportedAuthentication, attempt())
        reply(MockResponse().setResponseCode(302).setHeader("Location", "/hermes/login?x=1").addHeader("Set-Cookie", cookieHeader))
        assertEquals(HermesException.Kind.UnsupportedAuthentication, attempt())
        reply(MockResponse().setResponseCode(302).setHeader("Location", "/hermes/login"))
        assertEquals("No cookie", HermesException.Kind.InvalidResponse, attempt())
        reply(MockResponse().setResponseCode(302).setHeader("Location", "/hermes/login").addHeader("Set-Cookie", "hermes_session_pkce=a; Path=/hermes"))
        assertEquals("No expiry", HermesException.Kind.InvalidResponse, attempt())
        assertTrue("Never reached the password step", host.callsTo("/auth/password-login").isEmpty())
        // A relative Location with ./ resolves against the authorize URL and is accepted when it lands on /login.
        reply(MockResponse().setResponseCode(302).setHeader("Location", "../../login").addHeader("Set-Cookie", cookieHeader))
        runBlocking { authenticator().signIn(SignInInput.Password(null, "u", "p")) }
    }

    @Test fun theLoginAnswerMustCarryExactlyTheExpectedStateAndACode() {
        fun attempt(next: (String) -> String) {
            passwordHost(login = { _, state -> ScriptedHost.json("""{"ok":true,"next":"${next(state)}"}""") })
        }
        fun run() = kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) }
        val invalid = HermesException.Kind.InvalidResponse
        attempt { s -> "$callback?state=WRONG&code=c" }; assertEquals("state mismatch", invalid, run())
        attempt { s -> "$callback?state=$s&code=c&extra=1" }; assertEquals("extra field", invalid, run())
        attempt { s -> "$callback?state=$s&state=$s" }; assertEquals("no code", invalid, run())
        attempt { s -> "$callback?state=$s&code=a&code=b" }; assertEquals("two codes", invalid, run())
        attempt { s -> "$callback?state=$s&code=" }; assertEquals("empty code", invalid, run())
        attempt { s -> "$callback?state=$s" }; assertEquals("one field", invalid, run())
        attempt { s -> "$callback" }; assertEquals("no query", invalid, run())
        attempt { s -> "http://127.0.0.1:49153/loopdy-native-callback?state=$s&code=c" }
        assertEquals("different port", HermesException.Kind.RedirectRefused, run())
        attempt { s -> "http://127.0.0.1:49152/other?state=$s&code=c" }
        assertEquals("different path", HermesException.Kind.RedirectRefused, run())
        attempt { s -> "https://127.0.0.1:49152/loopdy-native-callback?state=$s&code=c" }
        assertEquals("different scheme", HermesException.Kind.RedirectRefused, run())
        passwordHost(login = { _, _ -> ScriptedHost.json("""{"ok":false,"next":"$callback?state=x&code=c"}""") })
        assertEquals("ok:false", invalid, run())
        passwordHost(login = { _, _ -> MockResponse().setResponseCode(401) })
        assertEquals(HermesException.Kind.InvalidCredentials, run())
        assertTrue("No code was ever exchanged", host.callsTo("/auth/native/token").isEmpty())
    }

    @Test fun theIdentityBehindTheTokenMustMatchEverywhere() {
        fun run(provider: String? = null) = kind { authenticator().signIn(SignInInput.Password(provider, "u", "p")) }
        passwordHost(token = { tokenReply(provider = "other") })
        assertEquals("The token's provider is not the selected one", HermesException.Kind.IdentityChanged, run("basic"))
        passwordHost(token = { tokenReply(provider = "other") })
        assertEquals("Not the only password provider either", HermesException.Kind.IdentityChanged, run())
        passwordHost(meReply = me(user = "someone-else"))
        assertEquals("/api/auth/me must agree with the token", HermesException.Kind.IdentityChanged, run())
        passwordHost(meReply = me(provider = "other"))
        assertEquals(HermesException.Kind.IdentityChanged, run())
        passwordHost(token = { MockResponse().setResponseCode(401) })
        assertEquals(HermesException.Kind.InvalidCredentials, run())
        passwordHost(token = { ScriptedHost.json("""{"token_type":"bearer","access_token":"a","provider":"basic","user_id":"u","expires_at":${now + 60}}""") })
        assertEquals(HermesException.Kind.InvalidResponse, run())
    }

    @Test fun theOneUseCodeIsNeverSentTwice() {
        passwordHost(token = { MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST) })
        assertEquals(HermesException.Kind.ConnectionFailed, kind { authenticator().signIn(SignInInput.Password(null, "u", "p")) })
        assertEquals(1, host.callsTo("/auth/native/token").size)
    }

    // Cancellation

    @Test fun cancellingASignInStagesNothingAndKeepsTheCurrentConnection() = runBlocking {
        val authenticator = authenticator()
        val existing = SavedConnection(host.endpoint, StoredAuth.DashboardSession("existing", true), null, null)
        store.replace(null, existing)
        authenticator.restoreForTest(existing)
        host.on("GET", "/") { MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE) }
        val attempt = async { authenticator.signIn(SignInInput.Dashboard) }
        var waited = 0
        while (host.callsTo("/").isEmpty() && waited++ < 300) delay(10)
        attempt.cancel()
        assertThrows(CancellationException::class.java) { runBlocking { attempt.await() } }
        assertEquals(existing, authenticator.savedConnection)
        assertEquals(existing, store.load(existing.authority))
    }

    @Test fun cancelAuthenticationEndsTheAttemptWithACancelledError() = runBlocking {
        host.on("GET", "/api/status", status(false))
        host.on("GET", "/") { MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE) }
        val authenticator = authenticator()
        val attempt = async { runCatching { authenticator.signIn(SignInInput.Dashboard) } }
        var waited = 0
        while (host.callsTo("/").isEmpty() && waited++ < 300) delay(10)
        authenticator.cancelAuthentication()
        val failure = attempt.await().exceptionOrNull()
        assertEquals(HermesException.Kind.Cancelled, (failure as HermesException).kind)
        assertNull(authenticator.savedConnection)
    }

    /** Adopts [saved] as the current connection the way a restore does, but without touching the host. */
    private suspend fun HermesAuthenticator.restoreForTest(saved: SavedConnection) {
        host.on("GET", "/api/status", status(false))
        host.on("GET", "/", ScriptedHost.dashboardPage("existing"))
        restore(saved)
        host.requests.clear()
        assertNotNull(savedConnection)
        TimeUnit.MILLISECONDS.sleep(0)
    }
}
