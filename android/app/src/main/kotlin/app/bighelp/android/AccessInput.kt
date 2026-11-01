package app.bighelp.android

import app.bighelp.android.live.AccessSetup
import app.bighelp.hermes.AccessCredential
import app.bighelp.hermes.CustomHeader
import app.bighelp.hermes.CustomHeaderException
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException

enum class AccessKind { None, Cloudflare, ProxyLogin }

enum class AccessProblem { Credential, HeaderName, HeaderReserved, HeaderValue, HeaderDuplicate, TooManyHeaders }

/**
 * What the person typed under "Extra access details": the gate in front of their computer's address. It stays
 * plain strings until [build] checks them, so the form can keep half-typed text.
 */
data class AccessInput(
    val kind: AccessKind = AccessKind.None,
    val id: String = "",
    val secret: String = "",
    val headers: List<Pair<String, String>> = emptyList(),
) {
    internal fun build(): AccessBuild = try {
        val credential = when (kind) {
            AccessKind.None -> null
            AccessKind.Cloudflare -> AccessCredential.cloudflareAccess(id, secret)
            AccessKind.ProxyLogin -> AccessCredential.proxyBasic(id, secret)
        }
        AccessBuild.Ok(AccessSetup(credential, CustomHeader.list(headers)))
    } catch (_: HermesException) {
        AccessBuild.Invalid(AccessProblem.Credential)
    } catch (failure: CustomHeaderException) {
        AccessBuild.Invalid(
            when (failure.problem) {
                CustomHeaderException.Problem.InvalidName -> AccessProblem.HeaderName
                CustomHeaderException.Problem.Reserved -> AccessProblem.HeaderReserved
                CustomHeaderException.Problem.InvalidValue -> AccessProblem.HeaderValue
                CustomHeaderException.Problem.Duplicate -> AccessProblem.HeaderDuplicate
                CustomHeaderException.Problem.TooMany -> AccessProblem.TooManyHeaders
            },
        )
    }
}

internal sealed interface AccessBuild {
    data class Ok(val setup: AccessSetup) : AccessBuild
    data class Invalid(val problem: AccessProblem) : AccessBuild
}

internal fun defaultComputerName(endpoint: HermesEndpoint): String = endpoint.host

internal fun describe(problem: AccessProblem): String = when (problem) {
    AccessProblem.Credential -> "Those access details can't be used. Check for spaces or a colon in the username."
    AccessProblem.HeaderName -> "A header name can only use letters, numbers and dashes."
    AccessProblem.HeaderReserved -> "That header name is used by the app itself. Pick another."
    AccessProblem.HeaderValue -> "Every header needs a value."
    AccessProblem.HeaderDuplicate -> "Each header name can be used once."
    AccessProblem.TooManyHeaders -> "You can add up to 16 headers."
}
