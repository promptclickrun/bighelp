package app.bighelp.android.live

import android.content.Context
import app.bighelp.android.storage.AndroidCredentialKey
import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.recordBindingBytes
import app.bighelp.hermes.CredentialAuthority
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.StaleCredentialException
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray

/**
 * Protected persistence only; the connection owner decides when a ready sign-in may be committed.
 * Cancellation can arrive after a write commits. Retire and join owners before cleanup, and read back
 * an uncertain result. Do not wrap these calls in runInterruptible or Future.cancel(true).
 */
internal class AndroidCredentialStore(
    private val records: ProtectedRecordStore,
    private val computerScope: String = "independent",
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : CredentialStore {
    override suspend fun load(authority: CredentialAuthority): SavedConnection? = withContext(dispatcher) {
        val raw = records.read(credentialRecordKey(authority, computerScope)) ?: return@withContext null
        try {
            decode(authority, raw)
        } finally {
            raw.fill(0)
        }
    }

    override suspend fun replace(expected: SavedConnection?, next: SavedConnection) = withContext(dispatcher) {
        next.validate()
        require(expected == null || expected.authority == next.authority) { "A replacement keeps its authority" }
        val key = credentialRecordKey(next.authority, computerScope)
        val raw = records.read(key)
        try {
            val stored = raw?.let { decode(next.authority, it) }
            if (stored != expected) throw StaleCredentialException()
            val replacement = next.toBytes()
            try {
                currentCoroutineContext().ensureActive()
                // Compare the actual encoded snapshot, allowing harmless JSON ordering and future optional fields.
                if (!records.compareAndSet(key, raw, replacement)) throw StaleCredentialException()
            } finally {
                replacement.fill(0)
            }
        } finally {
            raw?.fill(0)
        }
    }

    override suspend fun delete(expected: SavedConnection) = withContext(dispatcher) {
        val key = credentialRecordKey(expected.authority, computerScope)
        val raw = records.read(key)
        try {
            if (raw == null || decode(expected.authority, raw) != expected) throw StaleCredentialException()
            currentCoroutineContext().ensureActive()
            if (!records.compareAndSet(key, raw, null)) throw StaleCredentialException()
        } finally {
            raw?.fill(0)
        }
    }

    /** Only an explicit local recovery action may discard a sign-in the app cannot read. */
    suspend fun discardUnreadable(authority: CredentialAuthority): Boolean = withContext(dispatcher) {
        val key = credentialRecordKey(authority, computerScope)
        currentCoroutineContext().ensureActive()
        if (records.discardUnreadable(key)) return@withContext true
        val raw = records.read(key) ?: return@withContext false
        try {
            try {
                decode(authority, raw)
                false
            } catch (failure: HermesException) {
                if (failure.kind !in setOf(HermesException.Kind.SavedConnectionInvalid, HermesException.Kind.InvalidCredentials)) {
                    throw failure
                }
                currentCoroutineContext().ensureActive()
                records.compareAndSet(key, raw, null)
            }
        } finally {
            raw.fill(0)
        }
    }

    private fun decode(authority: CredentialAuthority, raw: ByteArray): SavedConnection =
        SavedConnection.fromBytes(raw).also {
            if (it.authority != authority) throw HermesException(HermesException.Kind.SavedConnectionInvalid)
        }

    companion object {
        fun create(context: Context, computerID: UUID) = AndroidCredentialStore(
            ProtectedRecordStore(File(context.noBackupFilesDir, "hermes-sign-ins"), RecordCipher(AndroidCredentialKey)),
            computerScope = computerID.toString(),
        )
    }
}

internal fun credentialRecordKey(authority: CredentialAuthority, computerScope: String = "independent"): String {
    recordBindingBytes(computerScope)
    recordBindingBytes(authority.endpoint)
    recordBindingBytes(authority.principal)
    return buildJsonArray {
        add(JsonPrimitive("bighelp.credential.v1"))
        add(JsonPrimitive(computerScope))
        add(JsonPrimitive(authority.endpoint))
        add(JsonPrimitive(authority.principal))
    }.toString()
}
