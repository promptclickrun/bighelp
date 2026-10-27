package app.bighelp.hermes

import java.io.IOException
import java.io.InterruptedIOException
import java.net.URI
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.CookieJar
import okhttp3.Dispatcher
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer

/**
 * [HermesHttp] over OkHttp, for one endpoint.
 *
 * Isolated by construction: no cookie jar, cache, redirect, authenticator or automatic retry, and a
 * private connection pool. Every HTTP/1.x request asks the host to close afterwards (`Connection: close`),
 * so no request ever rides an idle pooled socket that a host or proxy has already closed. With
 * `retryOnConnectionFailure(false)` such a socket would otherwise fail a request that never left the
 * device. Nothing here resends a request, whatever its method.
 *
 * Errors name only a [HermesException.Kind]: never the URL, a header, the query or a body.
 */
class OkHttpHermesHttp(
    val endpoint: HermesEndpoint,
    override val accessHeaders: AccessHeaders = AccessHeaders.none,
) : HermesHttp {
    private val client = HermesOkHttp.baseClient()
    private val closed = AtomicBoolean(false)

    internal val activeCalls: Int get() = client.dispatcher.runningCallsCount()

    override suspend fun send(request: HermesHttpRequest): HttpResult {
        if (closed.get()) throw HermesException(HermesException.Kind.NotConnected)
        val prepared = prepare(request)
        val call = client.newBuilder()
            .callTimeout(prepared.timeoutMillis, TimeUnit.MILLISECONDS)
            .readTimeout(prepared.timeoutMillis, TimeUnit.MILLISECONDS)
            .build()
            .newCall(prepared.okRequest)
        return try {
            call.execute(prepared)
        } catch (e: HermesException) {
            // Past this point bytes may have left the device: a mutation's outcome is unknown, not failed.
            throw if (request.method != "GET" && !e.outcomeUnknown) e.asOutcomeUnknown() else e
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    private class Prepared(
        val okRequest: Request,
        val maximumBytes: Int,
        val timeoutMillis: Long,
        val allowAuthorizeRedirect: Boolean,
        val sentAccessToken: Boolean,
    )

    private fun prepare(request: HermesHttpRequest): Prepared {
        val method = request.method
        if (method !in METHODS) throw HermesException(HermesException.Kind.InvalidResponse)
        val ceiling = HermesHttpLimits.responseCeiling(request.route, method, request.query)
        if (request.maximumResponseBytes !in 1..ceiling) throw HermesException(HermesException.Kind.MessageTooLarge)
        val url = try {
            val base = endpoint.httpUrl(request.route).toString().toHttpUrl().newBuilder()
            request.query.forEach { (name, value) -> base.addQueryParameter(name, value) }
            base.build()
        } catch (_: HermesEndpointException) {
            throw HermesException(HermesException.Kind.InvalidEndpoint)
        } catch (_: IllegalArgumentException) {
            throw HermesException(HermesException.Kind.InvalidEndpoint)
        }

        val headers = Headers.Builder()
        accessHeaders.values.forEach { (name, value) -> headers.addUnsafeNonAscii(name, value) }
        val builder = Request.Builder().url(url).headers(headers.build())
            .header("Accept", request.accept)
            .header("Cache-Control", "no-store")
            // A fresh socket per HTTP/1.x request; HTTP/2 ignores the header.
            .header("Connection", "close")

        request.nativeGuard?.let { guard ->
            if (!allowsNativeGuard(request.route, method) || request.auth is HttpAuth.None || request.cookie != null ||
                !LOWERCASE_UUID.matches(guard.requestId) || guard.etag.isEmpty() || guard.etag.any { it.code !in 0x20..0x7e }
            ) throw HermesException(HermesException.Kind.InvalidResponse)
            builder.header("If-Match", guard.etag).header("X-Loopdy-Request-ID", guard.requestId)
        }
        when (val auth = request.auth) {
            HttpAuth.None -> Unit
            is HttpAuth.Bearer -> {
                HermesSecrets.requireToken(auth.token)
                builder.header("Authorization", "Bearer ${auth.token}")
            }
            is HttpAuth.DashboardSession -> {
                HermesSecrets.requireToken(auth.token)
                builder.header("X-Hermes-Session-Token", auth.token)
            }
        }
        request.cookie?.let { builder.header("Cookie", it) }

        val body: RequestBody? = when {
            request.body != null -> {
                if (method == "GET") throw HermesException(HermesException.Kind.InvalidResponse)
                val bytes = request.body.toString().toByteArray(Charsets.UTF_8)
                if (bytes.size > HermesHttpLimits.requestBodyLimit(request.route, method)) {
                    throw HermesException(HermesException.Kind.MessageTooLarge)
                }
                bytes.toRequestBody(JSON)
            }
            method == "GET" -> null
            else -> ByteArray(0).toRequestBody(null)
        }
        builder.method(method, body)
        return Prepared(
            builder.build(), request.maximumResponseBytes, HermesHttpLimits.clampTimeoutMillis(request.timeoutMillis),
            request.allowAuthorizeRedirect, accessHeaders.values.containsKey("CF-Access-Client-Id"),
        )
    }

    private suspend fun Call.execute(prepared: Prepared): HttpResult = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(if (closed.get()) HermesException(HermesException.Kind.Cancelled) else map(e))
            }

            override fun onResponse(call: Call, response: Response) {
                // Nothing thrown here may escape: it would end on OkHttp's thread and crash the app.
                val result = try {
                    response.use { interpret(it, prepared) }
                } catch (e: HermesException) {
                    continuation.resumeWithException(e)
                    return
                } catch (e: Throwable) {
                    continuation.resumeWithException(if (closed.get()) HermesException(HermesException.Kind.Cancelled) else map(e))
                    return
                }
                continuation.resume(result)
            }
        })
    }

    private fun interpret(response: Response, prepared: Prepared): HttpResult {
        val status = response.code
        val contentType = response.header("Content-Type")?.lowercase().orEmpty()
        if (isCloudflareAccessDenial(status, contentType, response.header("CF-RAY") != null, prepared.sentAccessToken) ||
            isCloudflareRedirect(status, response.header("Location"))
        ) throw HermesException(HermesException.Kind.CloudflareAccessDenied)
        if (response.request.url != prepared.okRequest.url) throw HermesException(HermesException.Kind.RedirectRefused)
        if (status in 300..399 && !(prepared.allowAuthorizeRedirect && status == 302)) {
            throw HermesException(HermesException.Kind.RedirectRefused)
        }
        val body = response.body ?: throw HermesException(HermesException.Kind.InvalidResponse)
        if (body.contentLength() > prepared.maximumBytes) throw HermesException(HermesException.Kind.MessageTooLarge)

        // The budget counts decoded bytes as they arrive: a declared length is never trusted, and a
        // compressed body is measured after decompression. One byte past the budget is enough to refuse.
        val source = body.source()
        val buffer = Buffer()
        while (buffer.size <= prepared.maximumBytes) {
            if (source.read(buffer, prepared.maximumBytes + 1L - buffer.size) == -1L) break
        }
        if (buffer.size > prepared.maximumBytes) throw HermesException(HermesException.Kind.MessageTooLarge)

        val lines = ArrayList<Pair<String, String>>(response.headers.size)
        for (index in 0 until response.headers.size) lines += response.headers.name(index) to response.headers.value(index)
        return HttpResult(status, lines, buffer.readByteArray())
    }

    internal companion object {
        private val METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE")
        private val JSON = "application/json".toMediaType()
        private val LOWERCASE_UUID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        /** Plugin routes take the context guard on POST; telemetry takes it on PUT. */
        fun allowsNativeGuard(route: String, method: String): Boolean =
            route.startsWith("/api/plugins/loopdy/native/") &&
                (method == "POST" || (method == "PUT" && route == "/api/plugins/loopdy/native/telemetry"))

        /** Cloudflare Access answers a rejected service token with its own HTML block page; Hermes answers JSON. */
        fun isCloudflareAccessDenial(status: Int, contentType: String, hasRay: Boolean, sentAccessToken: Boolean): Boolean =
            sentAccessToken && (status == 401 || status == 403) && contentType.startsWith("text/html") && hasRay

        /** A redirect to Cloudflare Access' own login means the gate refused, not that Hermes moved. */
        fun isCloudflareRedirect(status: Int, location: String?): Boolean {
            if (status !in 300..399 || location == null) return false
            val host = try {
                URI(location).host?.lowercase()
            } catch (_: Exception) {
                null
            } ?: return false
            return host == "cloudflareaccess.com" || host.endsWith(".cloudflareaccess.com")
        }

        /** Never wraps the cause: platform messages can carry the URL. */
        fun map(error: Throwable): HermesException = when (error) {
            is HermesException -> error
            is SSLException -> HermesException(HermesException.Kind.TlsRequired)
            is InterruptedIOException -> HermesException(HermesException.Kind.TimedOut)
            else -> HermesException(HermesException.Kind.ConnectionFailed)
        }
    }
}

/** The one place OkHttp is configured, so HTTP and WebSocket share the same isolation rules. */
internal object HermesOkHttp {
    /** No redirects, cookies, cache, authenticators or automatic retries, and a private pool. */
    fun baseClient(): OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .cookieJar(CookieJar.NO_COOKIES)
        .cache(null)
        .retryOnConnectionFailure(false)
        .connectionPool(ConnectionPool(HermesHttpLimits.CONNECTIONS_PER_HOST, 30, TimeUnit.SECONDS))
        .dispatcher(Dispatcher().apply { maxRequests = 64; maxRequestsPerHost = HermesHttpLimits.CONNECTIONS_PER_HOST })
        .connectTimeout(HermesHttpLimits.DEFAULT_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        .readTimeout(HermesHttpLimits.DEFAULT_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        .writeTimeout(HermesHttpLimits.DEFAULT_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        .callTimeout(HermesHttpLimits.LONGEST_REQUEST_MILLIS, TimeUnit.MILLISECONDS)
        .build()
}
