package app.bighelp.android.live

import android.content.Context
import app.bighelp.android.storage.AndroidCredentialKey
import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.recordBindingBytes
import app.bighelp.hermes.CredentialAuthority
import app.bighelp.hermes.HermesEndpoint
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** Saved setup metadata, never a claim that a computer is currently connected. */
internal data class SavedComputer(
    val id: UUID,
    val name: String,
    val endpoint: HermesEndpoint,
    val principal: String,
    val setupComplete: Boolean,
) {
    val authority get() = CredentialAuthority(endpoint.canonical, principal)
}

internal data class SavedComputerSnapshot(
    val revision: UUID?,
    val computers: List<SavedComputer>,
    val selectedID: UUID?,
)

internal enum class SavedComputersProblem { InvalidChange, Unreadable, Changed }
internal class SavedComputersException(val problem: SavedComputersProblem) : Exception(problem.name)
internal const val SAVED_COMPUTERS_RECORD_KEY = "bighelp.computers.v1"

/**
 * The pending row can be saved before committing credentials, so an interrupted setup remains recoverable.
 * Cancellation can arrive after a write commits. Retire and join owners before cleanup, and read back
 * an uncertain result. Do not wrap these calls in runInterruptible or Future.cancel(true).
 */
internal class SavedComputerStore(
    private val records: ProtectedRecordStore,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun load(): SavedComputerSnapshot = withContext(dispatcher) {
        val raw = records.read(SAVED_COMPUTERS_RECORD_KEY) ?: return@withContext empty()
        try { decode(raw) } finally { raw.fill(0) }
    }

    /** Explicit reset only: callers retire connection owners and clear their unreachable local data first. */
    suspend fun discardUnreadable(): Boolean = withContext(dispatcher) {
        currentCoroutineContext().ensureActive()
        if (records.discardUnreadable(SAVED_COMPUTERS_RECORD_KEY)) return@withContext true
        val raw = records.read(SAVED_COMPUTERS_RECORD_KEY) ?: return@withContext false
        try {
            try {
                decode(raw)
                false
            } catch (_: SavedComputersException) {
                currentCoroutineContext().ensureActive()
                records.compareAndSet(SAVED_COMPUTERS_RECORD_KEY, raw, null)
            }
        } finally { raw.fill(0) }
    }

    suspend fun replace(
        expected: SavedComputerSnapshot,
        computers: List<SavedComputer>,
        selectedID: UUID?,
    ): SavedComputerSnapshot = withContext(dispatcher) {
        val next = SavedComputerSnapshot(UUID.randomUUID(), computers.toList(), selectedID)
        validate(next, SavedComputersProblem.InvalidChange)
        val raw = records.read(SAVED_COMPUTERS_RECORD_KEY)
        try {
            if ((raw?.let(::decode) ?: empty()) != expected) throw SavedComputersException(SavedComputersProblem.Changed)
            val bytes = encode(next)
            try {
                currentCoroutineContext().ensureActive()
                if (!records.compareAndSet(SAVED_COMPUTERS_RECORD_KEY, raw, bytes)) {
                    throw SavedComputersException(SavedComputersProblem.Changed)
                }
            } finally { bytes.fill(0) }
            next
        } finally { raw?.fill(0) }
    }

    private fun validate(snapshot: SavedComputerSnapshot, problem: SavedComputersProblem) {
        fun invalid(): Nothing = throw SavedComputersException(problem)
        if (snapshot.computers.size > 32 || snapshot.computers.map { it.id }.toSet().size != snapshot.computers.size) invalid()
        if (snapshot.selectedID != null && snapshot.computers.none { it.id == snapshot.selectedID }) invalid()
        for (computer in snapshot.computers) {
            if (computer.name.isBlank() || computer.name.any { Character.isISOControl(it) }) invalid()
            try {
                if (recordBindingBytes(computer.name).size > 4_096) invalid()
                recordBindingBytes(computer.principal)
            } catch (_: app.bighelp.android.storage.RecordStorageException) { invalid() }
        }
    }

    private fun encode(snapshot: SavedComputerSnapshot): ByteArray = buildJsonObject {
        put("schemaVersion", 1)
        put("revision", snapshot.revision.toString())
        put("selectedID", snapshot.selectedID?.toString()?.let(::JsonPrimitive) ?: JsonNull)
        put("computers", buildJsonArray {
            for (computer in snapshot.computers) add(buildJsonObject {
                put("id", computer.id.toString())
                put("name", computer.name)
                put("endpoint", computer.endpoint.canonical)
                put("allowPrivateHttp", computer.endpoint.allowPrivateHttp)
                put("principal", computer.principal)
                put("setupComplete", computer.setupComplete)
            })
        })
    }.toString().toByteArray(Charsets.UTF_8)

    private fun decode(bytes: ByteArray): SavedComputerSnapshot {
        try {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            val root = Json.parseToJsonElement(text) as? JsonObject ?: unreadable()
            val version = root["schemaVersion"] as? JsonPrimitive ?: unreadable()
            if (version.isString || version.intOrNull != 1) unreadable()
            val revision = uuid(root.text("revision"))
            val selected = if (root["selectedID"] == null || root["selectedID"] is JsonNull) null
                else uuid(root.text("selectedID"))
            val rows = root["computers"] as? JsonArray ?: unreadable()
            if (rows.size > 32) unreadable()
            val computers = rows.map { row ->
                val value = row as? JsonObject ?: unreadable()
                val endpointText = value.text("endpoint")
                val allowPrivate = value.bool("allowPrivateHttp")
                val endpoint = HermesEndpoint.parse(endpointText, allowPrivate)
                if (endpoint.canonical != endpointText) unreadable()
                SavedComputer(
                    uuid(value.text("id")), value.text("name"), endpoint, value.text("principal"),
                    if (value["setupComplete"] == null) false else value.bool("setupComplete"),
                )
            }
            return SavedComputerSnapshot(revision, computers, selected).also { validate(it, SavedComputersProblem.Unreadable) }
        } catch (_: Exception) {
            unreadable()
        }
    }

    private fun uuid(text: String): UUID = UUID.fromString(text).also { if (it.toString() != text) unreadable() }
    private fun JsonObject.text(key: String): String = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: unreadable()
    private fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: unreadable()
    private fun unreadable(): Nothing = throw SavedComputersException(SavedComputersProblem.Unreadable)
    private fun empty() = SavedComputerSnapshot(null, emptyList(), null)

    companion object {
        fun create(context: Context) = SavedComputerStore(
            ProtectedRecordStore(File(context.noBackupFilesDir, "saved-computers"), RecordCipher(AndroidCredentialKey)),
        )
    }
}
