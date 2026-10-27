package app.bighelp.hermes

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Which Hermes credential, if any, a request carries. Tokens are validated before anything is sent. */
sealed interface HttpAuth {
    data object None : HttpAuth

    /** `Authorization: Bearer <token>` for a gated host. */
    class Bearer(val token: String) : HttpAuth {
        override fun toString() = "Bearer"
    }

    /** `X-Hermes-Session-Token: <token>` for an ungated dashboard. */
    class DashboardSession(val token: String) : HttpAuth {
        override fun toString() = "DashboardSession"
    }
}

/** Plugin routes take the context guard on POST: `If-Match` and a lowercase-UUID `X-Loopdy-Request-ID`. */
class NativeGuard(val etag: String, val requestId: String)

/**
 * One bounded HTTP request. [route] is application-owned and appended to the endpoint's prefix; [query]
 * values are encoded separately. Defaults match the contract: 1 MiB response budget, 20 s timeout.
 */
class HermesHttpRequest(
    val route: String,
    val method: String = "GET",
    val query: List<Pair<String, String>> = emptyList(),
    val body: JsonObject? = null,
    val auth: HttpAuth = HttpAuth.None,
    /** Only the password flow's `NAME=VALUE` PKCE cookie. There is no cookie jar. */
    val cookie: String? = null,
    val accept: String = "application/json",
    val maximumResponseBytes: Int = HermesHttpLimits.DEFAULT_RESPONSE_BYTES,
    val timeoutMillis: Long = HermesHttpLimits.DEFAULT_TIMEOUT_MILLIS,
    /** Lets one 302 from `/auth/native/authorize` through unfollowed. No other redirect is ever returned. */
    val allowAuthorizeRedirect: Boolean = false,
    val nativeGuard: NativeGuard? = null,
) {
    fun withAuth(auth: HttpAuth) = HermesHttpRequest(
        route, method, query, body, auth, cookie, accept, maximumResponseBytes, timeoutMillis,
        allowAuthorizeRedirect, nativeGuard,
    )
}

/** A completed HTTP exchange. Non-2xx statuses are returned, not thrown; map them with [requireSuccess]. */
class HttpResult(val status: Int, private val headerLines: List<Pair<String, String>>, val body: ByteArray) {
    fun header(name: String): String? = headerLines.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second
    fun headers(name: String): List<String> = headerLines.filter { it.first.equals(name, ignoreCase = true) }.map { it.second }
    val contentType: String get() = header("Content-Type")?.lowercase().orEmpty()

    /** Strict UTF-8, strict JSON (no duplicate keys, nesting ≤ 64). @throws HermesException InvalidResponse */
    fun json(): JsonElement = HermesHttpDecoding.json(body)
    fun jsonObject(): JsonObject = json() as? JsonObject ?: throw HermesException(HermesException.Kind.InvalidResponse)
    fun text(): String = HermesHttpDecoding.utf8(body)

    /** 2xx passes; everything else becomes the contract's generic category. */
    fun requireSuccess() {
        val kind = when (status) {
            in 200..299 -> return
            401, 403 -> HermesException.Kind.InvalidCredentials
            404, 405 -> HermesException.Kind.UnsupportedAuthentication
            429 -> HermesException.Kind.RateLimited
            in 500..599 -> HermesException.Kind.ServerUnavailable
            else -> HermesException.Kind.InvalidResponse
        }
        throw HermesException(kind)
    }

    /**
     * Something other than Hermes' own status answered: its Host-header guard, or a web page. Only fixed
     * categories reach the caller, never the body. 401, 403 and 5xx pages keep their own meaning.
     */
    fun requireHermesAnswer() {
        if (status == 400 && contentType.startsWith("application/json") &&
            (runCatching { jsonObject()["detail"] }.getOrNull() as? kotlinx.serialization.json.JsonPrimitive)
                ?.takeIf { it.isString }?.content?.startsWith("Invalid Host header") == true
        ) throw HermesException(HermesException.Kind.HostNameRefused)
        if (contentType.startsWith("text/html") && (status in 200..299 || status == 400)) {
            throw HermesException(HermesException.Kind.WebPageInsteadOfHermes, throughCloudflare = header("CF-RAY") != null)
        }
    }

    override fun toString() = "HttpResult($status, ${body.size} bytes)"
}

/** Bounded HTTP to one endpoint. No redirects, no cookies, no cache, no automatic retry. */
interface HermesHttp : AutoCloseable {
    /** The gate headers every request (and the WebSocket upgrade) carries. */
    val accessHeaders: AccessHeaders

    /**
     * @throws HermesException for a refused redirect, a Cloudflare Access denial, an oversize or invalid
     * request or response, a TLS or connection failure and a timeout. Cancelling the caller cancels the call.
     */
    suspend fun send(request: HermesHttpRequest): HttpResult
}
