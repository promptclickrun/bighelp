package app.bighelp.hermes

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Rotation, compare-and-replace, restore, commit, authenticated resend and gateway credentials against a
 * scripted loopback host. One store is shared between authenticators to model concurrent copies.
 */
class HermesAuthenticatorSessionTest {
    private val host = ScriptedHost("/hermes")
    private val store = InMemoryCredentialStore()
    private val clock = TestClock(java.time.Instant.ofEpochSecond(1_800_000_000))
    private val now = 1_800_000_000L
    private val resources = mutableListOf<AutoCloseable>()

    @After fun stop() {
        resources.forEach { it.close() }
        host.close()
    }

    private fun make(timings: AuthTimings = AuthTimings(), access: AccessHeaders = AccessHeaders.none): HermesAuthenticator =
        HermesAuthenticator(host.endpoint, OkHttpHermesHttp(host.endpoint, access).also { resources += it }, store, null, clock, timings = timings)
            .also { resources += it }

    private fun bearer(access: String = "old-access", refresh: String? = "refresh-1", expires: Long? = now - 60, user: String = "synthetic-user") =
        SavedConnection(host.endpoint, StoredAuth.Bearer(access, refresh, expires), "basic", user)

    private fun dashboard(token: String = "old-dash", automatic: Boolean = true) =
        SavedConnection(host.endpoint, StoredAuth.DashboardSession(token, automatic), null, null)

    /** An authenticator on a record already in the store, the way a reconnect or relaunch finds it. */
    private suspend fun restored(saved: SavedConnection, timings: AuthTimings = AuthTimings()): HermesAuthenticator {
        if (store.load(saved.authority) != saved) store.replace(store.load(saved.authority), saved)
        return make(timings).also { it.adoptForTest(saved, persisted = true) }
    }

    private fun kind(block: suspend () -> Unit) = assertThrows(HermesException::class.java) { runBlocking { block() } }.kind

    private fun renewed(refresh: String? = "refresh-2", access: String = "new-access", user: String = "synthetic-user", provider: String = "basic", expires: Long = now + 3_600) =
        ScriptedHost.json("""{"token_type":"Bearer","access_token":"$access","refresh_token":${refresh?.let { "\"$it\"" } ?: "null"},"provider":"$provider","user_id":"$user","expires_at":$expires}""")

    private val ping = HermesHttpRequest("/api/plugins/loopdy/native/context", maximumResponseBytes = 16_384)

    private fun pingRoute() = host.on("GET", "/api/plugins/loopdy/native/context") { request ->
        if (request.getHeader("Authorization") == "Bearer new-access") ScriptedHost.json("{}") else MockResponse().setResponseCode(401)
    }

    private fun refreshBodies() = host.callsTo("/auth/native/refresh").map { it.body.snapshot().utf8() }

    // Proactive and reactive renewal

    @Test fun anExpiringTokenIsRenewedBeforeTheRequestAndTheRecordIsReplacedDurably() = runBlocking {
        host.on("POST", "/auth/native/refresh", renewed())
        pingRoute()
        val saved = bearer(expires = now + 20) // inside the 30 s lead
        val authenticator = restored(saved)
        assertEquals(200, authenticator.authenticated(ping).status)
        assertEquals(listOf("POST /auth/native/refresh", "GET /api/plugins/loopdy/native/context"), host.calls)
        assertEquals("""{"refresh_token":"refresh-1","provider":"basic"}""", refreshBodies().single())
        val rotated = SavedConnection(host.endpoint, StoredAuth.Bearer("new-access", "refresh-2", now + 3_600), "basic", "synthetic-user")
        assertEquals(rotated, store.load(saved.authority))
        assertEquals(rotated, authenticator.savedConnection)
    }

    @Test fun aTokenOutsideTheLeadWindowIsNotRenewed() = runBlocking {
        host.on("GET", "/api/plugins/loopdy/native/context", ScriptedHost.json("{}"))
        val authenticator = restored(bearer(expires = now + 31))
        authenticator.authenticated(ping)
        assertEquals(listOf("GET /api/plugins/loopdy/native/context"), host.calls)
        assertEquals("Bearer old-access", host.requests.single().getHeader("Authorization"))
    }

    @Test fun manyConcurrentRequestsShareOneRenewalFlight() = runBlocking {
        host.on("POST", "/auth/native/refresh") { renewed().setBodyDelay(300, TimeUnit.MILLISECONDS) }
        pingRoute()
        val authenticator = restored(bearer())
        val results = (1..6).map { async { authenticator.authenticated(ping).status } }.awaitAll()
        assertEquals(List(6) { 200 }, results)
        assertEquals("Exactly one refresh went out", 1, host.callsTo("/auth/native/refresh").size)
        assertEquals(6, host.callsTo("/api/plugins/loopdy/native/context").size)
    }

    @Test fun aRenewalNeverStartsIfTheStoredRecordIsNoLongerTheOneInMemory() = runBlocking {
        val saved = bearer()
        val authenticator = restored(saved)
        val newer = bearer(access = "newer", refresh = "refresh-9", expires = now + 600)
        store.replace(saved, newer)
        host.on("POST", "/auth/native/refresh", renewed())
        assertEquals(HermesException.Kind.SecureStorageChanged, kind { authenticator.authenticated(ping) })
        assertEquals("The rotated token another copy saved was never resent", 0, host.callsTo("/auth/native/refresh").size)
        assertEquals(newer, store.load(saved.authority))
    }

    @Test fun aRejectedRenewalAsksForANewSignInAndWritesNothingEveryTime() = runBlocking {
        host.on("POST", "/auth/native/refresh", ScriptedHost.json("""{"error":"session_expired"}""", 401))
        val saved = bearer()
        val authenticator = restored(saved)
        repeat(2) { assertEquals(HermesException.Kind.AuthenticationRequired, kind { authenticator.authenticated(ping) }) }
        assertEquals("Hermes was asked each time; the person is not left waiting on a hidden pause", 2, host.callsTo("/auth/native/refresh").size)
        assertEquals(saved, store.load(saved.authority))
        assertEquals(saved, authenticator.savedConnection)
        assertEquals(HermesException.Kind.AuthenticationRequired, kind { restored(saved).authenticated(ping) })
        assertEquals(saved, store.load(saved.authority))
    }

    @Test fun aRejectedRenewalLeavesTheOtherCopysNewerSignIn() = runBlocking {
        val saved = bearer()
        var count = 0
        host.on("POST", "/auth/native/refresh") {
            if (++count == 1) renewed().setBodyDelay(800, TimeUnit.MILLISECONDS)
            else ScriptedHost.json("""{"error":"session_expired"}""", 401).setBodyDelay(100, TimeUnit.MILLISECONDS)
        }
        pingRoute()
        val winner = restored(saved)
        val loser = restored(saved)
        val winning = async { winner.authenticated(ping) }
        var waited = 0
        while (host.callsTo("/auth/native/refresh").isEmpty() && waited++ < 300) delay(10)
        assertEquals(HermesException.Kind.AuthenticationRequired, kind { loser.authenticated(ping) })
        assertEquals(200, winning.await().status)
        assertEquals("The winner could still save its new sign-in", "refresh-2", ((store.load(saved.authority)!!.auth) as StoredAuth.Bearer).refreshToken)
    }

    @Test fun anOutageKeepsTheTokenAndPausesFurtherRenewalsForAMoment() = runBlocking {
        var calls = 0
        host.on("POST", "/auth/native/refresh") { if (++calls == 1) MockResponse().setResponseCode(503) else renewed() }
        pingRoute()
        val saved = bearer()
        val authenticator = restored(saved, AuthTimings(refusedRenewalPauseMillis = 400))
        assertEquals(HermesException.Kind.ServerUnavailable, kind { authenticator.authenticated(ping) })
        assertEquals("Same answer inside the pause, no new renewal", HermesException.Kind.ServerUnavailable, kind { authenticator.authenticated(ping) })
        assertEquals(1, host.callsTo("/auth/native/refresh").size)
        assertEquals("The refresh token is kept", saved, store.load(saved.authority))
        delay(450)
        assertEquals(200, authenticator.authenticated(ping).status)
        assertEquals(2, host.callsTo("/auth/native/refresh").size)
        assertEquals("refresh-2", ((store.load(saved.authority)!!.auth) as StoredAuth.Bearer).refreshToken)
    }

    @Test fun rateLimitsAndProxyErrorsAreRefusalsThatKeepTheTokenAndAProxyChallengeIsNotASignInEnd() = runBlocking {
        val saved = bearer()
        store.replace(null, saved)
        host.on("POST", "/auth/native/refresh", MockResponse().setResponseCode(429))
        assertEquals(HermesException.Kind.RateLimited, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        host.on("POST", "/auth/native/refresh", MockResponse().setResponseCode(502))
        assertEquals(HermesException.Kind.ServerUnavailable, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        host.on("POST", "/auth/native/refresh", ScriptedHost.html("no").setResponseCode(401).addHeader("WWW-Authenticate", "Basic realm=\"proxy\""))
        val challenged = kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) }
        assertNotEquals("A proxy's challenge is not Hermes ending the sign-in", HermesException.Kind.AuthenticationRequired, challenged)
        assertEquals(saved, store.load(saved.authority))
    }

    @Test fun aRenewalCutByTheNetworkIsNotRememberedAndTheTokenStaysForTheNextTry() = runBlocking {
        var calls = 0
        host.on("POST", "/auth/native/refresh") { if (++calls == 1) MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST) else renewed() }
        pingRoute()
        val saved = bearer()
        val authenticator = restored(saved)
        assertEquals(HermesException.Kind.ConnectionFailed, kind { authenticator.authenticated(ping) })
        assertEquals(saved, store.load(saved.authority))
        assertEquals("No pause after a network error: it retries at once", 200, authenticator.authenticated(ping).status)
        assertEquals(
            "The same refresh token went out twice",
            listOf("""{"refresh_token":"refresh-1","provider":"basic"}""", """{"refresh_token":"refresh-1","provider":"basic"}"""),
            refreshBodies(),
        )
    }

    @Test fun aRenewalThatChangesThePrincipalOrIsMalformedIsNotSaved() = runBlocking {
        val saved = bearer()
        store.replace(null, saved)
        host.on("POST", "/auth/native/refresh", renewed(user = "someone-else"))
        assertEquals(HermesException.Kind.IdentityChanged, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        host.on("POST", "/auth/native/refresh", renewed(provider = "other"))
        assertEquals(HermesException.Kind.IdentityChanged, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        host.on("POST", "/auth/native/refresh", ScriptedHost.json("""{"token_type":"Bearer"}"""))
        assertEquals(HermesException.Kind.InvalidResponse, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        host.on("POST", "/auth/native/refresh", renewed(expires = now - 5))
        assertEquals(HermesException.Kind.InvalidResponse, kind { make().apply { adoptForTest(saved, true) }.authenticated(ping) })
        assertEquals(saved, store.load(saved.authority))
    }

    @Test fun withoutARefreshTokenThereIsNothingToSendAndTheSignInIsOver() = runBlocking {
        val saved = bearer(refresh = null)
        val authenticator = restored(saved)
        assertEquals(HermesException.Kind.AuthenticationRequired, kind { authenticator.authenticated(ping) })
        assertEquals(0, host.callsTo("/auth/native/refresh").size)
    }

    @Test fun aStorageFailureAfterTheHostRotatedIsReportedAndNothingElseChanges() = runBlocking {
        val saved = bearer()
        val flaky = object : CredentialStore by store {
            override suspend fun replace(expected: SavedConnection?, next: SavedConnection) = throw IOException("disk full /secret/path")
        }
        store.replace(null, saved)
        host.on("POST", "/auth/native/refresh", renewed())
        val authenticator = HermesAuthenticator(host.endpoint, OkHttpHermesHttp(host.endpoint).also { resources += it }, flaky, null, clock).also { resources += it }
        authenticator.adoptForTest(saved, persisted = true)
        val failure = assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticated(ping) } }
        assertEquals(HermesException.Kind.SecureStorageUnavailable, failure.kind)
        assertFalse("/secret/path" in failure.message.orEmpty() + failure.toString())
        assertEquals("The in-memory record is not advanced past what is durable", saved, authenticator.savedConnection)
    }

    @Test fun aStagedSignInRotatesInMemoryOnlyAndCommitPersistsTheLatest() = runBlocking {
        host.on("POST", "/auth/native/refresh", renewed())
        pingRoute()
        val staged = bearer()
        val authenticator = make()
        authenticator.adoptForTest(staged, persisted = false)
        assertEquals(200, authenticator.authenticated(ping).status)
        assertNull("Staging never touches the store", store.load(staged.authority))
        val rotated = authenticator.savedConnection!!
        assertEquals("new-access", (rotated.auth as StoredAuth.Bearer).accessToken)

        authenticator.commit(expected = null)
        assertEquals(rotated, store.load(rotated.authority))
        assertTrue(authenticator.isPersisted)
        authenticator.commit(expected = null) // already persisted: no second write, no failure
    }

    // Commit

    @Test fun commitWritesOnlyWhenTheCallersFenceStillHoldsAndReadsBackTheRecord() = runBlocking {
        val staged = dashboard()
        val authenticator = make()
        authenticator.adoptForTest(staged, persisted = false)
        assertEquals(HermesException.Kind.Cancelled, kind { authenticator.commit(null) { false } })
        assertNull(store.load(staged.authority))
        authenticator.commit(null) { true }
        assertEquals(staged, store.load(staged.authority))
    }

    @Test fun commitFailsWhenAnotherRecordAlreadyOwnsTheAuthorityOrTheStoreLies() = runBlocking {
        val staged = bearer(expires = now + 3_600)
        store.replace(null, bearer(access = "existing", expires = now + 100))
        val authenticator = make().apply { adoptForTest(staged, persisted = false) }
        assertEquals(HermesException.Kind.SecureStorageChanged, kind { authenticator.commit(expected = null) })
        authenticator.commit(expected = bearer(access = "existing", expires = now + 100)) // replacing the exact old record works
        assertEquals(staged, store.load(staged.authority))

        val otherAccount = bearer(user = "someone-else")
        assertEquals(
            "Expectation of another principal is refused before any write",
            HermesException.Kind.IdentityChanged,
            kind { make().apply { adoptForTest(staged.let { bearer(access = "x", expires = now + 1_000) }, false) }.commit(expected = otherAccount) },
        )

        val liar = object : CredentialStore by InMemoryCredentialStore() {
            override suspend fun load(authority: CredentialAuthority): SavedConnection? = null
        }
        val lied = HermesAuthenticator(host.endpoint, OkHttpHermesHttp(host.endpoint).also { resources += it }, liar, null, clock).also { resources += it }
        lied.adoptForTest(dashboard("t"), persisted = false)
        assertEquals("A write that cannot be read back does not count", HermesException.Kind.SecureStorageUnavailable, kind { lied.commit(null) })
        assertFalse(lied.isPersisted)
    }

    // Restore

    @Test fun restoreChecksTheStoreTheModeAndTheIdentity() = runBlocking {
        val saved = bearer(expires = now + 3_600)
        store.replace(null, saved)
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":true,"auth_flows":["native_pkce"]}"""))
        host.on("GET", "/api/auth/me", ScriptedHost.json("""{"provider":"basic","user_id":"synthetic-user"}"""))
        val authenticator = make()
        authenticator.restore(saved)
        assertEquals(listOf("GET /api/status", "GET /api/auth/me"), host.calls)
        assertEquals("Bearer old-access", host.callsTo("/api/auth/me").single().getHeader("Authorization"))
        assertTrue(authenticator.isPersisted)

        host.on("GET", "/api/auth/me", ScriptedHost.json("""{"provider":"basic","user_id":"another"}"""))
        assertEquals(HermesException.Kind.IdentityChanged, kind { make().restore(saved) })
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":false}"""))
        assertEquals("A gated credential on an ungated host", HermesException.Kind.AuthModeChanged, kind { make().restore(saved) })
    }

    @Test fun restoreRefusesAStaleSnapshotAWrongEndpointAndAnInvalidRecord() = runBlocking {
        val saved = bearer(expires = now + 3_600)
        store.replace(null, bearer(access = "newer", expires = now + 3_600))
        assertEquals(HermesException.Kind.SecureStorageChanged, kind { make().restore(saved) })
        val elsewhere = SavedConnection(HermesEndpoint.parse("http://127.0.0.1:1/other", true), StoredAuth.DashboardSession("t", true), null, null)
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { make().restore(elsewhere) })
        assertEquals(HermesException.Kind.SavedConnectionInvalid, kind { make().restore(SavedConnection(host.endpoint, StoredAuth.Bearer("a", null, null), null, null)) })
        assertEquals("Nothing reached the host", 0, host.requests.size)
    }

    @Test fun restoreRenewsWhenMeSaysTheAccessTokenIsDead() = runBlocking {
        val saved = bearer(expires = now + 3_600)
        store.replace(null, saved)
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":true}"""))
        host.on("GET", "/api/auth/me", MockResponse().setResponseCode(401))
        host.on("POST", "/auth/native/refresh", renewed())
        make().restore(saved)
        assertEquals(listOf("GET /api/status", "GET /api/auth/me", "POST /auth/native/refresh"), host.calls)
        assertEquals("new-access", (store.load(saved.authority)!!.auth as StoredAuth.Bearer).accessToken)
    }

    @Test fun restoreRereadsAnAutomaticDashboardTokenButNeverReplacesAManualOne() = runBlocking {
        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":false}"""))
        host.on("GET", "/", ScriptedHost.dashboardPage("restarted-token"))
        val automatic = dashboard("old-dash", automatic = true)
        store.replace(null, automatic)
        val authenticator = make()
        authenticator.restore(automatic)
        assertEquals(StoredAuth.DashboardSession("restarted-token", true), store.load(automatic.authority)!!.auth)
        assertEquals(store.load(automatic.authority), authenticator.savedConnection)

        host.requests.clear()
        val manual = dashboard("manual-token", automatic = false)
        store.delete(store.load(automatic.authority)!!)
        store.replace(null, manual)
        make().restore(manual)
        assertEquals(listOf("GET /api/status"), host.calls)
        assertEquals(manual, store.load(manual.authority))

        host.on("GET", "/api/status", ScriptedHost.json("""{"auth_required":true}"""))
        assertEquals(HermesException.Kind.AuthModeChanged, kind { make().restore(manual) })
    }

    // Authenticated resend

    @Test fun aDashboardTokenTurnedAwayIsReadAgainAndTheRequestSentOnce() = runBlocking {
        host.on("GET", "/", ScriptedHost.dashboardPage("new-dash"))
        host.on("GET", "/api/plugins/loopdy/native/context") { r ->
            if (r.getHeader("X-Hermes-Session-Token") == "new-dash") ScriptedHost.json("{}") else MockResponse().setResponseCode(401)
        }
        val saved = dashboard()
        val authenticator = restored(saved)
        assertEquals(200, authenticator.authenticated(ping).status)
        assertEquals(listOf("GET /api/plugins/loopdy/native/context", "GET /", "GET /api/plugins/loopdy/native/context"), host.calls)
        assertEquals(StoredAuth.DashboardSession("new-dash", true), store.load(saved.authority)!!.auth)
    }

    @Test fun aBearerTurnedAwayIsRenewedAndTheRequestSentOnceMoreNeverTwice() = runBlocking {
        host.on("POST", "/auth/native/refresh", renewed())
        host.on("GET", "/api/plugins/loopdy/native/context", MockResponse().setResponseCode(401))
        val authenticator = restored(bearer(expires = now + 3_600))
        assertEquals("The second 401 is returned, not looped", 401, authenticator.authenticated(ping).status)
        assertEquals(
            listOf("GET /api/plugins/loopdy/native/context", "POST /auth/native/refresh", "GET /api/plugins/loopdy/native/context"),
            host.calls,
        )
    }

    @Test fun otherStatusesAndChallengesAreReturnedOnceWithoutRenewal() = runBlocking {
        val authenticator = restored(bearer(expires = now + 3_600))
        host.on("GET", "/api/plugins/loopdy/native/context", MockResponse().setResponseCode(404))
        assertEquals(404, authenticator.authenticated(ping).status)
        host.on("GET", "/api/plugins/loopdy/native/context", MockResponse().setResponseCode(401).addHeader("WWW-Authenticate", "Basic realm=\"p\""))
        assertEquals(401, authenticator.authenticated(ping).status)
        assertEquals(2, host.requests.size)
        val noRefresh = restored(bearer(access = "other", refresh = null, expires = now + 3_600).let { SavedConnection(host.endpoint, it.auth, "basic", "other-user") })
        host.on("GET", "/api/plugins/loopdy/native/context", MockResponse().setResponseCode(401))
        host.requests.clear()
        assertEquals("Nothing to renew", 401, noRefresh.authenticated(ping).status)
        assertEquals(1, host.requests.size)
    }

    @Test fun aRequestWhoseTokenAnotherRequestAlreadyRenewedIsResentWithoutAnotherRenewal() = runBlocking {
        host.on("POST", "/auth/native/refresh", renewed())
        host.on("GET", "/api/plugins/loopdy/native/context") { r ->
            when (r.getHeader("Authorization")) {
                "Bearer new-access" -> ScriptedHost.json("{}")
                else -> MockResponse().setResponseCode(401).setBodyDelay(200, TimeUnit.MILLISECONDS)
            }
        }
        val authenticator = restored(bearer(expires = now + 3_600))
        val results = (1..3).map { async { authenticator.authenticated(ping).status } }.awaitAll()
        assertEquals(List(3) { 200 }, results)
        assertEquals(1, host.callsTo("/auth/native/refresh").size)
    }

    // Uncertain outcome

    @Test fun aMutationLostAfterDispatchIsATypedUncertainOutcomeAndIsNeverResent() = runBlocking {
        val authenticator = restored(bearer(expires = now + 3_600))
        host.on("POST", "/api/plugins/loopdy/native/goals", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        val post = HermesHttpRequest("/api/plugins/loopdy/native/goals", "POST", body = buildJsonObject { put("title", "t") })
        val failure = assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticatedJson(post) } }
        assertEquals(HermesException.Kind.OutcomeUnknown, failure.kind)
        assertTrue(failure.outcomeUnknown)
        assertEquals(1, host.callsTo("/api/plugins/loopdy/native/goals").size)

        val get = assertThrows(HermesException::class.java) {
            runBlocking {
                host.on("GET", "/api/plugins/loopdy/native/context", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
                authenticator.authenticatedJson(ping)
            }
        }
        assertEquals("A read is simply a failure", HermesException.Kind.ConnectionFailed, get.kind)
        assertFalse(get.outcomeUnknown)
    }

    @Test fun definitiveRejectionsAndPreSendFailuresOfAMutationAreNotUncertain() = runBlocking {
        val authenticator = restored(bearer(expires = now + 3_600))
        val route = "/api/plugins/loopdy/native/goals"
        val post = HermesHttpRequest(route, "POST", body = buildJsonObject { put("title", "t") })
        host.on("POST", route, ScriptedHost.json("""{"detail":"nope"}""", 422))
        val rejected = assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticatedJson(post) } }
        assertEquals(HermesException.Kind.InvalidResponse, rejected.kind)
        assertFalse(rejected.outcomeUnknown)
        host.on("POST", route, MockResponse().setResponseCode(502))
        assertEquals("A proxy 502 may have reached Hermes", HermesException.Kind.OutcomeUnknown,
            assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticatedJson(post) } }.kind)
        host.on("POST", route, ScriptedHost.json("not json"))
        assertEquals("A 200 whose answer cannot be read", HermesException.Kind.OutcomeUnknown,
            assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticatedJson(post) } }.kind)
        val before = host.requests.size
        val oversize = HermesHttpRequest(route, "POST", body = buildJsonObject { put("x", "y".repeat(HermesHttpLimits.MAXIMUM_BODY_BYTES)) })
        val certain = assertThrows(HermesException::class.java) { runBlocking { authenticator.authenticatedJson(oversize) } }
        assertEquals(HermesException.Kind.MessageTooLarge, certain.kind)
        assertFalse("Nothing was sent, so the outcome is known", certain.outcomeUnknown)
        assertEquals(before, host.requests.size)
        host.on("POST", route, ScriptedHost.json("""{"ok":true}"""))
        assertEquals("""{"ok":true}""", authenticator.authenticatedJson(post).toString())
    }

    @Test fun aRouteRefusalHookRunsBeforeTheGenericMapping() = runBlocking {
        val authenticator = restored(bearer(expires = now + 3_600))
        host.on("PATCH", "/api/sessions/s1", ScriptedHost.json("""{"detail":"revision_conflict"}""", 409))
        val failure = assertThrows(HermesException::class.java) {
            runBlocking {
                authenticator.authenticatedJson(HermesHttpRequest("/api/sessions/s1", "PATCH", body = buildJsonObject { put("title", "t") })) { r ->
                    if (r.status == 409) HermesException(HermesException.Kind.RpcRejected, code = 409L, refusal = "revision_conflict") else null
                }
            }
        }
        assertEquals(HermesException.Kind.RpcRejected, failure.kind)
        assertEquals(409L, failure.code)
        assertFalse("A definitive 409 is not an unknown outcome", failure.outcomeUnknown)
    }

    // Gateway credentials and health

    @Test fun aDashboardSocketCarriesTheTokenInTheQueryAndTheHeaderAndTheGate() = runBlocking {
        val access = AccessHeaders.of(host.endpoint, AccessCredential.proxyBasic("u", "p"), listOf(CustomHeader.of("X-Gate", "g")))
        val authenticator = make(access = access).apply { adoptForTest(dashboard("tok+en/1"), persisted = true) }
        val request = authenticator.socketRequest()
        assertEquals("ws://127.0.0.1:${host.server.port}/hermes/api/ws?token=tok%2Ben%2F1", request.url)
        assertEquals(mapOf("Authorization" to "Basic dTpw", "X-Gate" to "g", "X-Hermes-Session-Token" to "tok+en/1"), request.headers)
        assertNull(request.requiredSubprotocol)
        assertFalse("tok" in request.toString())
        assertEquals("No network call for a dashboard socket", 0, host.requests.size)
    }

    @Test fun everyBearerSocketMintsAFreshTicketAndOffersItAsASubprotocol() = runBlocking {
        var n = 0
        host.on("POST", "/api/auth/ws-ticket") { r ->
            assertEquals("Bearer old-access", r.getHeader("Authorization"))
            assertEquals("{}", r.body.readUtf8())
            ScriptedHost.json("""{"ticket":"ticket_${++n}","ttl_seconds":30}""")
        }
        val authenticator = restored(bearer(expires = now + 3_600))
        val first = authenticator.socketRequest()
        val second = authenticator.socketRequest()
        assertEquals("ws://127.0.0.1:${host.server.port}/hermes/api/ws", first.url)
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.ticket_1", first.headers["Sec-WebSocket-Protocol"])
        assertEquals("hermes-gateway-v1, hermes-gateway-ticket.ticket_2", second.headers["Sec-WebSocket-Protocol"])
        assertEquals("hermes-gateway-v1", first.requiredSubprotocol)
        assertNull("No provider token in the gateway request", first.headers["Authorization"])
        assertFalse("ticket_1" in first.toString() || "old-access" in first.url)
        assertEquals(2, host.callsTo("/api/auth/ws-ticket").size)
    }

    @Test fun aTicketRequestTurnedAwayRenewsOnceAndMintsAgain() = runBlocking {
        host.on("POST", "/auth/native/refresh", renewed())
        host.on("POST", "/api/auth/ws-ticket") { r ->
            if (r.getHeader("Authorization") == "Bearer new-access") ScriptedHost.json("""{"ticket":"t1","ttl_seconds":30}""") else MockResponse().setResponseCode(401)
        }
        val authenticator = restored(bearer(expires = now + 3_600))
        assertTrue(authenticator.socketRequest().headers["Sec-WebSocket-Protocol"]!!.endsWith("ticket.t1"))
        assertEquals(listOf("POST /api/auth/ws-ticket", "POST /auth/native/refresh", "POST /api/auth/ws-ticket"), host.calls)

        host.on("POST", "/api/auth/ws-ticket", ScriptedHost.json("""{"ticket":"t1","ttl_seconds":999}"""))
        assertEquals(HermesException.Kind.InvalidResponse, kind { authenticator.socketRequest() })
    }

    @Test fun healthNeedsOkTrueABooleanAuthModeAndASmallBody() = runBlocking {
        val authenticator = restored(bearer(expires = now + 3_600))
        host.on("GET", "/api/health", ScriptedHost.json("""{"ok":true,"auth_required":true,"extra":1}"""))
        authenticator.requireHealth()
        assertEquals("Bearer old-access", host.callsTo("/api/health").single().getHeader("Authorization"))
        listOf("""{"ok":false,"auth_required":true}""", """{"ok":"true","auth_required":true}""", """{"ok":true}""", """{"ok":true,"auth_required":"yes"}""", "{}")
            .forEach {
                host.on("GET", "/api/health", ScriptedHost.json(it))
                assertEquals(it, HermesException.Kind.AuthenticationRequired, kind { authenticator.requireHealth() })
            }
        host.on("GET", "/api/health", ScriptedHost.json("""{"ok":true,"auth_required":true,"pad":"${"x".repeat(16_400)}"}"""))
        assertEquals(HermesException.Kind.MessageTooLarge, kind { authenticator.requireHealth() })
    }

    @Test fun closingWaitsForARenewalOnItsWayInsteadOfCuttingItOff() = runBlocking {
        host.on("POST", "/auth/native/refresh") { renewed().setBodyDelay(500, TimeUnit.MILLISECONDS) }
        pingRoute()
        val saved = bearer()
        val authenticator = restored(saved)
        val request = async { runCatching { authenticator.authenticated(ping) } }
        var waited = 0
        while (host.callsTo("/auth/native/refresh").isEmpty() && waited++ < 300) delay(10)
        request.cancel()
        authenticator.settlePendingRenewal(5_000)
        assertEquals("The renewal finished and its new token was saved", "refresh-2", (store.load(saved.authority)!!.auth as StoredAuth.Bearer).refreshToken)
    }
}
