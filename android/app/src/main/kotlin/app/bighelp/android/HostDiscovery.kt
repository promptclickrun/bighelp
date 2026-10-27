package app.bighelp.android

import app.bighelp.hermes.HermesEndpoint
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer

/**
 * Outcome of the public host check. A host that answers is [Available]: found, not connected, and no
 * sign-in, token or session has been requested of it.
 */
sealed interface DiscoveryResult {
    /** Nothing was sent: the one-time AI data agreement has not been given. */
    data object ConsentRequired : DiscoveryResult

    /** Unreachable, refused, redirected, oversized or not the documented shape. The reason is never kept. */
    data object Unavailable : DiscoveryResult

    data class Available(val authRequired: Boolean, val browserSignIn: Boolean) : DiscoveryResult
}

/** The seam [BighelpAppModel] calls, so state tests need no network. */
fun interface HostChecker {
    suspend fun check(endpoint: HermesEndpoint, consentGranted: Boolean): DiscoveryResult
}

/**
 * Consent-gated `GET /api/status` against one validated [HermesEndpoint]. It is the only network code in
 * the first milestone, and it takes no credential of any kind.
 *
 * The request carries no cookies, tokens or custom headers and follows no redirects (not even to the same
 * origin), so a proxy or sign-in page can never turn into a "found" host. The decoded body is capped at
 * [HostStatus.MAXIMUM_BYTES] and is never kept or logged, whatever it holds. Certificates are checked by
 * the platform; HTTPS is the default and plain HTTP exists only on an endpoint that already passed the
 * private-network opt-in in [HermesEndpoint.parse].
 */
class HostDiscovery(private val client: OkHttpClient = defaultClient) : HostChecker {
    override suspend fun check(endpoint: HermesEndpoint, consentGranted: Boolean): DiscoveryResult {
        if (!consentGranted) return DiscoveryResult.ConsentRequired
        val request = try {
            Request.Builder()
                .url(endpoint.httpUrl("/api/status").toString())
                .header("Accept", "application/json")
                .header("Cache-Control", "no-store")
                .build()
        } catch (_: IllegalArgumentException) {
            return DiscoveryResult.Unavailable
        }
        return client.newCall(request).answer()
    }

    private suspend fun Call.answer(): DiscoveryResult = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = continuation.resume(DiscoveryResult.Unavailable)

            override fun onResponse(call: Call, response: Response) {
                // Nothing thrown here may escape: it would end on OkHttp's thread and crash the app.
                val result = try {
                    response.use(::interpret)
                } catch (_: Exception) {
                    DiscoveryResult.Unavailable
                }
                continuation.resume(result)
            }
        })
    }

    private fun interpret(response: Response): DiscoveryResult {
        if (response.code != 200) return DiscoveryResult.Unavailable
        val body = response.body ?: return DiscoveryResult.Unavailable
        if (body.contentLength() > HostStatus.MAXIMUM_BYTES) return DiscoveryResult.Unavailable

        // One byte past the budget is enough to know the body is too large.
        val source = body.source()
        val buffer = Buffer()
        while (buffer.size <= HostStatus.MAXIMUM_BYTES) {
            if (source.read(buffer, HostStatus.MAXIMUM_BYTES + 1L - buffer.size) == -1L) break
        }
        if (buffer.size > HostStatus.MAXIMUM_BYTES) return DiscoveryResult.Unavailable

        val status = HostStatus.parse(buffer.readByteArray()) ?: return DiscoveryResult.Unavailable
        return DiscoveryResult.Available(status.authRequired, status.browserSignIn)
    }

    private companion object {
        val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .cookieJar(CookieJar.NO_COOKIES)
                .cache(null)
                .retryOnConnectionFailure(false)
                .connectTimeout(8, TimeUnit.SECONDS)
                .readTimeout(8, TimeUnit.SECONDS)
                .writeTimeout(8, TimeUnit.SECONDS)
                .callTimeout(15, TimeUnit.SECONDS)
                .build()
        }
    }
}
