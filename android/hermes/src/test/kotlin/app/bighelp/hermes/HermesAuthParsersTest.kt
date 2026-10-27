package app.bighelp.hermes

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class HermesAuthParsersTest {
    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject
    private fun kind(block: () -> Unit) = assertThrows(HermesException::class.java) { block() }.kind
    private val invalid = HermesException.Kind.InvalidResponse

    // Dashboard bootstrap

    private fun page(vararg scripts: String, outside: String = "") =
        "<!doctype html><html><head><title>t</title></head><body>$outside${scripts.joinToString("") { "<script>$it</script>" }}</body></html>"

    private fun token(html: String) = HermesAuthParsers.dashboardToken(html.toByteArray())

    @Test fun bootstrapReadsTheOneTokenAndTheUngatedMarker() {
        assertEquals(
            "synthetic-dashboard-token",
            token(page("window.__HERMES_SESSION_TOKEN__ = \"synthetic-dashboard-token\";\nwindow.__HERMES_AUTH_REQUIRED__ = false;")),
        )
        assertEquals(
            "Whitespace and separate script elements are fine",
            "abc",
            token(page("  window.__HERMES_SESSION_TOKEN__=\"abc\" ;", "x=1; window.__HERMES_AUTH_REQUIRED__=false;")),
        )
        assertEquals("a\"b", token(page("window.__HERMES_SESSION_TOKEN__=\"a\\u0022b\";window.__HERMES_AUTH_REQUIRED__=false;")))
        assertEquals("tok", token("<SCRIPT type=\"module\">window.__HERMES_SESSION_TOKEN__=\"tok\";window.__HERMES_AUTH_REQUIRED__=false;</SCRIPT >"))
    }

    @Test fun bootstrapRefusesAnythingButExactlyOneTokenInAScriptAndAFalseMarker() {
        val marker = "window.__HERMES_AUTH_REQUIRED__=false;"
        val unsupported = HermesException.Kind.UnsupportedAuthentication
        assertEquals("no token", unsupported, kind { token(page(marker)) })
        assertEquals("no marker", unsupported, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"t\";")) })
        assertEquals("gated page", unsupported, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"t\";window.__HERMES_AUTH_REQUIRED__=true;")) })
        assertEquals("two tokens", unsupported, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"a\";window.__HERMES_SESSION_TOKEN__=\"b\";$marker")) })
        assertEquals("two markers", unsupported, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"a\";$marker$marker")) })
        assertEquals(
            "only a script element counts",
            unsupported,
            kind { token(page(marker, outside = "<p>window.__HERMES_SESSION_TOKEN__=\"t\";</p><div title='window.__HERMES_SESSION_TOKEN__=\"t\";'></div>")) },
        )
        assertEquals("an unrelated variable", unsupported, kind { token(page("window.OTHER=\"t\";$marker")) })
        assertEquals(
            "a token assignment embedded in other code is not a bare assignment",
            unsupported,
            kind { token(page("var x = {a: window.__HERMES_SESSION_TOKEN__=\"t\";};$marker")) },
        )
    }

    @Test fun bootstrapValidatesTheTokenAndTheBytes() {
        val marker = "window.__HERMES_AUTH_REQUIRED__=false;"
        assertEquals(HermesException.Kind.InvalidCredentials, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"has space\";$marker")) })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"\";$marker")) })
        assertEquals(HermesException.Kind.InvalidCredentials, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"${"x".repeat(16_385)}\";$marker")) })
        assertEquals(invalid, kind { token(page("window.__HERMES_SESSION_TOKEN__=\"\\x\";$marker")) })
        assertEquals(invalid, kind { HermesAuthParsers.dashboardToken(byteArrayOf(0xC3.toByte(), 0x28)) })
        assertEquals(invalid, kind { HermesAuthParsers.dashboardToken(ByteArray(1_048_577) { 'a'.code.toByte() }) })
    }

    // Status

    @Test fun statusRequiresABooleanAndBoundsTheFlows() {
        val none = HermesAuthParsers.status(obj("""{"auth_required":false}"""))
        assertEquals(false, none.authRequired)
        assertEquals(emptyList<String>(), none.flows)
        assertEquals(emptyList<String>(), HermesAuthParsers.status(obj("""{"auth_required":true,"auth_flows":null}""")).flows)
        val gated = HermesAuthParsers.status(obj("""{"auth_required":true,"auth_flows":["cookie","native_pkce","future-flow"],"other":1}"""))
        assertEquals(listOf("cookie", "native_pkce", "future-flow"), gated.flows)
        assertEquals(true, gated.supportsNativePkce)
        assertEquals("Not offered on an ungated host", false, HermesAuthParsers.status(obj("""{"auth_required":false,"auth_flows":["native_pkce"]}""")).supportsNativePkce)
        assertEquals("Exact string only", false, HermesAuthParsers.status(obj("""{"auth_required":true,"auth_flows":["Native_PKCE"]}""")).supportsNativePkce)

        listOf(
            """{}""", """{"auth_required":"true"}""", """{"auth_required":1}""", """{"auth_required":null}""",
            """{"auth_required":true,"auth_flows":"native_pkce"}""", """{"auth_required":true,"auth_flows":[1]}""",
            """{"auth_required":true,"auth_flows":[""]}""", """{"auth_required":true,"auth_flows":["a","a"]}""",
            """{"auth_required":true,"auth_flows":["${"f".repeat(129)}"]}""",
            """{"auth_required":true,"auth_flows":[${(1..33).joinToString { "\"f$it\"" }}]}""",
        ).forEach { assertEquals(it, invalid, kind { HermesAuthParsers.status(obj(it)) }) }
        HermesAuthParsers.status(obj("""{"auth_required":true,"auth_flows":[${(1..32).joinToString { "\"f$it\"" }},]}""".replace(",]", "]")))
        HermesAuthParsers.status(obj("""{"auth_required":true,"auth_flows":["${"f".repeat(128)}"]}"""))
    }

    @Test fun providersAreBoundedAndUnique() {
        val list = HermesAuthParsers.providers(obj("""{"providers":[{"name":"basic","display_name":"Password","supports_password":true},{"name":"sso","supports_password":false}]}"""))
        assertEquals(listOf(AuthProvider("basic", "Password", true), AuthProvider("sso", "sso", false)), list)
        listOf(
            """{}""", """{"providers":{}}""",
            """{"providers":[{"name":"a","supports_password":"yes"}]}""", """{"providers":[{"name":"a"}]}""",
            """{"providers":[{"name":"","supports_password":true}]}""", """{"providers":[{"name":"a b","supports_password":true}]}""",
            """{"providers":[{"name":"é","supports_password":true}]}""", """{"providers":[{"name":"${"n".repeat(257)}","supports_password":true}]}""",
            """{"providers":[{"name":"a","supports_password":true},{"name":"a","supports_password":false}]}""",
            """{"providers":[{"name":"a","display_name":"","supports_password":true}]}""",
            """{"providers":[{"name":"a","display_name":"x\u0007y","supports_password":true}]}""",
            """{"providers":[{"name":"a","display_name":"${"d".repeat(513)}","supports_password":true}]}""",
            """{"providers":[${(1..65).joinToString { "{\"name\":\"p$it\",\"supports_password\":true}" }}]}""",
            """{"providers":[7]}""",
        ).forEach { assertEquals(it.take(60), invalid, kind { HermesAuthParsers.providers(obj(it)) }) }
        assertEquals(64, HermesAuthParsers.providers(obj("""{"providers":[${(1..64).joinToString { "{\"name\":\"p$it\",\"supports_password\":true}" }}]}""")).size)
    }

    // PKCE cookie

    private val now = 1_800_000_000L
    private val httpsRoot = HermesEndpoint.parse("hermes.example")
    private val httpsPrefix = HermesEndpoint.parse("hermes.example/hermes")
    private val httpRoot = HermesEndpoint.parse("http://192.168.1.5:9119", allowPrivateHttp = true)
    private val httpPrefix = HermesEndpoint.parse("http://192.168.1.5:9119/hermes", allowPrivateHttp = true)

    private fun cookie(endpoint: HermesEndpoint, vararg headers: String) = HermesAuthParsers.pkceCookie(headers.toList(), endpoint, now)
    private val future = "Max-Age=600"

    @Test fun theCookieNameAndPathFollowTheSchemeAndPrefix() {
        assertEquals("__Host-hermes_session_pkce=abc_-=", cookie(httpsRoot, "__Host-hermes_session_pkce=abc_-=; Path=/; Secure; HttpOnly; SameSite=None; $future"))
        assertEquals("__Secure-hermes_session_pkce=abc", cookie(httpsPrefix, "__Secure-hermes_session_pkce=abc; Path=/hermes; Secure; $future"))
        assertEquals("hermes_session_pkce=abc", cookie(httpRoot, "hermes_session_pkce=abc; Path=/; $future"))
        assertEquals("hermes_session_pkce=abc", cookie(httpPrefix, "hermes_session_pkce=abc; Path=/hermes; HttpOnly; $future"))
        listOf(
            httpsRoot to "hermes_session_pkce=abc; Path=/; Secure; $future",
            httpsRoot to "__Secure-hermes_session_pkce=abc; Path=/; Secure; $future",
            httpsPrefix to "__Host-hermes_session_pkce=abc; Path=/hermes; Secure; $future",
            httpRoot to "__Host-hermes_session_pkce=abc; Path=/; $future",
            httpsRoot to "__Host-hermes_session_pkce=abc; Path=/hermes; Secure; $future",
            httpsPrefix to "__Secure-hermes_session_pkce=abc; Path=/; Secure; $future",
            httpPrefix to "hermes_session_pkce=abc; Path=/; $future",
            httpRoot to "hermes_session_pkce=abc; Path=/hermes; $future",
            httpRoot to "hermes_session_pkce=abc; $future",
            httpRoot to "hermes_session_pkce=abc; Path=/Hermes; $future",
        ).forEach { (endpoint, header) -> assertEquals(header, invalid, kind { cookie(endpoint, header) }) }
    }

    @Test fun theCookieMustBeSecureUnexpiredAndAboutTheEndpointHost() {
        assertEquals(invalid, kind { cookie(httpsRoot, "__Host-hermes_session_pkce=a; Path=/; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Max-Age=0") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Max-Age=-5") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Max-Age=soon") })
        assertEquals("An explicit future Expires counts", "hermes_session_pkce=a",
            cookie(httpRoot, "hermes_session_pkce=a; Path=/; Expires=Wed, 13 Dec 2028 08:00:00 GMT"))
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Expires=not-a-date") })
        assertEquals("Max-Age wins over Expires", invalid,
            kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Max-Age=0; Expires=Wed, 13 Dec 2028 08:00:00 GMT") })

        assertEquals("hermes_session_pkce=a", cookie(httpRoot, "hermes_session_pkce=a; Path=/; Domain=192.168.1.5; $future"))
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Domain=evil.example; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a; Path=/; Domain=.192.168.1.5; $future") })
        val ipv6 = HermesEndpoint.parse("http://[fd00::1]:9119", allowPrivateHttp = true)
        assertEquals("hermes_session_pkce=a", cookie(ipv6, "hermes_session_pkce=a; Path=/; Domain=[FD00::1]; $future"))
    }

    @Test fun theCookieValueIsBoundedAndTheSelectionIsExact() {
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=; Path=/; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a b; Path=/; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=a+b; Path=/; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=\"abc\"; Path=/; $future") })
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=é; Path=/; $future") })
        cookie(httpRoot, "hermes_session_pkce=${"A".repeat(8_192)}; Path=/; $future")
        assertEquals(invalid, kind { cookie(httpRoot, "hermes_session_pkce=${"A".repeat(8_193)}; Path=/; $future") })

        assertEquals("No cookie at all", invalid, kind { cookie(httpRoot) })
        assertEquals("Look-alike names are not accepted", invalid, kind { cookie(httpRoot, "hermes_session_pkce2=a; Path=/; $future", "x_hermes_session_pkce=a; Path=/; $future") })
        assertEquals("Two cookies of the name", invalid, kind {
            cookie(httpRoot, "hermes_session_pkce=a; Path=/; $future", "hermes_session_pkce=b; Path=/; $future")
        })
        assertEquals(
            "Other cookies are ignored, never imported",
            "hermes_session_pkce=a",
            cookie(httpRoot, "other=1; Path=/", "hermes_session_pkce=a; Path=/; $future", "hermes_session_at=secret; Path=/"),
        )
    }

    // Token responses

    private val endpoint = HermesEndpoint.parse("hermes.example/p")
    private fun session(json: String, nowMillis: Long = now * 1_000) = HermesAuthParsers.nativeSession(obj(json), endpoint, nowMillis)
    private fun good(vararg overrides: Pair<String, String>): String {
        val fields = linkedMapOf(
            "token_type" to "\"Bearer\"", "access_token" to "\"access-1\"", "refresh_token" to "\"refresh-1\"",
            "provider" to "\"basic\"", "user_id" to "\"synthetic-user\"", "expires_at" to "${now + 3_600}",
        )
        overrides.forEach { fields[it.first] = it.second }
        return fields.entries.joinToString(prefix = "{", postfix = "}") { "\"${it.key}\":${it.value}" }
    }

    @Test fun aTokenResponseBecomesABearerConnection() {
        val saved = session(good())
        assertEquals(StoredAuth.Bearer("access-1", "refresh-1", now + 3_600), saved.auth)
        assertEquals("basic", saved.provider)
        assertEquals("synthetic-user", saved.userId)
        assertEquals(endpoint, saved.endpoint)
        assertNull("An empty refresh token is no refresh capability", (session(good("refresh_token" to "\"\"")).auth as StoredAuth.Bearer).refreshToken)
        assertNull((session(good("refresh_token" to "null")).auth as StoredAuth.Bearer).refreshToken)
        assertEquals("A fractional expiry keeps its whole second", now + 3_600, (session(good("expires_at" to "${now + 3_600}.75")).auth as StoredAuth.Bearer).expiresAtEpochSeconds)
    }

    @Test fun aTokenResponseThatIsNotExactlyRightIsRefused() {
        listOf(
            good("token_type" to "\"bearer\""), good("token_type" to "\"Basic\""), good("token_type" to "null"),
            good("access_token" to "\"\""), good("access_token" to "\"has space\""), good("access_token" to "12"),
            good("access_token" to "\"${"x".repeat(16_385)}\""), good("refresh_token" to "\"has space\""),
            good("provider" to "\"\""), good("provider" to "null"), good("user_id" to "\"\""), good("user_id" to "5"),
            good("provider" to "\" padded\""), good("user_id" to "\"tab\\t\""), good("provider" to "\"${"p".repeat(129)}\""),
            good("user_id" to "\"${"u".repeat(513)}\""),
            good("expires_at" to "${now}"), good("expires_at" to "${now - 1}"), good("expires_at" to "\"${now + 60}\""), good("expires_at" to "null"),
            "{}",
        ).forEach {
            val failure = assertThrows(it, HermesException::class.java) { session(it) }
            assertEquals(it, invalid, failure.kind)
        }
        session(good("provider" to "\"${"p".repeat(128)}\"", "user_id" to "\"${"u".repeat(512)}\""))
    }

    @Test fun ticketsAreBoundedAndUrlSafe() {
        assertEquals("abc_-DEF123", HermesAuthParsers.ticket(obj("""{"ticket":"abc_-DEF123","ttl_seconds":30}""")))
        assertEquals("a", HermesAuthParsers.ticket(obj("""{"ticket":"a","ttl_seconds":300}""")))
        assertEquals("a", HermesAuthParsers.ticket(obj("""{"ticket":"a","ttl_seconds":0.5}""")))
        listOf(
            """{"ticket":"a"}""", """{"ticket":"","ttl_seconds":30}""", """{"ticket":"a b","ttl_seconds":30}""", """{"ticket":"a.b","ttl_seconds":30}""",
            """{"ticket":"é","ttl_seconds":30}""", """{"ticket":"${"t".repeat(4_097)}","ttl_seconds":30}""", """{"ticket":5,"ttl_seconds":30}""",
            """{"ticket":"a","ttl_seconds":0}""", """{"ticket":"a","ttl_seconds":-1}""", """{"ticket":"a","ttl_seconds":301}""",
            """{"ticket":"a","ttl_seconds":"30"}""", """{"ticket":"a","ttl_seconds":null}""",
        ).forEach { assertEquals(it, invalid, kind { HermesAuthParsers.ticket(obj(it)) }) }
        HermesAuthParsers.ticket(obj("""{"ticket":"${"t".repeat(4_096)}","ttl_seconds":30}"""))
    }
}
