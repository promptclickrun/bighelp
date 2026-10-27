package app.bighelp.hermes

import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Pure, bounded readers of what the host sends during sign-in. Nothing here does I/O. */
internal object HermesAuthParsers {
    private const val MAXIMUM_BOOTSTRAP_BYTES = 1_048_576
    private val SCRIPT = Regex("""<script\b[^>]*>([\s\S]*?)</script\s*>""", RegexOption.IGNORE_CASE)
    // A lookbehind, not a consumed `;`: two assignments in a row must both be seen.
    private val MODE_ASSIGNMENT = Regex("""(?<=^|;)\s*window\.__HERMES_AUTH_REQUIRED__\s*=\s*(true|false)\s*;""")
    private const val TOKEN_NAME = "window.__HERMES_SESSION_TOKEN__"
    private const val MAXIMUM_TOKEN_LITERAL = 65_536

    private fun invalid() = HermesException(HermesException.Kind.InvalidResponse)

    /**
     * Inert `window.__HERMES_SESSION_TOKEN__` assignment of an ungated dashboard page. Only `<script>`
     * contents count, exactly one token and exactly one `false` auth marker; the page is never executed.
     */
    fun dashboardToken(bytes: ByteArray): String {
        if (bytes.size > MAXIMUM_BOOTSTRAP_BYTES) throw invalid()
        val html = HermesHttpDecoding.utf8(bytes)
        val tokens = ArrayList<String>()
        val modes = ArrayList<String>()
        for (script in SCRIPT.findAll(html)) {
            val code = script.groupValues[1]
            for (literal in tokenLiterals(code)) {
                val value = try {
                    StrictJson.parse(literal)
                } catch (_: StrictJson.Malformed) {
                    throw invalid()
                }
                tokens += (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw invalid()
            }
            for (match in MODE_ASSIGNMENT.findAll(code)) modes += match.groupValues[1]
        }
        if (tokens.size != 1 || modes != listOf("false")) {
            throw HermesException(HermesException.Kind.UnsupportedAuthentication)
        }
        HermesSecrets.requireToken(tokens.single())
        return tokens.single()
    }

    /**
     * The double-quoted literals of statement-level `window.__HERMES_SESSION_TOKEN__ = "…";` assignments.
     * Scanned by hand: a regex over an arbitrarily long string literal recurses once per character and a
     * hostile page could overflow the stack. Anything that is not exactly that statement is ignored.
     */
    private fun tokenLiterals(code: String): List<String> {
        val found = ArrayList<String>()
        var from = 0
        while (true) {
            val at = code.indexOf(TOKEN_NAME, from)
            if (at < 0) return found
            from = at + TOKEN_NAME.length
            var back = at - 1
            while (back >= 0 && code[back] in " \t\r\n") back--
            if (back >= 0 && code[back] != ';') continue
            var i = skipSpace(code, from)
            if (i >= code.length || code[i] != '=') continue
            i = skipSpace(code, i + 1)
            if (i >= code.length || code[i] != '"') continue
            val start = i
            i++
            while (i < code.length && code[i] != '"') {
                if (i - start > MAXIMUM_TOKEN_LITERAL) throw invalid()
                i += if (code[i] == '\\') 2 else 1
            }
            if (i >= code.length) continue
            val literal = code.substring(start, i + 1)
            val end = skipSpace(code, i + 1)
            if (end >= code.length || code[end] != ';') continue
            found += literal
            from = end + 1
        }
    }

    private fun skipSpace(code: String, from: Int): Int {
        var i = from
        while (i < code.length && code[i].isWhitespace()) i++
        return i
    }

    /** `GET /api/status` body to [AuthStatus] without providers. */
    fun status(body: JsonObject): AuthStatus {
        val authRequired = body["auth_required"].boolean ?: throw invalid()
        val advertised = body["auth_flows"]
        val flows = if (advertised == null || advertised is JsonNull) {
            emptyList()
        } else {
            val array = advertised as? JsonArray ?: throw invalid()
            if (array.size > 32) throw invalid()
            array.map { element ->
                element.string?.takeIf { it.isNotEmpty() && utf8Length(it) <= 128 } ?: throw invalid()
            }
        }
        if (flows.toSet().size != flows.size) throw invalid()
        return AuthStatus(authRequired, flows, emptyList())
    }

    /** `GET /api/auth/providers` body: at most 64 unique printable-ASCII names. */
    fun providers(body: JsonObject): List<AuthProvider> {
        val rows = body["providers"] as? JsonArray ?: throw invalid()
        if (rows.size > 64) throw invalid()
        val names = HashSet<String>()
        return rows.map { row ->
            val entry = row as? JsonObject ?: throw invalid()
            val name = entry["name"].string
            if (name == null || name.isEmpty() || utf8Length(name) > 256 || name.any { it.code !in 0x21..0x7e } || !names.add(name)) {
                throw invalid()
            }
            val supportsPassword = entry["supports_password"].boolean ?: throw invalid()
            val displayName = entry["display_name"].string ?: name
            if (displayName.isEmpty() || utf8Length(displayName) > 512 || displayName.any { Character.isISOControl(it) }) {
                throw invalid()
            }
            AuthProvider(name, displayName, supportsPassword)
        }
    }

    /**
     * The one short-lived `NAME=VALUE` PKCE cookie from the authorize 302, read from `Set-Cookie` by hand.
     * The name follows scheme and prefix; there must be exactly one of it; its domain is the endpoint's
     * host, its path the prefix (or `/`), it is `Secure` over HTTPS and has an explicit future expiry.
     * Every other cookie is ignored and nothing is kept.
     */
    fun pkceCookie(setCookieHeaders: List<String>, endpoint: HermesEndpoint, nowEpochSeconds: Long): String {
        val expectedPath = endpoint.prefix.ifEmpty { "/" }
        val name = (if (endpoint.isSecure) (if (expectedPath == "/") "__Host-" else "__Secure-") else "") + "hermes_session_pkce"
        val matches = setCookieHeaders.mapNotNull { header ->
            val parts = header.split(';')
            val pair = parts.first().trim()
            val equals = pair.indexOf('=')
            if (equals <= 0 || pair.substring(0, equals) != name) null else parts to pair.substring(equals + 1)
        }
        val (parts, value) = matches.singleOrNull() ?: throw invalid()
        val attributes = HashMap<String, String>()
        for (attribute in parts.drop(1)) {
            val trimmed = attribute.trim()
            val equals = trimmed.indexOf('=')
            val key = (if (equals < 0) trimmed else trimmed.substring(0, equals)).trim().lowercase()
            attributes.putIfAbsent(key, if (equals < 0) "" else trimmed.substring(equals + 1).trim())
        }
        val domain = attributes["domain"]
        if (domain != null && domain.lowercase().trim('[', ']') != endpoint.host) throw invalid()
        if (attributes["path"] != expectedPath) throw invalid()
        if (endpoint.isSecure && "secure" !in attributes) throw invalid()
        val expiresAt = cookieExpiry(attributes, nowEpochSeconds) ?: throw invalid()
        if (expiresAt <= nowEpochSeconds) throw invalid()
        if (value.isEmpty() || value.length > 8_192 ||
            !value.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' || it == '=' }
        ) throw invalid()
        return "$name=$value"
    }

    /** Max-Age wins over Expires (RFC 6265). Null when neither is present and valid. */
    private fun cookieExpiry(attributes: Map<String, String>, now: Long): Long? {
        attributes["max-age"]?.let { text ->
            val seconds = text.toLongOrNull() ?: return null
            return if (seconds <= 0) Long.MIN_VALUE else now + seconds
        }
        val expires = attributes["expires"] ?: return null
        for (format in EXPIRES_FORMATS) {
            try {
                return ZonedDateTime.parse(expires, format).toEpochSecond()
            } catch (_: Exception) {
                // try the next shape
            }
        }
        return null
    }

    private val EXPIRES_FORMATS = listOf(
        DateTimeFormatter.ofPattern("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.ENGLISH).withZone(ZoneOffset.UTC),
        DateTimeFormatter.ofPattern("EEE, dd-MMM-yyyy HH:mm:ss zzz", Locale.ENGLISH).withZone(ZoneOffset.UTC),
    )

    /**
     * A token response (`/auth/native/token`, `/auth/native/refresh`) as a bearer connection. The type
     * must be exactly `Bearer`, tokens printable ASCII, the identity valid, and the expiry in the future
     * (Unix seconds). An empty or absent refresh token means the session cannot be renewed.
     */
    fun nativeSession(body: JsonObject, endpoint: HermesEndpoint, nowEpochMillis: Long): SavedConnection {
        if (body["token_type"].string != "Bearer") throw invalid()
        val access = body["access_token"].string ?: throw invalid()
        val provider = body["provider"].string ?: throw invalid()
        val user = body["user_id"].string ?: throw invalid()
        val expiry = body["expires_at"].number ?: throw invalid()
        if (!(expiry > nowEpochMillis / 1_000.0)) throw invalid()
        val refresh = body["refresh_token"].string?.takeIf { it.isNotEmpty() }
        val saved = SavedConnection(
            endpoint, StoredAuth.Bearer(access, refresh, expiry.toLong()), provider, user,
        )
        try {
            saved.validate()
        } catch (_: HermesException) {
            throw invalid()
        }
        return saved
    }

    /** Ticket reply of `POST /api/auth/ws-ticket`: 1–4,096 URL-safe characters and a TTL of at most 300 s. */
    fun ticket(body: JsonObject): String {
        val ticket = body["ticket"].string
        val ttl = body["ttl_seconds"].number
        if (ticket == null || ticket.isEmpty() || ticket.length > 4_096 ||
            !ticket.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' } ||
            ttl == null || !(ttl > 0.0) || ttl > 300.0
        ) throw invalid()
        return ticket
    }

    internal val JsonElement?.string: String?
        get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    internal val JsonElement?.boolean: Boolean?
        get() = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.let {
            when (it) { "true" -> true; "false" -> false; else -> null }
        }

    internal val JsonElement?.number: Double?
        get() = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toDoubleOrNull()?.takeIf { it.isFinite() }
}
