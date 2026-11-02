package app.bighelp.hermes

import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Clock
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Signs in to one Hermes endpoint and keeps the sign-in alive, using the host's stock APIs only.
 *
 * **Staging.** [signIn] returns a candidate and holds it in memory; it never writes the
 * [CredentialStore]. The owner connects the gateway with it and calls [commit] only after `gateway.ready`
 * and its own host-selection fence, so a superseded or failed Connect cannot replace a saved sign-in. A
 * restored sign-in ([restore]) is already persisted, and every rotation of it is a durable compare-and-
 * replace against the exact record it started from; a stale authenticator fails instead of overwriting.
 *
 * **Rotation.** Renewal is single-flight. It sends the saved refresh token and replaces the record only
 * after the new session verifies and keeps the same principal. The record's refresh token survives every
 * failure; a 401 from Hermes means "sign in again" and writes nothing (a newer record saved by another
 * authenticator is never erased). There is no server-side logout: signing out is deleting the local record.
 *
 * Nothing sent here is ever retried automatically except the documented single resend of an authenticated
 * request after a renewal, which relies on Hermes refusing a bad sign-in before the route runs.
 */
class HermesAuthenticator(
    val endpoint: HermesEndpoint,
    private val http: HermesHttp,
    private val store: CredentialStore,
    private val browser: BrowserLauncher? = null,
    private val clock: Clock = Clock.systemUTC(),
    private val random: SecureRandom = SecureRandom(),
    private val timings: AuthTimings = AuthTimings(),
) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private var current: SavedConnection? = null
    private var persisted = false
    private var refreshFlight: Deferred<Unit>? = null
    private var refusedRenewal: Pair<Long, HermesException>? = null
    private var signInAttempt: Job? = null

    /** The in-memory sign-in: staged after [signIn], persisted after [commit] or [restore]. */
    val savedConnection: SavedConnection? get() = synchronized(lock) { current }

    /** True once the current record is known to be in the [CredentialStore]. */
    val isPersisted: Boolean get() = synchronized(lock) { persisted }

    private fun nowSeconds() = clock.millis() / 1_000

    /** Test seam: adopt [saved] as current without any network or store access. */
    internal fun adoptForTest(saved: SavedConnection, persisted: Boolean) {
        synchronized(lock) { current = saved; this.persisted = persisted; refusedRenewal = null }
    }

    // Discovery

    /** Public status plus, when native PKCE is on offer, the provider list (never needed to stay on offer). */
    suspend fun discover(): AuthStatus = discoverStatus(enrichProviders = true)

    private suspend fun discoverStatus(enrichProviders: Boolean): AuthStatus {
        val response = http.send(HermesHttpRequest("/api/status"))
        response.requireHermesAnswer()
        response.requireSuccess()
        val status = HermesAuthParsers.status(response.jsonObject())
        if (!status.supportsNativePkce || !enrichProviders) return status
        val providers = try {
            val reply = http.send(HermesHttpRequest("/api/auth/providers"))
            reply.requireSuccess()
            HermesAuthParsers.providers(reply.jsonObject())
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Presentation metadata cannot disable a flow the status already advertises.
            emptyList()
        }
        return AuthStatus(status.authRequired, status.flows, providers)
    }

    // Sign-in

    /**
     * Signs in and stages the result in memory only. Cancelling the caller, or [cancelAuthentication],
     * ends the attempt, cancels its HTTP calls and the browser listener, and leaves the current
     * connection and the store untouched.
     * @throws HermesException for every refusal; never with credentials in the message.
     */
    suspend fun signIn(input: SignInInput): SavedConnection {
        cancelAuthentication()
        currentCoroutineContext().ensureActive()
        val attempt = scope.async { performSignIn(input) }
        synchronized(lock) { signInAttempt = attempt }
        try {
            val candidate = attempt.await()
            synchronized(lock) {
                if (signInAttempt !== attempt) throw HermesException(HermesException.Kind.Cancelled)
                current = candidate
                persisted = false
                refusedRenewal = null
            }
            return candidate
        } catch (e: CancellationException) {
            attempt.cancel()
            if (currentCoroutineContext().isActive) throw HermesException(HermesException.Kind.Cancelled)
            throw e
        } catch (e: HermesException) {
            throw e
        } catch (_: Exception) {
            throw HermesException(HermesException.Kind.InvalidResponse)
        } finally {
            synchronized(lock) { if (signInAttempt === attempt) signInAttempt = null }
        }
    }

    /** Cancels the exact in-flight sign-in (and its browser wait), not the saved host session. */
    fun cancelAuthentication() {
        val attempt = synchronized(lock) { signInAttempt.also { signInAttempt = null } }
        attempt?.cancel()
    }

    private suspend fun performSignIn(input: SignInInput): SavedConnection {
        val status = discoverStatus(enrichProviders = input is SignInInput.Password || input is SignInInput.Browser)
        val gated = status.authRequired
        val candidate = when (input) {
            is SignInInput.Token -> {
                HermesSecrets.requireToken(input.token)
                if (gated) {
                    val identity = verifiedIdentity(input.token)
                    SavedConnection(endpoint, StoredAuth.Bearer(input.token, null, identity.expiresAt), identity.provider, identity.userId)
                } else {
                    SavedConnection(endpoint, StoredAuth.DashboardSession(input.token, automatic = false), null, null)
                }
            }
            SignInInput.Dashboard -> {
                if (gated) throw HermesException(HermesException.Kind.AuthModeChanged)
                SavedConnection(endpoint, StoredAuth.DashboardSession(dashboardToken(), automatic = true), null, null)
            }
            is SignInInput.Password -> {
                if (!gated) throw HermesException(HermesException.Kind.UnsupportedAuthentication)
                passwordSignIn(input, status)
            }
            is SignInInput.Browser -> {
                if (!gated) throw HermesException(HermesException.Kind.UnsupportedAuthentication)
                browserSignIn(input.provider, status)
            }
        }
        candidate.validate()
        return candidate
    }

    private class Identity(val provider: String, val userId: String, val expiresAt: Long?)

    private suspend fun verifiedIdentity(accessToken: String): Identity {
        val response = http.send(HermesHttpRequest("/api/auth/me", auth = HttpAuth.Bearer(accessToken)))
        response.requireSuccess()
        val body = response.jsonObject()
        val provider = body["provider"].stringOrNull()?.takeIf { it.isNotEmpty() }
        val user = body["user_id"].stringOrNull()?.takeIf { it.isNotEmpty() }
        if (provider == null || user == null) throw HermesException(HermesException.Kind.InvalidResponse)
        val expiry = (body["expires_at"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()?.takeIf { it.isFinite() }
        return Identity(provider, user, expiry?.toLong())
    }

    private fun requireIdentity(provider: String?, userId: String?, saved: SavedConnection) {
        if (provider != saved.provider || userId != saved.userId) throw HermesException(HermesException.Kind.IdentityChanged)
    }

    private suspend fun dashboardToken(): String {
        val response = http.send(HermesHttpRequest("/", accept = "text/html"))
        response.requireSuccess()
        if (!response.contentType.startsWith("text/html")) throw HermesException(HermesException.Kind.UnsupportedAuthentication)
        return HermesAuthParsers.dashboardToken(response.body)
    }

    private fun randomSecret(): String = base64Url(ByteArray(32).also(random::nextBytes))

    private fun base64Url(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    private fun challenge(verifier: String) = base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8)))

    private suspend fun passwordSignIn(input: SignInInput.Password, status: AuthStatus): SavedConnection {
        if (input.username.isEmpty() || utf8Length(input.username) > 1_024 ||
            input.password.isEmpty() || utf8Length(input.password) > 16_384
        ) throw HermesException(HermesException.Kind.InvalidCredentials)
        val passwordProviders = status.passwordProviders.map { it.name }
        val provider = if (input.provider != null) {
            if (input.provider !in passwordProviders) throw HermesException(HermesException.Kind.UnsupportedAuthentication)
            input.provider
        } else {
            passwordProviders.singleOrNull() ?: throw HermesException(
                if (passwordProviders.isEmpty()) HermesException.Kind.UnsupportedAuthentication else HermesException.Kind.AmbiguousPasswordProvider,
            )
        }
        val verifier = randomSecret()
        val state = randomSecret()
        // No listener exists for this flow: the login answer carries the callback in JSON, checked locally.
        val authorize = http.send(
            HermesHttpRequest(
                "/auth/native/authorize",
                query = listOf(
                    "provider" to provider, "code_challenge" to challenge(verifier), "code_challenge_method" to "S256",
                    "redirect_uri" to PASSWORD_CALLBACK, "state" to state,
                ),
                allowAuthorizeRedirect = true,
            ),
        )
        val location = authorize.header("Location")
        if (authorize.status != 302 || location == null || !resolvesToLogin(location)) {
            throw HermesException(HermesException.Kind.UnsupportedAuthentication)
        }
        val cookie = HermesAuthParsers.pkceCookie(authorize.headers("Set-Cookie"), endpoint, nowSeconds())

        val login = http.send(
            HermesHttpRequest(
                "/auth/password-login", "POST",
                body = buildJsonObject {
                    put("provider", provider); put("username", input.username); put("password", input.password); put("next", "")
                },
                cookie = cookie,
            ),
        )
        login.requireSuccess()
        val reply = login.jsonObject()
        if ((reply["ok"] as? JsonPrimitive)?.takeIf { !it.isString }?.content != "true") throw HermesException(HermesException.Kind.InvalidResponse)
        val code = codeFromCallback(reply["next"].stringOrNull() ?: throw HermesException(HermesException.Kind.InvalidResponse), state)

        val exchange = http.send(
            HermesHttpRequest("/auth/native/token", "POST", body = buildJsonObject { put("code", code); put("code_verifier", verifier) }),
        )
        exchange.requireSuccess()
        val saved = HermesAuthParsers.nativeSession(exchange.jsonObject(), endpoint, clock.millis())
        if (saved.provider != provider) throw HermesException(HermesException.Kind.IdentityChanged)
        val token = (saved.auth as StoredAuth.Bearer).accessToken
        val identity = verifiedIdentity(token)
        requireIdentity(identity.provider, identity.userId, saved)
        return saved
    }

    /** `Location` resolved against the authorize URL must be exactly this endpoint's `/login`. */
    private fun resolvesToLogin(location: String): Boolean = try {
        val base = endpoint.httpUrl("/auth/native/authorize")
        base.resolve(URI(location)).normalize() == endpoint.httpUrl("/login").normalize()
    } catch (_: URISyntaxException) {
        false
    }

    /** `next` must be the fixed callback with exactly one `state` (ours) and one nonempty `code`. */
    private fun codeFromCallback(next: String, state: String): String {
        val query = next.indexOf('?').takeIf { it >= 0 }?.let { next.substring(it + 1) }
            ?: throw HermesException(HermesException.Kind.InvalidResponse)
        val items = query.split('&').map { item ->
            val equals = item.indexOf('=')
            if (equals < 0) throw HermesException(HermesException.Kind.InvalidResponse)
            try {
                URLDecoder.decode(item.substring(0, equals), "UTF-8") to URLDecoder.decode(item.substring(equals + 1), "UTF-8")
            } catch (_: IllegalArgumentException) {
                throw HermesException(HermesException.Kind.InvalidResponse)
            }
        }
        val code = items.singleOrNull { it.first == "code" }?.second
        if (items.size != 2 || items.count { it.first == "state" } != 1 || items.single { it.first == "state" }.second != state ||
            code.isNullOrEmpty()
        ) throw HermesException(HermesException.Kind.InvalidResponse)
        if (next.substringBefore('?') != PASSWORD_CALLBACK) throw HermesException(HermesException.Kind.RedirectRefused)
        return code
    }

    private suspend fun browserSignIn(provider: String?, status: AuthStatus): SavedConnection {
        if (!status.supportsNativePkce) throw HermesException(HermesException.Kind.UnsupportedAuthentication)
        if (provider != null && (provider.isEmpty() || utf8Length(provider) > 128 || provider.any { it.code !in 0x21..0x7e })) {
            throw HermesException(HermesException.Kind.UnsupportedAuthentication)
        }
        val launcher = browser ?: throw HermesException(HermesException.Kind.BrowserAuthenticationUnavailable)
        val verifier = randomSecret()
        val state = randomSecret()
        val callbackPath = "/loopdy-native-callback/${randomSecret()}"
        val code = LoopbackCallbackListener.bind(callbackPath, state, timings).use { listener ->
            val query = mutableListOf(
                "code_challenge" to challenge(verifier), "code_challenge_method" to "S256",
                "redirect_uri" to listener.callbackUrl, "state" to state,
            )
            provider?.let { query += "provider" to it }
            val authorizeUrl = authorizeUrl(query)
            listener.awaitCode { launcher.open(authorizeUrl) }
        }
        // The code is a one-use mutation: after any uncertainty the person starts a new sign-in.
        val exchange = try {
            http.send(HermesHttpRequest("/auth/native/token", "POST", body = buildJsonObject { put("code", code); put("code_verifier", verifier) }))
        } catch (e: HermesException) {
            throw when (e.kind) {
                HermesException.Kind.ConnectionFailed, HermesException.Kind.TimedOut, HermesException.Kind.Disconnected,
                HermesException.Kind.Cancelled, HermesException.Kind.InvalidResponse, HermesException.Kind.MessageTooLarge ->
                    HermesException(HermesException.Kind.NativeTokenExchangeUncertain, outcomeUnknown = true)
                else -> e
            }
        }
        exchange.requireSuccess()
        // The code is spent. A 2xx whose answer cannot be read leaves the outcome unknown, like a lost one.
        val saved = try {
            HermesAuthParsers.nativeSession(exchange.jsonObject(), endpoint, clock.millis())
        } catch (e: HermesException) {
            throw if (e.kind == HermesException.Kind.InvalidResponse) {
                HermesException(HermesException.Kind.NativeTokenExchangeUncertain, outcomeUnknown = true)
            } else e
        }
        if (provider != null && saved.provider != provider) throw HermesException(HermesException.Kind.IdentityChanged)
        val identity = verifiedIdentity((saved.auth as StoredAuth.Bearer).accessToken)
        requireIdentity(identity.provider, identity.userId, saved)
        return saved
    }

    private fun authorizeUrl(query: List<Pair<String, String>>): String {
        val encoded = query.joinToString("&") { (name, value) -> "${encode(name)}=${encode(value)}" }
        return "${endpoint.httpUrl("/auth/native/authorize")}?$encoded"
    }

    private fun encode(text: String) = URLEncoder.encode(text, "UTF-8").replace("+", "%20")

    /**
     * Persists the staged sign-in. Call it only after `gateway.ready` and your own "this host is still the
     * selected one" check ([stillCurrent]); a false answer writes nothing. [expected] is the record you
     * loaded before signing in (null for a new computer); anything else in the store fails the commit.
     * The write is read back before it counts.
     */
    suspend fun commit(expected: SavedConnection? = null, stillCurrent: () -> Boolean = { true }) {
        val (candidate, alreadyPersisted) = synchronized(lock) { current to persisted }
        if (candidate == null) throw HermesException(HermesException.Kind.NotConnected)
        if (alreadyPersisted) return
        if (!stillCurrent()) throw HermesException(HermesException.Kind.Cancelled)
        if (expected != null && expected.authority != candidate.authority) throw HermesException(HermesException.Kind.IdentityChanged)
        candidate.validate()
        replaceDurably(expected, candidate)
        synchronized(lock) { if (current == candidate) persisted = true }
    }

    // Restore and rotation

    /**
     * Adopts a record read from the store and rechecks it against the host. [saved] must still equal the
     * stored record, so a stale snapshot never overwrites a newer rotation or account.
     */
    suspend fun restore(saved: SavedConnection) {
        saved.validate()
        if (saved.endpoint != endpoint) throw HermesException(HermesException.Kind.SavedConnectionInvalid)
        if (loadStored(saved.authority) != saved) throw HermesException(HermesException.Kind.SecureStorageChanged)
        synchronized(lock) { current = saved; persisted = true; refusedRenewal = null }
        verifyModeAndSession()
    }

    /**
     * Rediscovers the host's mode and rechecks the identity before every reconnect. A switch between
     * dashboard and provider authentication is refused rather than sending the old credential another way.
     */
    suspend fun verifyModeAndSession() {
        val saved = savedConnection ?: throw HermesException(HermesException.Kind.NotConnected)
        val gated = discoverStatus(enrichProviders = false).authRequired
        when (val auth = saved.auth) {
            is StoredAuth.DashboardSession -> {
                if (gated) throw HermesException(HermesException.Kind.AuthModeChanged)
                if (auth.automatic) {
                    val token = dashboardToken()
                    if (savedConnection != saved) throw HermesException(HermesException.Kind.SecureStorageChanged)
                    if (token != auth.token) rotate(saved, SavedConnection(endpoint, StoredAuth.DashboardSession(token, true), null, null))
                }
            }
            is StoredAuth.Bearer -> {
                if (!gated) throw HermesException(HermesException.Kind.AuthModeChanged)
                val expiry = auth.expiresAtEpochSeconds
                if (expiry != null && expiry <= nowSeconds() + RENEW_AHEAD_SECONDS) {
                    refresh()
                } else {
                    try {
                        val identity = verifiedIdentity(auth.accessToken)
                        requireIdentity(identity.provider, identity.userId, saved)
                    } catch (e: HermesException) {
                        if (e.kind != HermesException.Kind.InvalidCredentials) throw e
                        refresh()
                    }
                }
            }
        }
    }

    private suspend fun refresh() {
        val flight = synchronized(lock) {
            refreshFlight ?: run {
                refusedRenewal?.let { (at, error) ->
                    if (System.nanoTime() - at < timings.refusedRenewalPauseMillis * 1_000_000) throw error
                }
                val started = scope.async(start = CoroutineStart.LAZY) { performRefresh() }
                refreshFlight = started
                started.invokeOnCompletion { synchronized(lock) { if (refreshFlight === started) refreshFlight = null } }
                started
            }
        }
        flight.start()
        flight.await()
    }

    private suspend fun performRefresh() {
        val (start, wasPersisted) = synchronized(lock) { current to persisted }
        val auth = start?.auth as? StoredAuth.Bearer
        val refreshToken = auth?.refreshToken ?: throw HermesException(HermesException.Kind.AuthenticationRequired)
        // Another authenticator on the same record may have renewed already; sending the token it rotated
        // would look like reuse to the provider and end the whole sign-in. Check first.
        if (wasPersisted && loadStored(start.authority) != start) throw HermesException(HermesException.Kind.SecureStorageChanged)

        val response = http.send(
            HermesHttpRequest(
                "/auth/native/refresh", "POST",
                body = buildJsonObject { put("refresh_token", refreshToken); put("provider", start.provider.orEmpty()) },
            ),
        )
        // Hermes' own 401 (no challenge header) says the provider ended this sign-in. Nothing is written:
        // another authenticator may be saving a newer record right now. A new sign-in replaces it.
        if (response.status == 401 && response.header("WWW-Authenticate") == null) {
            throw HermesException(HermesException.Kind.AuthenticationRequired)
        }
        if (response.status !in 200..299) {
            val refusal = if (response.status == 503) {
                HermesException(HermesException.Kind.ServerUnavailable)
            } else {
                try {
                    response.requireSuccess()
                    HermesException(HermesException.Kind.InvalidResponse)
                } catch (e: HermesException) {
                    e
                }
            }
            synchronized(lock) { refusedRenewal = System.nanoTime() to refusal }
            throw refusal
        }
        val refreshed = HermesAuthParsers.nativeSession(response.jsonObject(), endpoint, clock.millis())
        requireIdentity(refreshed.provider, refreshed.userId, start)
        rotate(start, refreshed, wasPersisted)
        synchronized(lock) { refusedRenewal = null }
    }

    /** Durable compare-and-replace when persisted; memory only for a staged sign-in. */
    private suspend fun rotate(old: SavedConnection, replacement: SavedConnection, wasPersisted: Boolean = isPersisted) {
        if (wasPersisted) replaceDurably(old, replacement)
        synchronized(lock) { if (current == old) current = replacement }
    }

    private suspend fun loadStored(authority: CredentialAuthority): SavedConnection? = try {
        store.load(authority)
    } catch (e: CancellationException) {
        throw e
    } catch (e: HermesException) {
        throw e
    } catch (_: Exception) {
        throw HermesException(HermesException.Kind.SecureStorageUnavailable)
    }

    private suspend fun replaceDurably(expected: SavedConnection?, next: SavedConnection) {
        try {
            store.replace(expected, next)
        } catch (_: StaleCredentialException) {
            throw HermesException(HermesException.Kind.SecureStorageChanged)
        } catch (e: CancellationException) {
            throw e
        } catch (e: HermesException) {
            throw e
        } catch (_: Exception) {
            throw HermesException(HermesException.Kind.SecureStorageUnavailable)
        }
        // External storage: read the exact record back rather than trusting the write call.
        if (loadStored(next.authority) != next) throw HermesException(HermesException.Kind.SecureStorageUnavailable)
    }

    /** Gives a renewal already on its way time to finish and save before the connection is torn down. */
    suspend fun settlePendingRenewal(withinMillis: Long = timings.renewalSettleMillis) {
        val flight = synchronized(lock) { refreshFlight } ?: return
        withTimeoutOrNull(withinMillis) { runCatching { flight.await() } }
    }

    // Authenticated requests

    private class Tokens(val bearer: String?, val dashboard: String?) {
        val auth: HttpAuth
            get() = when {
                bearer != null -> HttpAuth.Bearer(bearer)
                dashboard != null -> HttpAuth.DashboardSession(dashboard)
                else -> HttpAuth.None
            }
    }

    private suspend fun authenticatedTokens(): Tokens {
        val saved = savedConnection ?: throw HermesException(HermesException.Kind.AuthenticationRequired)
        saved.validate()
        val auth = saved.auth
        if (auth is StoredAuth.Bearer) {
            val expiry = auth.expiresAtEpochSeconds
            if (expiry != null && expiry <= nowSeconds() + RENEW_AHEAD_SECONDS) refresh()
        }
        return when (val now = (savedConnection ?: throw HermesException(HermesException.Kind.AuthenticationRequired)).auth) {
            is StoredAuth.Bearer -> Tokens(now.accessToken, null)
            is StoredAuth.DashboardSession -> Tokens(null, now.token)
        }
    }

    /**
     * Sends [request] with the current credential (any `auth` already on it is replaced). On HTTP 401
     * **without** `WWW-Authenticate` it renews the sign-in once (or re-reads a changed automatic dashboard
     * token) and resends once; Hermes checks the sign-in before any route runs, so the first attempt never
     * started. A 401 with `WWW-Authenticate` is a proxy's challenge and is returned as is. Any other status,
     * including 4xx and 5xx, is returned for the caller to interpret.
     */
    suspend fun authenticated(request: HermesHttpRequest): HttpResult {
        val tokens = authenticatedTokens()
        val response = http.send(request.withAuth(tokens.auth))
        if (response.status != 401 || response.header("WWW-Authenticate") != null || !renewSignIn(tokens)) return response
        return http.send(request.withAuth(authenticatedTokens().auth))
    }

    /**
     * [authenticated] plus the generic interpretation: 2xx JSON is returned; other statuses throw their
     * category. A mutation (any method but GET) that ends without a definitive rejection status
     * (400, 401, 403, 404, 405, 409, 422, 429) throws [HermesException.Kind.OutcomeUnknown] with
     * [HermesException.outcomeUnknown] set, and is never resent. [refusal] may turn a response into a
     * route-specific refusal before the generic mapping.
     */
    suspend fun authenticatedJson(request: HermesHttpRequest, refusal: ((HttpResult) -> HermesException?)? = null): JsonElement {
        val mutation = request.method != "GET"
        val response = try {
            authenticated(request)
        } catch (e: HermesException) {
            // The HTTP layer flags a failure after dispatch; one before (a bad token, an oversize body) is certain.
            throw if (mutation && e.outcomeUnknown) HermesException(HermesException.Kind.OutcomeUnknown, outcomeUnknown = true) else e
        }
        try {
            refusal?.invoke(response)?.let { throw it }
            response.requireSuccess()
            return response.json()
        } catch (e: HermesException) {
            if (mutation && response.status !in DEFINITIVE_REJECTIONS) {
                throw HermesException(HermesException.Kind.OutcomeUnknown, outcomeUnknown = true)
            }
            throw e
        }
    }

    private suspend fun renewSignIn(turnedAway: Tokens): Boolean {
        val saved = savedConnection ?: return false
        return when (val auth = saved.auth) {
            is StoredAuth.Bearer -> {
                if (auth.accessToken != turnedAway.bearer) return true
                if (synchronized(lock) { refreshFlight } == null && auth.refreshToken == null) return false
                try {
                    refresh()
                    true
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    false
                }
            }
            is StoredAuth.DashboardSession -> {
                if (auth.token != turnedAway.dashboard) return true
                if (!auth.automatic) return false
                val fresh = try {
                    dashboardToken()
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    return false
                }
                if (fresh == auth.token || savedConnection != saved) return false
                try {
                    rotate(saved, SavedConnection(endpoint, StoredAuth.DashboardSession(fresh, true), null, null))
                    true
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    false
                }
            }
        }
    }

    // Gateway credentials and health

    /**
     * The gateway upgrade: a dashboard token rides the query **and** `X-Hermes-Session-Token`; a bearer
     * session mints a **fresh** single-use ticket for every call and offers it as a second subprotocol.
     * Gate headers always ride along; no cookie is ever added. Never log the result.
     */
    suspend fun socketRequest(): SocketRequest {
        val saved = savedConnection ?: throw HermesException(HermesException.Kind.NotConnected)
        val headers = LinkedHashMap<String, String>(http.accessHeaders.values)
        return when (val auth = saved.auth) {
            is StoredAuth.DashboardSession -> {
                headers["X-Hermes-Session-Token"] = auth.token
                SocketRequest("${endpoint.webSocketUrl}?token=${encode(auth.token)}", headers, null)
            }
            is StoredAuth.Bearer -> {
                val ticket = mintTicket()
                headers["Sec-WebSocket-Protocol"] = "${SocketRequest.GATEWAY_SUBPROTOCOL}, ${SocketRequest.TICKET_SUBPROTOCOL_PREFIX}$ticket"
                SocketRequest(endpoint.webSocketUrl, headers, SocketRequest.GATEWAY_SUBPROTOCOL)
            }
        }
    }

    private suspend fun mintTicket(): String {
        fun bearer(): String = (savedConnection?.auth as? StoredAuth.Bearer)?.accessToken
            ?: throw HermesException(HermesException.Kind.NotConnected)
        val first = bearer()
        var response = http.send(HermesHttpRequest("/api/auth/ws-ticket", "POST", body = JsonObject(emptyMap()), auth = HttpAuth.Bearer(first)))
        if (response.status == 401) {
            refresh()
            response = http.send(HermesHttpRequest("/api/auth/ws-ticket", "POST", body = JsonObject(emptyMap()), auth = HttpAuth.Bearer(bearer())))
        }
        response.requireSuccess()
        return HermesAuthParsers.ticket(response.jsonObject())
    }

    /** `GET /api/health` through the authenticated path: `ok` must be true and `auth_required` a Boolean. */
    suspend fun requireHealth() {
        val response = authenticated(HermesHttpRequest("/api/health", maximumResponseBytes = 16_384))
        response.requireSuccess()
        val body = response.jsonObject()
        fun flag(key: String) = (body[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content
        if (flag("ok") != "true" || (flag("auth_required") != "true" && flag("auth_required") != "false")) {
            throw HermesException(HermesException.Kind.AuthenticationRequired)
        }
    }

    /** Ends sign-in attempts and renewals and closes HTTP. The store is untouched; there is no server logout. */
    override fun close() {
        cancelAuthentication()
        scope.cancel()
        http.close()
    }

    private fun JsonElement?.stringOrNull(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private companion object {
        const val PASSWORD_CALLBACK = "http://127.0.0.1:49152/loopdy-native-callback"
        const val RENEW_AHEAD_SECONDS = 30L
        val DEFINITIVE_REJECTIONS = setOf(400, 401, 403, 404, 405, 409, 422, 429)
    }
}
