package app.bighelp.hermes

import java.util.Base64

// What guards a Hermes address before Hermes itself: a Cloudflare Access service token, a reverse proxy's
// Basic login, or custom proxy headers. These are independent of the Hermes sign-in, are stored separately
// by the app, and travel on every HTTP request and WebSocket upgrade to that one endpoint, never elsewhere.

/** A proxy gate credential. Secrets never appear in [toString]. */
class AccessCredential private constructor(
    val kind: Kind,
    /** The Cloudflare client ID, or the proxy username. */
    val clientId: String,
    /** The Cloudflare client secret, or the proxy password. */
    val clientSecret: String,
) {
    enum class Kind { CloudflareAccess, ProxyBasic }

    fun headers(): Map<String, String> = when (kind) {
        Kind.CloudflareAccess -> linkedMapOf("CF-Access-Client-Id" to clientId, "CF-Access-Client-Secret" to clientSecret)
        Kind.ProxyBasic -> mapOf(
            "Authorization" to "Basic " +
                Base64.getEncoder().encodeToString("$clientId:$clientSecret".toByteArray(Charsets.UTF_8)),
        )
    }

    /** Cloudflare Access is HTTPS only; Basic may also go to an approved private HTTP address. */
    fun canSend(endpoint: HermesEndpoint): Boolean = endpoint.isSecure || kind == Kind.ProxyBasic

    override fun equals(other: Any?) =
        other is AccessCredential && kind == other.kind && clientId == other.clientId && clientSecret == other.clientSecret

    override fun hashCode() = (kind.hashCode() * 31 + clientId.hashCode()) * 31 + clientSecret.hashCode()
    override fun toString() = "AccessCredential($kind)"

    companion object {
        /** Both values trimmed, 1–512 bytes of printable ASCII with no spaces. */
        fun cloudflareAccess(clientId: String, clientSecret: String): AccessCredential {
            val id = clientId.trim()
            val secret = clientSecret.trim()
            if (!headerSafe(id) || !headerSafe(secret)) throw invalid()
            return AccessCredential(Kind.CloudflareAccess, id, secret)
        }

        /** Username trimmed, 1–256 bytes, no colon or control; the password keeps its spaces, 1–512 bytes. */
        fun proxyBasic(username: String, password: String): AccessCredential {
            val user = username.trim()
            if (user.isEmpty() || utf8Length(user) > 256 || ':' in user || user.any(::isControl) ||
                password.isEmpty() || utf8Length(password) > 512 || password.any(::isControl)
            ) throw invalid()
            return AccessCredential(Kind.ProxyBasic, user, password)
        }

        private fun headerSafe(value: String) = value.isNotEmpty() && value.length <= 512 && value.all { it.code in 0x21..0x7e }
        private fun isControl(c: Char) = c.code < 0x20 || c.code == 0x7f || c.code in 0x80..0x9f
        private fun invalid() = HermesException(HermesException.Kind.InvalidAccessCredentials)
    }
}

class CustomHeaderException(val problem: Problem) : IllegalArgumentException(problem.name) {
    enum class Problem { InvalidName, Reserved, InvalidValue, Duplicate, TooMany }
}

/** A header a proxy in front of Hermes wants, such as `X-Access-Id`. Reserved names are the app's or HTTP's own. */
class CustomHeader private constructor(val name: String, val value: String) {
    override fun equals(other: Any?) = other is CustomHeader && name == other.name && value == other.value
    override fun hashCode() = name.hashCode() * 31 + value.hashCode()
    override fun toString() = "CustomHeader($name)"

    companion object {
        const val MAXIMUM_COUNT = 16

        fun of(name: String, value: String): CustomHeader {
            val trimmedName = name.trim()
            val trimmedValue = value.trim()
            if (!isToken(trimmedName) || utf8Length(trimmedName) > 128) invalid(CustomHeaderException.Problem.InvalidName)
            if (isReserved(trimmedName)) invalid(CustomHeaderException.Problem.Reserved)
            if (trimmedValue.isEmpty() || utf8Length(trimmedValue) > 4_096 ||
                trimmedValue.any { !(it == '\t' || it.code in 0x20..0x7e || it.code >= 0x80) }
            ) invalid(CustomHeaderException.Problem.InvalidValue)
            return CustomHeader(trimmedName, trimmedValue)
        }

        /** Blank rows are skipped; at most 16; names unique ignoring case. */
        fun list(pairs: List<Pair<String, String>>): List<CustomHeader> {
            val filled = pairs.filter { it.first.isNotBlank() || it.second.isNotBlank() }
            if (filled.size > MAXIMUM_COUNT) invalid(CustomHeaderException.Problem.TooMany)
            val seen = HashSet<String>()
            return filled.map { (name, value) ->
                of(name, value).also { if (!seen.add(it.name.lowercase())) invalid(CustomHeaderException.Problem.Duplicate) }
            }
        }

        fun isReserved(name: String): Boolean {
            val lower = name.lowercase()
            return lower in RESERVED || lower.startsWith("sec-") || lower.startsWith("x-loopdy-") ||
                lower.startsWith("x-hermes-") || lower.startsWith("cf-access-")
        }

        private val RESERVED = setOf(
            "host", "authorization", "proxy-authorization", "cookie", "content-type", "content-length",
            "content-encoding", "transfer-encoding", "connection", "upgrade", "keep-alive", "te", "expect",
            "accept", "accept-encoding", "cache-control", "range", "if-match", "if-none-match", "origin",
        )

        private fun isToken(name: String) = name.isNotEmpty() &&
            name.all { (it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9') || it in "!#$%&'*+-.^_`|~" }

        private fun invalid(problem: CustomHeaderException.Problem): Nothing = throw CustomHeaderException(problem)
    }
}

/**
 * The complete header set for one endpoint's gate. The values hold secrets; [toString] names none of them.
 * Applied to every HTTP request and to the WebSocket upgrade explicitly.
 */
class AccessHeaders private constructor(val values: Map<String, String>) {
    override fun toString() = "AccessHeaders(${values.size} headers)"

    companion object {
        val none = AccessHeaders(emptyMap())

        /** @throws HermesException [HermesException.Kind.InvalidAccessCredentials] if [credential] cannot go to [endpoint]. */
        fun of(endpoint: HermesEndpoint, credential: AccessCredential?, custom: List<CustomHeader>): AccessHeaders {
            if (credential != null && !credential.canSend(endpoint)) {
                throw HermesException(HermesException.Kind.InvalidAccessCredentials)
            }
            val values = LinkedHashMap<String, String>()
            credential?.let { values.putAll(it.headers()) }
            custom.forEach { values[it.name] = it.value }
            return AccessHeaders(values)
        }
    }
}
