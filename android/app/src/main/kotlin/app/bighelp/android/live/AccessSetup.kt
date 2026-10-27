package app.bighelp.android.live

import app.bighelp.android.storage.AndroidCredentialKey
import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.android.storage.AndroidChatStore
import app.bighelp.hermes.AccessCredential
import app.bighelp.hermes.AccessHeaders
import app.bighelp.hermes.CustomHeader
import app.bighelp.hermes.HermesEndpoint
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * What guards a computer's address before Hermes does: a Cloudflare Access token, a proxy login and/or custom
 * proxy headers. It belongs to the computer, not to a sign-in, and travels only to that computer's address.
 * Its secrets never appear in [toString].
 */
internal class AccessSetup(val credential: AccessCredential?, val custom: List<CustomHeader>) {
    val isEmpty: Boolean get() = credential == null && custom.isEmpty()

    /** @throws app.bighelp.hermes.HermesException when the credential cannot be sent to [endpoint] (Cloudflare needs HTTPS). */
    fun headers(endpoint: HermesEndpoint): AccessHeaders = AccessHeaders.of(endpoint, credential, custom)

    override fun equals(other: Any?) = other is AccessSetup && credential == other.credential && custom == other.custom
    override fun hashCode() = credential.hashCode() * 31 + custom.hashCode()
    override fun toString() = "AccessSetup(credential=${credential?.kind}, headers=${custom.size})"

    companion object {
        val None = AccessSetup(null, emptyList())
    }
}

/** Everything the phone keeps for one computer besides its sign-in and its row: gate details and chat records. */
internal interface ComputerLocalData {
    suspend fun loadAccess(id: UUID): AccessSetup
    suspend fun saveAccess(id: UUID, access: AccessSetup)

    /** Removing a computer removes this too. Safe to run again. */
    suspend fun forget(id: UUID)

    object None : ComputerLocalData {
        override suspend fun loadAccess(id: UUID) = AccessSetup.None
        override suspend fun saveAccess(id: UUID, access: AccessSetup) = Unit
        override suspend fun forget(id: UUID) = Unit
    }
}

internal fun accessRecordKey(id: UUID): String = buildJsonArray {
    add(JsonPrimitive("bighelp.access.v1"))
    add(JsonPrimitive(id.toString()))
}.toString()

/** Gate details sealed with the same device key as sign-ins, one record per computer, backup-excluded. */
internal class AndroidAccessSetupStore(
    private val records: ProtectedRecordStore,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun loadAccess(id: UUID): AccessSetup = withContext(dispatcher) {
        val raw = records.read(accessRecordKey(id)) ?: return@withContext AccessSetup.None
        try { decode(raw) } finally { raw.fill(0) }
    }

    suspend fun saveAccess(id: UUID, access: AccessSetup) = withContext(dispatcher) {
        val key = accessRecordKey(id)
        val current = records.read(key)
        try {
            val next = if (access.isEmpty) null else encode(access)
            try {
                if (!records.compareAndSet(key, current, next)) throw RecordStorageException(StorageProblem.DiskUnavailable)
            } finally { next?.fill(0) }
        } finally { current?.fill(0) }
    }

    suspend fun deleteAccess(id: UUID) = saveAccess(id, AccessSetup.None)

    private fun encode(access: AccessSetup): ByteArray = buildJsonObject {
        put("schemaVersion", 1)
        access.credential?.let { credential ->
            put("credential", buildJsonObject {
                put("kind", credential.kind.name)
                put("clientId", credential.clientId)
                put("clientSecret", credential.clientSecret)
            })
        }
        put("custom", buildJsonArray {
            for (header in access.custom) add(buildJsonObject { put("name", header.name); put("value", header.value) })
        })
    }.toString().toByteArray(Charsets.UTF_8)

    private fun decode(bytes: ByteArray): AccessSetup {
        try {
            val root = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) as? JsonObject ?: throw unreadable()
            val version = root["schemaVersion"] as? JsonPrimitive
            if (version == null || version.isString || version.intOrNull != 1) throw unreadable()
            val credential = (root["credential"] as? JsonObject)?.let { value ->
                val id = text(value, "clientId")
                val secret = text(value, "clientSecret")
                when (text(value, "kind")) {
                    AccessCredential.Kind.CloudflareAccess.name -> AccessCredential.cloudflareAccess(id, secret)
                    AccessCredential.Kind.ProxyBasic.name -> AccessCredential.proxyBasic(id, secret)
                    else -> throw unreadable()
                }
            }
            val custom = (root["custom"] as? JsonArray ?: throw unreadable()).map { row ->
                val value = row as? JsonObject ?: throw unreadable()
                CustomHeader.of(text(value, "name"), text(value, "value"))
            }
            return AccessSetup(credential, custom)
        } catch (failure: RecordStorageException) {
            throw failure
        } catch (_: Exception) {
            throw unreadable()
        }
    }

    private fun text(value: JsonObject, key: String): String =
        (value[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull ?: throw unreadable()

    private fun unreadable() = RecordStorageException(StorageProblem.CorruptRecord)

    companion object {
        fun create(context: android.content.Context) = AndroidAccessSetupStore(
            ProtectedRecordStore(File(context.noBackupFilesDir, "access-headers"), RecordCipher(AndroidCredentialKey)),
        )
    }
}

internal class AndroidComputerLocalData(
    private val access: AndroidAccessSetupStore,
    private val chat: AndroidChatStore,
) : ComputerLocalData {
    override suspend fun loadAccess(id: UUID) = access.loadAccess(id)
    override suspend fun saveAccess(id: UUID, access: AccessSetup) = this.access.saveAccess(id, access)
    override suspend fun forget(id: UUID) {
        access.deleteAccess(id)
        chat.purge(id.toString())
    }
}
