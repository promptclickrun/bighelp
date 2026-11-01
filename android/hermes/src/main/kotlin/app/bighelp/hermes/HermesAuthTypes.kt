package app.bighelp.hermes

/** One entry of `GET /api/auth/providers`. */
class AuthProvider(val name: String, val displayName: String, val supportsPassword: Boolean) {
    override fun equals(other: Any?) = other is AuthProvider && name == other.name &&
        displayName == other.displayName && supportsPassword == other.supportsPassword

    override fun hashCode() = (name.hashCode() * 31 + displayName.hashCode()) * 31 + supportsPassword.hashCode()
    override fun toString() = "AuthProvider($name)"
}

/**
 * What a host's public `GET /api/status` (and, for native PKCE, `/api/auth/providers`) says about signing
 * in. Unknown [flows] are kept. Neither a version nor a build string is ever consulted.
 */
class AuthStatus(val authRequired: Boolean, val flows: List<String>, val providers: List<AuthProvider>) {
    /** Native PKCE is offered only on a gated host that lists exactly `native_pkce`. */
    val supportsNativePkce: Boolean get() = authRequired && NATIVE_PKCE in flows
    val passwordProviders: List<AuthProvider> get() = if (supportsNativePkce) providers.filter { it.supportsPassword } else emptyList()
    val browserProviders: List<AuthProvider> get() = if (supportsNativePkce) providers else emptyList()

    override fun toString() = "AuthStatus(authRequired=$authRequired, flows=$flows, providers=${providers.size})"

    companion object {
        const val NATIVE_PKCE = "native_pkce"
    }
}

/** What the person chose to sign in with. Secrets are redacted from [toString]. */
sealed interface SignInInput {
    /** Ungated host: read the dashboard's own session token. */
    data object Dashboard : SignInInput

    /** An entered session token (ungated) or provider-issued access token (gated). */
    class Token(val token: String) : SignInInput {
        override fun toString() = "Token"
    }

    /** Native PKCE with a password-capable provider; [provider] null means "the only one". */
    class Password(val provider: String?, val username: String, val password: String) : SignInInput {
        override fun toString() = "Password(provider=$provider)"
    }

    /** Native PKCE in the person's browser; a null [provider] lets the host show its chooser. */
    class Browser(val provider: String?) : SignInInput
}

/**
 * Opens the host's authorize page in the person's own browser (a Custom Tab on Android). The app supplies
 * this; Hermes' sign-in page runs there, so this module never sees browser cookies. The result of the
 * sign-in does not come back through the browser: only the device-local loopback listener supplies the code.
 * [open] should return once the page has been handed to the browser; an exception means it could not.
 */
fun interface BrowserLauncher {
    suspend fun open(authorizeUrl: String)
}

/**
 * Where and how to open the gateway socket. [url] carries the dashboard token in its query, so never log
 * it; [toString] shows neither the URL nor the headers.
 */
class SocketRequest(
    val url: String,
    /** Gate headers, the dashboard token header, or `Sec-WebSocket-Protocol` carrying a fresh ticket. */
    val headers: Map<String, String>,
    /** The subprotocol a ticketed upgrade must negotiate, or null for a dashboard session. */
    val requiredSubprotocol: String?,
) {
    override fun toString() = "SocketRequest(ticketed=${requiredSubprotocol != null})"

    companion object {
        const val GATEWAY_SUBPROTOCOL = "hermes-gateway-v1"
        const val TICKET_SUBPROTOCOL_PREFIX = "hermes-gateway-ticket."
    }
}

/** Deadlines of the authenticator, injectable so tests need not wait. Defaults are the contract's. */
class AuthTimings(
    val refusedRenewalPauseMillis: Long = 15_000,
    val browserSignInMillis: Long = 600_000,
    val callbackRequestMillis: Long = 5_000,
    val callbackResponseFlushMillis: Long = 2_000,
    val renewalSettleMillis: Long = 8_000,
)
