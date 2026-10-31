package app.bighelp.hermes.chat

import app.bighelp.hermes.utf8Length
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The platform-neutral durable store the chat repository writes through. The app supplies Android I/O
 * (protected, atomic, backup-excluded files); this module only defines what must be stored, the exact scope
 * of each record and the byte ceilings, so persistence is the same everywhere and a write failure is a typed
 * result the repository can act on. Two classes of record never mix:
 *
 *  * **Durable** records ([RecordKind.durable]): drafts, the submission journal, creation intents and the
 *    identity (routing aliases) of a conversation. They hold text a person typed or evidence of a possibly
 *    sent mutation, so a quota or eviction pass must never remove them. [ChatStore.commit] applies a list of
 *    them atomically (all or none) and throws [ChatStoreException] when it cannot; the repository then sends
 *    nothing.
 *  * **Cache** records: the catalog and retained history. They only make the next open faster. A cache write
 *    is best effort ([ChatStore.putCache]) and an implementation may drop any of them at any time; losing a
 *    cache record never changes what the person sees as unsent or uncertain.
 */
object ChatStoreLimits {
    /** One message a person types or sends, as UTF-8. */
    const val MAXIMUM_MESSAGE_TEXT_BYTES = 1_048_576

    /** The JSON-escaped form of one message (it must also fit one 2 MiB gateway frame with its envelope). */
    const val MAXIMUM_ENCODED_MESSAGE_BYTES = 2 * 1_048_576 - 16_384

    /** Attachment references (names/handles, never attachment bytes) kept with a draft or journal entry. */
    const val MAXIMUM_ATTACHMENT_REFERENCES = 16
    const val MAXIMUM_ATTACHMENT_REFERENCE_BYTES = 1_024

    /** One composer draft record: its text, escaped, plus references and envelope. */
    const val MAXIMUM_DRAFT_RECORD_BYTES = MAXIMUM_ENCODED_MESSAGE_BYTES + 65_536

    /** One journal entry: the exact outgoing text and the original composer text, each escaped, plus envelope. */
    const val MAXIMUM_JOURNAL_ENTRY_BYTES = 2 * MAXIMUM_ENCODED_MESSAGE_BYTES + 65_536

    /** Unresolved (uncertain or refused) entries one conversation may hold; a new send is refused past this. */
    const val MAXIMUM_UNRESOLVED_ENTRIES = 32

    const val MAXIMUM_CREATION_RECORD_BYTES = 16_384
    const val MAXIMUM_IDENTITY_RECORD_BYTES = 131_072
    const val MAXIMUM_FORMER_STORED_IDS = 128

    const val MAXIMUM_CATALOG_CACHE_BYTES = 8 * 1_048_576
    const val MAXIMUM_HISTORY_CACHE_BYTES = 32 * 1_048_576 + 1_048_576
}

/**
 * One configured computer: the app's own UUID for the saved entry, its canonical endpoint
 * ([app.bighelp.hermes.HermesEndpoint.canonical]) and the exact signed-in principal. Everything stored for a
 * computer is scoped by all three, so another sign-in at the same address never sees these records.
 */
data class HostScope(val computerId: String, val endpoint: String, val principal: String) {
    init {
        require(Coordinates.isUuid(computerId)) { "The computer ID is a UUID" }
        require(Coordinates.isValid(endpoint, 2_048)) { "Invalid endpoint" }
        require(Coordinates.isValid(principal, 1_024)) { "Invalid principal" }
    }

    override fun toString() = "HostScope($computerId)"
}

/** A conversation's storage scope: the computer, the exact profile and the immutable anchor. */
data class ConversationScope(val host: HostScope, val profile: String, val anchor: String) {
    init {
        require(Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) { "Invalid profile" }
        require(Coordinates.isValid(anchor, Coordinates.MAXIMUM_COORDINATE_BYTES)) { "Invalid anchor" }
    }

    val ref: ConversationRef get() = ConversationRef(profile, anchor)
}

enum class RecordKind(val durable: Boolean, val maximumBytes: Int) {
    /** The composer text of one conversation (and its attachment references). */
    Draft(true, ChatStoreLimits.MAXIMUM_DRAFT_RECORD_BYTES),

    /** One unresolved submission: an uncertain send, or a definite refusal kept for the person. */
    Journal(true, ChatStoreLimits.MAXIMUM_JOURNAL_ENTRY_BYTES),

    /** One create intent per computer and profile. */
    Creation(true, ChatStoreLimits.MAXIMUM_CREATION_RECORD_BYTES),

    /** A conversation's stored tip, former stored IDs (routing aliases) and registry facts. */
    Identity(true, ChatStoreLimits.MAXIMUM_IDENTITY_RECORD_BYTES),

    CatalogCache(false, ChatStoreLimits.MAXIMUM_CATALOG_CACHE_BYTES),
    HistoryCache(false, ChatStoreLimits.MAXIMUM_HISTORY_CACHE_BYTES),
}

/**
 * The exact address of one record. Two keys are equal only when every field is equal; [canonical] is an
 * unambiguous, length-prefixed rendering a store may hash into a file name (the record body repeats its
 * scope, and the repository checks it on read, so a collision could never cross scopes unnoticed).
 */
class RecordKey private constructor(
    val kind: RecordKind,
    val host: HostScope,
    val profile: String?,
    val anchor: String?,
    val entry: String?,
) {
    val canonical: String = listOf(
        kind.name, host.computerId, host.endpoint, host.principal, profile.orEmpty(), anchor.orEmpty(), entry.orEmpty(),
        "${profile != null}${anchor != null}${entry != null}",
    ).joinToString("|") { "${it.length}:$it" }

    override fun equals(other: Any?) = other is RecordKey && other.canonical == canonical
    override fun hashCode() = canonical.hashCode()
    override fun toString() = "RecordKey(${kind.name})"

    companion object {
        /**
         * Rebuilds a key from its stored components (a file-backed store persists them to answer [ChatStore.keys]
         * after a restart). Each kind has one shape; any other combination is an `IllegalArgumentException`.
         */
        fun of(kind: RecordKind, host: HostScope, profile: String?, anchor: String?, entry: String?): RecordKey {
            val shape = when (kind) {
                RecordKind.Draft, RecordKind.Identity, RecordKind.HistoryCache -> profile != null && anchor != null && entry == null
                RecordKind.Journal -> profile != null && anchor != null && entry != null && Coordinates.isUuid(entry)
                RecordKind.Creation -> profile != null && anchor == null && entry == null
                RecordKind.CatalogCache -> profile == null && anchor == null && entry == null
            }
            require(shape) { "Invalid key shape for ${kind.name}" }
            profile?.let { require(Coordinates.isValid(it, Coordinates.MAXIMUM_PROFILE_BYTES)) { "Invalid profile" } }
            anchor?.let { require(Coordinates.isValid(it)) { "Invalid anchor" } }
            return RecordKey(kind, host, profile, anchor, entry)
        }

        fun draft(scope: ConversationScope) = RecordKey(RecordKind.Draft, scope.host, scope.profile, scope.anchor, null)
        fun journal(scope: ConversationScope, entryId: String): RecordKey {
            require(Coordinates.isUuid(entryId)) { "A journal entry ID is a UUID" }
            return RecordKey(RecordKind.Journal, scope.host, scope.profile, scope.anchor, entryId)
        }
        fun creation(host: HostScope, profile: String) = RecordKey(RecordKind.Creation, host, profile, null, null)
        fun identity(scope: ConversationScope) = RecordKey(RecordKind.Identity, scope.host, scope.profile, scope.anchor, null)
        fun catalog(host: HostScope) = RecordKey(RecordKind.CatalogCache, host, null, null, null)
        fun history(scope: ConversationScope) = RecordKey(RecordKind.HistoryCache, scope.host, scope.profile, scope.anchor, null)
    }
}

sealed interface StoreOp {
    /** [bytes] never exceed `key.kind.maximumBytes`; a store refuses a larger record with [ChatStoreException.Kind.TooLarge]. */
    class Put(val key: RecordKey, val bytes: ByteArray) : StoreOp
    class Delete(val key: RecordKey) : StoreOp
}

/** A durable write that was not applied. Nothing of the failed transaction is visible afterwards. */
class ChatStoreException(val kind: Kind, cause: Throwable? = null) : Exception(kind.name, cause) {
    enum class Kind { Unavailable, TooLarge, Corrupt, QuotaExceeded }
}

interface ChatStore {
    /** The exact record, or null when absent. A corrupt record is [ChatStoreException.Kind.Corrupt], never silently empty. */
    suspend fun read(key: RecordKey): ByteArray?

    /** Keys of [kind] for [host], optionally narrowed to one profile and anchor. Used to find retained work after a restart. */
    suspend fun keys(host: HostScope, kind: RecordKind, profile: String? = null, anchor: String? = null): List<RecordKey>

    /**
     * Applies [ops] atomically, durable kinds only (a cache kind is `IllegalArgumentException`). Either every
     * operation is visible afterwards, also after a process restart, or none is and this throws.
     */
    suspend fun commit(ops: List<StoreOp>)

    /** Best effort: may be dropped, never throws for capacity or I/O, never affects durable records. */
    suspend fun putCache(key: RecordKey, bytes: ByteArray)
    suspend fun deleteCache(key: RecordKey)
}

/**
 * A volatile reference store: atomic by construction, bounded like any other. For tests and the labeled demo;
 * the app's real store implements [ChatStore] over protected files.
 */
open class MemoryChatStore : ChatStore {
    private val lock = Mutex()
    protected val records = LinkedHashMap<RecordKey, ByteArray>()
    private val closed = AtomicBoolean(false)

    override suspend fun read(key: RecordKey): ByteArray? = lock.withLock { records[key]?.copyOf() }

    override suspend fun keys(host: HostScope, kind: RecordKind, profile: String?, anchor: String?): List<RecordKey> =
        lock.withLock {
            records.keys.filter {
                it.kind == kind && it.host == host && (profile == null || it.profile == profile) &&
                    (anchor == null || it.anchor == anchor)
            }
        }

    override suspend fun commit(ops: List<StoreOp>) {
        for (op in ops) {
            val key = op.key()
            require(key.kind.durable) { "A cache record is not a durable commit" }
            if (op is StoreOp.Put && op.bytes.size > key.kind.maximumBytes) throw ChatStoreException(ChatStoreException.Kind.TooLarge)
        }
        lock.withLock {
            beforeApply(ops)
            for (op in ops) when (op) {
                is StoreOp.Put -> records[op.key] = op.bytes.copyOf()
                is StoreOp.Delete -> records.remove(op.key)
            }
            afterApply()
        }
    }

    override suspend fun putCache(key: RecordKey, bytes: ByteArray) {
        require(!key.kind.durable) { "A durable record is not a cache write" }
        if (bytes.size > key.kind.maximumBytes) return
        lock.withLock { records[key] = bytes.copyOf() }
    }

    override suspend fun deleteCache(key: RecordKey) {
        require(!key.kind.durable) { "A durable record is not a cache delete" }
        lock.withLock { records.remove(key) }
    }

    /** Hook for subclasses (failure injection, snapshots): runs under the lock before any operation is applied; throw to refuse the whole commit. */
    protected open fun beforeApply(ops: List<StoreOp>) = Unit

    /** Runs under the lock after a commit was applied in memory. */
    protected open fun afterApply() = Unit

    private fun StoreOp.key() = when (this) {
        is StoreOp.Put -> key
        is StoreOp.Delete -> key
    }
}

/** Coordinate and text validation shared by every record and response check. Compares bytes, never normalized text. */
internal object Coordinates {
    const val MAXIMUM_COORDINATE_BYTES = 512
    const val MAXIMUM_PROFILE_BYTES = 128

    /** Nonempty, bounded, exactly its trimmed self, no control or format characters (Swift `validateIdentifier`). */
    fun isValid(value: String, maximumBytes: Int = MAXIMUM_COORDINATE_BYTES): Boolean {
        if (value.isEmpty() || utf8Length(value) > maximumBytes) return false
        if (value != value.trim { Character.isWhitespace(it) || Character.isSpaceChar(it) }) return false
        var index = 0
        while (index < value.length) {
            val point = value.codePointAt(index)
            index += Character.charCount(point)
            val type = Character.getType(point)
            if (type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()) return false
        }
        return true
    }

    fun isUuid(value: String): Boolean = UUID_PATTERN.matches(value)

    private val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
}
