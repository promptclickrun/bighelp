package app.bighelp.hermes

/**
 * Every failure of sign-in, HTTP and the gateway. [message] is always the fixed [Kind] name: never a URL,
 * token, cookie, body or host text. Cancellation of the caller's coroutine is a `CancellationException`,
 * not a [HermesException]; [Kind.Cancelled] means a client object was closed under a waiting request.
 *
 * [outcomeUnknown] is the typed "may have been accepted" flag: set only when a mutation may have left the
 * device and no answer came back. Nothing in this module retries such a request.
 */
class HermesException(
    val kind: Kind,
    val outcomeUnknown: Boolean = false,
    /** Hermes' numeric JSON-RPC code or the HTTP status of a retained route refusal. */
    val code: Long? = null,
    /** `error.data.reason`, a machine reason such as `MAX_CONCURRENT_SESSIONS`. */
    val reason: String? = null,
    /** Hermes' own refusal words flattened to one line ([HermesWire.MAXIMUM_REFUSAL_CHARACTERS]); display only. */
    val refusal: String? = null,
    /** For [Kind.WebPageInsteadOfHermes]: the page came through Cloudflare. */
    val throughCloudflare: Boolean = false,
) : Exception(kind.name) {
    enum class Kind {
        InvalidEndpoint, PlaintextNotAllowed, InvalidCredentials, AuthenticationRequired,
        UnsupportedAuthentication, AmbiguousPasswordProvider, AuthModeChanged, IdentityChanged,
        SavedConnectionInvalid, SecureStorageUnavailable, SecureStorageChanged,
        RedirectRefused, InvalidResponse, MessageTooLarge, TooManyRequests, NotConnected,
        ConnectionFailed, TlsRequired, RateLimited, ServerUnavailable,
        BrowserAuthenticationUnavailable, NativeTokenExchangeUncertain,
        InvalidAccessCredentials, CloudflareAccessDenied, HostNameRefused, WebPageInsteadOfHermes,
        Disconnected, TimedOut, Cancelled,

        /** Hermes answered an RPC or a route with a refusal; see [code], [reason] and [refusal]. */
        RpcRejected,

        /** Hermes' cap on open chats: code 4090 with reason `MAX_CONCURRENT_SESSIONS`. */
        ActiveSessionLimit,

        /** `per_session_exclusive_submit` is false, so starting a turn stays off. */
        ExclusiveSubmitUnavailable,

        /** A non-GET request may have been applied; reconcile host state before doing anything else. */
        OutcomeUnknown,
    }

    override fun toString(): String = "HermesException($kind${if (outcomeUnknown) ", outcomeUnknown" else ""})"
}

internal fun HermesException.asOutcomeUnknown() =
    HermesException(kind, outcomeUnknown = true, code = code, reason = reason, refusal = refusal, throughCloudflare = throughCloudflare)
