package app.bighelp.hermes

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

/**
 * A loopback stand-in for one Hermes host: routes answer from lambdas, every request is recorded. It is a
 * scripted test double, not Hermes; real-host behavior is covered by the disposable-host probes.
 */
class ScriptedHost(private val prefix: String = "") : AutoCloseable {
    val server = MockWebServer()
    val requests = CopyOnWriteArrayList<RecordedRequest>()
    private val routes = ConcurrentHashMap<String, (RecordedRequest) -> MockResponse>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val path = request.path.orEmpty().substringBefore('?')
                val handler = routes["${request.method} $path"] ?: routes["* $path"]
                return handler?.invoke(request) ?: MockResponse().setResponseCode(404)
            }
        }
        server.start()
    }

    val endpoint: HermesEndpoint
        get() = HermesEndpoint.parse("http://127.0.0.1:${server.port}$prefix", allowPrivateHttp = true)

    fun on(method: String, route: String, handler: (RecordedRequest) -> MockResponse) {
        routes["$method $prefix$route"] = handler
    }

    fun on(route: String, handler: (RecordedRequest) -> MockResponse) {
        routes["* $prefix$route"] = handler
    }

    fun on(method: String, route: String, response: MockResponse) = on(method, route) { response }

    /** `"METHOD /route"` lines (the prefix removed), in arrival order. */
    val calls: List<String>
        get() = requests.map { "${it.method} ${it.path.orEmpty().substringBefore('?').removePrefix(prefix)}" }

    fun callsTo(route: String) = requests.filter { it.path.orEmpty().substringBefore('?') == "$prefix$route" }

    override fun close() = server.shutdown()

    companion object {
        fun json(body: String, code: Int = 200) =
            MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

        fun html(body: String) = MockResponse().setHeader("Content-Type", "text/html; charset=utf-8").setBody(body)

        fun dashboardPage(token: String) =
            html("<!doctype html><script>window.__HERMES_SESSION_TOKEN__=\"$token\";window.__HERMES_AUTH_REQUIRED__=false;</script>")
    }
}

/** A clock the test moves by hand. */
class TestClock(private var instant: java.time.Instant) : java.time.Clock() {
    override fun getZone(): java.time.ZoneId = java.time.ZoneOffset.UTC
    override fun withZone(zone: java.time.ZoneId?): java.time.Clock = this
    override fun instant(): java.time.Instant = instant
    fun advanceSeconds(seconds: Long) { instant = instant.plusSeconds(seconds) }
}
