package app.bighelp.hermes

import java.net.URI
import java.net.URISyntaxException

/** Why an address or route was refused. Callers show plain words per reason and never echo the input. */
class HermesEndpointException(val reason: Reason) : IllegalArgumentException(reason.name) {
    enum class Reason { InvalidEndpoint, PlaintextNotAllowed, InvalidRoute }
}

/**
 * A validated Hermes dashboard base address, including an optional deployment prefix. [canonical] is the
 * endpoint's identity: scheme, effective port and prefix are all part of it, so credentials for
 * `/hermes-a` are never credentials for `/hermes-b`. Saved endpoints must go through [parse] again.
 *
 * Plain HTTP needs both the caller's explicit private-network opt-in and a host that is private by its
 * syntax alone. No name is ever resolved, so DNS cannot authorize plaintext.
 */
class HermesEndpoint private constructor(
    val isSecure: Boolean,
    /** Lowercase host without IPv6 brackets. */
    val host: String,
    /** The explicit port, or null when it is the scheme's default. */
    val port: Int?,
    /** Deployment prefix: empty, or `/a/b` with no trailing slash. */
    val prefix: String,
    val allowPrivateHttp: Boolean,
) {
    private val authority: String =
        (if (':' in host) "[$host]" else host) + (port?.let { ":$it" } ?: "")

    val canonical: String = "${if (isSecure) "https" else "http"}://$authority$prefix"

    /** The gateway socket, `wss` for HTTPS and `ws` for HTTP. The prefix is kept. */
    val webSocketUrl: String = "${if (isSecure) "wss" else "ws"}://$authority$prefix/api/ws"

    /**
     * Appends an application-owned [route] to the prefix. Caller-supplied absolute URLs, queries and
     * traversal never pass; add query values separately with a real query encoder.
     */
    fun httpUrl(route: String): URI {
        if (!route.startsWith("/") || "//" in route || route.any { it.code !in 0x21..0x7e || it in "?#%\\" } ||
            route.split('/').any { it == "." || it == ".." }
        ) throw HermesEndpointException(HermesEndpointException.Reason.InvalidRoute)
        return try {
            URI("$canonical$route")
        } catch (_: URISyntaxException) {
            throw HermesEndpointException(HermesEndpointException.Reason.InvalidRoute)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is HermesEndpoint && canonical == other.canonical && allowPrivateHttp == other.allowPrivateHttp

    override fun hashCode(): Int = 31 * canonical.hashCode() + allowPrivateHttp.hashCode()

    override fun toString(): String = canonical

    companion object {
        private const val MAXIMUM_INPUT_BYTES = 2_048
        private const val PREFIX_CHARACTERS =
            "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

        /**
         * @throws HermesEndpointException (an [IllegalArgumentException]) for anything the contract refuses:
         * whitespace, credentials, query, fragment, percent escapes, traversal, numeric host aliases, ports
         * outside 1–65535, an unsupported scheme, or plain HTTP that is not both opted in and private.
         */
        fun parse(input: String, allowPrivateHttp: Boolean = false): HermesEndpoint {
            // The only characters any valid endpoint holds are ASCII, so non-ASCII can never be accepted.
            if (input.isEmpty() || input.length > MAXIMUM_INPUT_BYTES ||
                input.any { it.code !in 0x21..0x7e } || '\\' in input
            ) throw invalidEndpoint()

            val separator = input.indexOf("://")
            val explicitScheme = if (separator >= 0) input.substring(0, separator).lowercase() else null
            val rest = when {
                separator >= 0 -> input.substring(separator + 3)
                // An unbracketed IPv6 literal with no path or port is unambiguous.
                HermesAddress.parseIPv6(input) != null -> "[$input]"
                else -> input
            }
            val secure = when (explicitScheme) {
                null, "https" -> true
                "http" -> false
                else -> throw invalidEndpoint()
            }
            // Credentials, query and fragment never belong in an endpoint, even when empty.
            if (rest.any { it == '@' || it == '?' || it == '#' }) throw invalidEndpoint()

            val slash = rest.indexOf('/')
            val authority = if (slash >= 0) rest.substring(0, slash) else rest
            val path = if (slash >= 0) rest.substring(slash) else ""
            if ('%' in authority) throw invalidEndpoint() // zone IDs and escaped hosts

            val (host, portText) = splitAuthority(authority)
            val port = portText?.let { parsePort(it) }
            if (!validHost(host)) throw invalidEndpoint()

            if (path.any { it !in PREFIX_CHARACTERS } || "//" in path ||
                path.split('/').any { it == "." || it == ".." }
            ) throw invalidEndpoint()

            if (!secure && !(allowPrivateHttp && HermesAddress.isPrivateNetworkHost(host))) {
                throw HermesEndpointException(HermesEndpointException.Reason.PlaintextNotAllowed)
            }
            val defaultPort = if (secure) 443 else 80
            return HermesEndpoint(
                isSecure = secure,
                host = host,
                port = port?.takeIf { it != defaultPort },
                prefix = path.removeSuffix("/"),
                allowPrivateHttp = allowPrivateHttp,
            )
        }

        /** Host (lowercase, no brackets) and the raw port digits, when a port is present. */
        private fun splitAuthority(authority: String): Pair<String, String?> {
            if (authority.startsWith("[")) {
                val close = authority.indexOf(']')
                if (close < 0) throw invalidEndpoint()
                val literal = authority.substring(1, close).lowercase()
                if (HermesAddress.parseIPv6(literal) == null) throw invalidEndpoint()
                val after = authority.substring(close + 1)
                return when {
                    after.isEmpty() -> literal to null
                    after.startsWith(":") -> literal to after.substring(1)
                    else -> throw invalidEndpoint()
                }
            }
            // An unbracketed host never holds ':' except before its port.
            val colon = authority.indexOf(':')
            if (colon < 0) return authority.lowercase() to null
            if (authority.indexOf(':', colon + 1) >= 0) throw invalidEndpoint()
            return authority.substring(0, colon).lowercase() to authority.substring(colon + 1)
        }

        private fun parsePort(text: String): Int {
            // An empty port ("host:") is refused rather than read as the default.
            if (text.isEmpty() || text.length > 5 || !text.all { it in '0'..'9' }) throw invalidEndpoint()
            return text.toInt().also { if (it !in 1..65_535) throw invalidEndpoint() }
        }

        private fun validHost(host: String): Boolean {
            if (host.isEmpty()) return false
            if (':' in host) return HermesAddress.parseIPv6(host) != null // bracketed literal, already checked
            if (HermesAddress.parseIPv4(host) != null) return true
            // Refuse numeric aliases (127.1, integer and hex IPv4) and ambiguous DNS.
            if (host.length > 253 || host.all { it in '0'..'9' || it == '.' } || host.startsWith("0x")) return false
            return host.split('.').all { label ->
                label.length in 1..63 && label.first() != '-' && label.last() != '-' &&
                    label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }
            }
        }

        private fun invalidEndpoint() = HermesEndpointException(HermesEndpointException.Reason.InvalidEndpoint)
    }
}
