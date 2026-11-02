package app.bighelp.hermes

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** How a saved connection signs in. The secrets are redacted from [toString]. */
sealed interface StoredAuth {
    /**
     * A provider-issued access token verified by `/api/auth/me`. [refreshToken] is null when the host
     * gave none (an entered token never acquires one). [expiresAtEpochSeconds] is the access token's expiry
     * in Unix **seconds**, when the host reported one.
     */
    class Bearer(
        val accessToken: String,
        val refreshToken: String?,
        val expiresAtEpochSeconds: Long?,
    ) : StoredAuth {
        override fun equals(other: Any?) = other is Bearer && accessToken == other.accessToken &&
            refreshToken == other.refreshToken && expiresAtEpochSeconds == other.expiresAtEpochSeconds

        override fun hashCode() = (accessToken.hashCode() * 31 + refreshToken.hashCode()) * 31 + expiresAtEpochSeconds.hashCode()
        override fun toString() = "Bearer(refresh=${refreshToken != null}, expiresAt=$expiresAtEpochSeconds)"
    }

    /** The dashboard's own session token on an ungated host; [automatic] tokens are re-read from the dashboard. */
    class DashboardSession(val token: String, val automatic: Boolean) : StoredAuth {
        override fun equals(other: Any?) = other is DashboardSession && token == other.token && automatic == other.automatic
        override fun hashCode() = token.hashCode() * 31 + automatic.hashCode()
        override fun toString() = "DashboardSession(automatic=$automatic)"
    }
}

/**
 * Where a credential lives: the canonical endpoint and the exact principal. Compared byte for byte, so a
 * different prefix, provider or user ID is a different authority and credentials never cross between them.
 */
data class CredentialAuthority(val endpoint: String, val principal: String)

/**
 * One saved sign-in. It holds secrets: persist it only through a protected [CredentialStore], never in
 * preferences, URLs or logs. [provider] and [userId] are the verified identity of a [StoredAuth.Bearer];
 * a dashboard session has neither.
 */
class SavedConnection(
    val endpoint: HermesEndpoint,
    val auth: StoredAuth,
    val provider: String?,
    val userId: String?,
) {
    val schemaVersion: Int get() = SCHEMA_VERSION

    /** Non-secret scope. A dashboard session is scoped to the endpoint alone. */
    val principal: String
        get() = if (auth is StoredAuth.DashboardSession) DASHBOARD_PRINCIPAL else "${provider.orEmpty()}\u001f${userId.orEmpty()}"

    val authority: CredentialAuthority get() = CredentialAuthority(endpoint.canonical, principal)

    /**
     * @throws HermesException [HermesException.Kind.SavedConnectionInvalid] for a dashboard record with an
     * identity or a bearer record without one, [HermesException.Kind.InvalidCredentials] for a bad token.
     */
    fun validate() {
        when (auth) {
            is StoredAuth.DashboardSession -> {
                if (provider != null || userId != null) throw HermesException(HermesException.Kind.SavedConnectionInvalid)
                HermesSecrets.requireToken(auth.token)
            }
            is StoredAuth.Bearer -> {
                HermesSecrets.requireToken(auth.accessToken)
                auth.refreshToken?.let(HermesSecrets::requireToken)
                if (provider == null || userId == null ||
                    !HermesSecrets.isValidIdentity(provider, HermesSecrets.MAXIMUM_PROVIDER_BYTES) ||
                    !HermesSecrets.isValidIdentity(userId, HermesSecrets.MAXIMUM_USER_ID_BYTES)
                ) throw HermesException(HermesException.Kind.SavedConnectionInvalid)
            }
        }
    }

    /** Compact JSON for the app's protected record store. Contains secrets. */
    fun toBytes(): ByteArray {
        val json = buildJsonObject {
            put("schemaVersion", SCHEMA_VERSION)
            put("endpoint", endpoint.canonical)
            put("allowPrivateHttp", endpoint.allowPrivateHttp)
            put("credentialEndpointIdentity", endpoint.canonical)
            put(
                "auth",
                buildJsonObject {
                    when (auth) {
                        is StoredAuth.Bearer -> {
                            put("type", "bearer")
                            put("accessToken", auth.accessToken)
                            put("refreshToken", auth.refreshToken?.let(::JsonPrimitive) ?: JsonNull)
                            put("expiresAt", auth.expiresAtEpochSeconds?.let(::JsonPrimitive) ?: JsonNull)
                        }
                        is StoredAuth.DashboardSession -> {
                            put("type", "dashboardSession")
                            put("token", auth.token)
                            put("automatic", auth.automatic)
                        }
                    }
                },
            )
            provider?.let { put("provider", it) }
            userId?.let { put("userId", it) }
        }
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    override fun equals(other: Any?) = other is SavedConnection && endpoint == other.endpoint && auth == other.auth &&
        provider == other.provider && userId == other.userId

    override fun hashCode() = ((endpoint.hashCode() * 31 + auth.hashCode()) * 31 + provider.hashCode()) * 31 + userId.hashCode()
    override fun toString() = "SavedConnection(${endpoint.canonical}, $auth)"

    companion object {
        const val SCHEMA_VERSION = 1
        const val MAXIMUM_RECORD_BYTES = 65_536
        const val DASHBOARD_PRINCIPAL = "dashboard-session"

        /**
         * Reads and validates a record written by [toBytes]. Unknown fields are ignored. The endpoint is
         * parsed again, so a record can never smuggle in an address the endpoint rules refuse.
         * @throws HermesException [HermesException.Kind.SavedConnectionInvalid] for anything else.
         */
        fun fromBytes(bytes: ByteArray): SavedConnection {
            fun invalid(): Nothing = throw HermesException(HermesException.Kind.SavedConnectionInvalid)
            if (bytes.size > MAXIMUM_RECORD_BYTES) invalid()
            val root = try {
                StrictJson.parse(String(bytes, Charsets.UTF_8)) as? JsonObject ?: invalid()
            } catch (_: StrictJson.Malformed) {
                invalid()
            }
            fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun JsonObject.longOrNull(key: String) = (this[key] as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toLongOrNull()
            if (root.longOrNull("schemaVersion") != SCHEMA_VERSION.toLong()) invalid()
            val allowPrivate = (root["allowPrivateHttp"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: invalid()
            val endpointText = root.text("endpoint") ?: invalid()
            val endpoint = try {
                HermesEndpoint.parse(endpointText, allowPrivate)
            } catch (_: HermesEndpointException) {
                invalid()
            }
            if (root.text("credentialEndpointIdentity") != endpoint.canonical || endpoint.canonical != endpointText) invalid()
            val authObject = root["auth"] as? JsonObject ?: invalid()
            val auth = when (authObject.text("type")) {
                "bearer" -> StoredAuth.Bearer(
                    authObject.text("accessToken") ?: invalid(),
                    authObject.text("refreshToken").also { if (it == null && authObject["refreshToken"] !is JsonNull?) invalid() },
                    authObject.longOrNull("expiresAt").also { if (it == null && authObject["expiresAt"] !is JsonNull?) invalid() },
                )
                "dashboardSession" -> StoredAuth.DashboardSession(
                    authObject.text("token") ?: invalid(),
                    (authObject["automatic"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: invalid(),
                )
                else -> invalid()
            }
            return SavedConnection(endpoint, auth, root.text("provider"), root.text("userId")).also { it.validate() }
        }
    }
}

/** The stored record changed since the caller read it. Nothing was written. */
class StaleCredentialException : Exception("Stale credential")

/**
 * Durable, protected credential storage with atomic compare-and-replace. Authority is the canonical
 * endpoint plus the exact principal. Implementations are Keystore-backed on Android and must make the
 * compare and the write one atomic step (also across processes that share the file).
 */
interface CredentialStore {
    suspend fun load(authority: CredentialAuthority): SavedConnection?

    /**
     * Writes [next] only if the stored record for `next.authority` equals [expected] exactly (or, for a
     * null [expected], only if none exists). The write is durable when this returns.
     * @throws StaleCredentialException when it does not match; nothing is written.
     * @throws IllegalArgumentException if [expected] belongs to another authority than [next].
     */
    suspend fun replace(expected: SavedConnection?, next: SavedConnection)

    /** Local sign-out: removes the record only if it still equals [expected]. There is no server-side revoke. */
    suspend fun delete(expected: SavedConnection)
}

/** Volatile store for tests and demos. Not durable, not protected. */
class InMemoryCredentialStore : CredentialStore {
    private val lock = Mutex()
    private val records = HashMap<CredentialAuthority, SavedConnection>()

    override suspend fun load(authority: CredentialAuthority): SavedConnection? = lock.withLock { records[authority] }

    override suspend fun replace(expected: SavedConnection?, next: SavedConnection) {
        require(expected == null || expected.authority == next.authority) { "A replacement keeps its authority" }
        lock.withLock {
            if (records[next.authority] != expected) throw StaleCredentialException()
            records[next.authority] = next
        }
    }

    override suspend fun delete(expected: SavedConnection) {
        lock.withLock {
            if (records[expected.authority] != expected) throw StaleCredentialException()
            records.remove(expected.authority)
        }
    }
}
