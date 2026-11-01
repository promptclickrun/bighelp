package app.bighelp.android.storage

import android.content.Context
import app.bighelp.hermes.chat.ChatStore
import app.bighelp.hermes.chat.ChatStoreException
import app.bighelp.hermes.chat.HostScope
import app.bighelp.hermes.chat.RecordKey
import app.bighelp.hermes.chat.RecordKind
import app.bighelp.hermes.chat.StoreOp
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.CREATE
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest
import java.util.zip.CRC32
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The chat repository's durable store on app-private, backup-excluded files.
 *
 * **Durable records** (drafts, the submission journal, create intents, identity) live in one append-only
 * transaction log. A commit is exactly one CRC-protected frame, written and flushed before it becomes visible,
 * so "all of its operations or none" holds across a crash without a recovery protocol: a restart replays whole
 * frames and drops a torn tail. A write that fails is cut back off the file, so a refused send leaves no trace.
 * Damage that is not a torn tail fails closed ([ChatStoreException.Kind.Corrupt]) instead of silently losing the
 * records after it; [discardUnreadable] is the explicit local reset. The log is compacted (live records
 * rewritten to a new file, then an atomic rename) when most of it is dead. Durable records are never evicted.
 *
 * **Cache records** (catalog, retained history) are one checksummed file each under `cache/`, written best
 * effort and evicted oldest-first past a byte budget. A damaged cache file is dropped, never reported.
 *
 * Nothing secret is stored here (the repository never writes one); credentials stay in the Keystore-sealed
 * stores. This store assumes one process, which is how the app runs.
 */
class AndroidChatStore internal constructor(
    private val directory: File,
    private val dispatcher: CoroutineDispatcher,
    private val files: ChatStoreFiles,
    private val tuning: ChatStoreTuning,
) : ChatStore {
    constructor(directory: File, dispatcher: CoroutineDispatcher = Dispatchers.IO) :
        this(directory, dispatcher, SystemChatStoreFiles, ChatStoreTuning())

    private class Slot(val position: Long, val length: Int, val crc: Int)
    private class Encoded(val bytes: ByteArray, val puts: List<Triple<RecordKey, Int, Slot>>)

    private val lock = Any()
    private var logFile: ChatLogFile? = null
    private var index = HashMap<RecordKey, Slot>()
    private var goodLength = 0L
    private var liveBytes = 0L
    private var loadFailure: ChatStoreException? = null
    private var nextCompactionGarbage = tuning.compactionMinimumGarbage

    private val logPath get() = File(directory, LOG_NAME)
    private val cacheDirectory get() = File(directory, CACHE_NAME)

    // ---- ChatStore

    override suspend fun read(key: RecordKey): ByteArray? = withContext(dispatcher) {
        synchronized(lock) { if (key.kind.durable) readDurable(key) else readCache(key) }
    }

    override suspend fun keys(host: HostScope, kind: RecordKind, profile: String?, anchor: String?): List<RecordKey> =
        withContext(dispatcher) {
            synchronized(lock) {
                val all = if (kind.durable) { ensureLoaded(); index.keys.toList() } else cacheKeys()
                all.filter {
                    it.kind == kind && it.host == host && (profile == null || it.profile == profile) &&
                        (anchor == null || it.anchor == anchor)
                }.sortedBy { it.canonical }
            }
        }

    override suspend fun commit(ops: List<StoreOp>) {
        var total = 0L
        for (op in ops) when (op) {
            is StoreOp.Put -> {
                require(op.key.kind.durable) { "A cache record is not a durable commit" }
                if (op.bytes.size > op.key.kind.maximumBytes) throw ChatStoreException(ChatStoreException.Kind.TooLarge)
                total += op.bytes.size
            }
            is StoreOp.Delete -> require(op.key.kind.durable) { "A cache record is not a durable commit" }
        }
        if (total > tuning.maximumCommitBytes || ops.size > MAXIMUM_OPERATIONS) throw ChatStoreException(ChatStoreException.Kind.TooLarge)
        if (ops.isEmpty()) return
        withContext(dispatcher) { synchronized(lock) { commitLocked(ops) } }
    }

    override suspend fun putCache(key: RecordKey, bytes: ByteArray) {
        require(!key.kind.durable) { "A durable record is not a cache write" }
        if (bytes.size > key.kind.maximumBytes) return
        withContext(dispatcher) { synchronized(lock) { try { writeCache(key, bytes) } catch (_: IOException) { } catch (_: RuntimeException) { } } }
    }

    override suspend fun deleteCache(key: RecordKey) {
        require(!key.kind.durable) { "A durable record is not a cache delete" }
        withContext(dispatcher) { synchronized(lock) { cacheFile(key).delete() } }
    }

    // ---- app-side operations

    /** Removing a computer removes everything stored for it: durable records, then cached ones. Safe to run again. */
    suspend fun purge(computerId: String) = withContext(dispatcher) {
        synchronized(lock) {
            cacheDirectory.listFiles { file -> file.name.endsWith(CACHE_SUFFIX) }?.forEach { file ->
                val key = try { readCacheHeader(file) } catch (_: IOException) { null } catch (_: RuntimeException) { null }
                if (key == null || key.host.computerId == computerId) file.delete()
            }
            ensureLoaded()
            val doomed = index.keys.filter { it.host.computerId == computerId }
            for (chunk in doomed.chunked(PURGE_CHUNK)) commitLocked(chunk.map { StoreOp.Delete(it) })
        }
    }

    /**
     * Explicit local reset after [ChatStoreException.Kind.Corrupt]: removes the damaged log so a fresh one starts.
     * The drafts and unresolved sends it held are gone, which is why only a deliberate action calls this.
     */
    suspend fun discardUnreadable(): Boolean = withContext(dispatcher) {
        synchronized(lock) {
            try {
                ensureLoaded()
                false
            } catch (failure: ChatStoreException) {
                if (failure.kind != ChatStoreException.Kind.Corrupt) throw failure
                resetHandle()
                try { Files.deleteIfExists(logPath.toPath()); files.syncDirectory(directory) } catch (e: IOException) {
                    throw ChatStoreException(ChatStoreException.Kind.Unavailable, e)
                }
                loadFailure = null
                true
            }
        }
    }

    fun close() = synchronized(lock) { resetHandle() }

    // ---- durable log

    private fun ensureLoaded() {
        loadFailure?.let { throw it }
        if (logFile != null) return
        try {
            if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) throw IOException("No directory")
            File(directory, COMPACT_NAME).delete()
            val log = files.open(logPath)
            try {
                replay(log)
            } catch (failure: Throwable) {
                try { log.close() } catch (_: IOException) { }
                index = HashMap(); liveBytes = 0; goodLength = 0
                throw failure
            }
            logFile = log
        } catch (failure: ChatStoreException) {
            if (failure.kind == ChatStoreException.Kind.Corrupt) loadFailure = failure
            throw failure
        } catch (failure: IOException) {
            throw ChatStoreException(kindOf(failure), failure)
        }
    }

    /** Rebuilds the index from whole frames. A torn tail is cut off; damage followed by more data is [Corrupt]. */
    private fun replay(log: ChatLogFile) {
        var size = log.size()
        if (size < FILE_MAGIC.size) {
            // Only a file that holds a prefix of our own header (a creation cut short) may be started over.
            if (!FILE_MAGIC.copyOf(size.toInt()).contentEquals(log.read(0, size.toInt()))) throw corrupt()
            log.truncate(0)
            log.append(FILE_MAGIC)
            log.sync()
            files.syncDirectory(directory)
            size = FILE_MAGIC.size.toLong()
        } else if (!log.read(0, FILE_MAGIC.size).contentEquals(FILE_MAGIC)) {
            throw corrupt()
        }
        var position = FILE_MAGIC.size.toLong()
        val replayed = HashMap<RecordKey, Slot>()
        var torn = false
        while (position < size) {
            val remaining = size - position
            if (remaining < FRAME_HEADER) { torn = true; break }
            val header = ByteBuffer.wrap(log.read(position, FRAME_HEADER))
            val magic = ByteArray(4).also { header.get(it) }
            if (!magic.contentEquals(FRAME_MAGIC)) {
                // A crash can leave the tail zero-filled; anything else here is damage, not an interrupted write.
                if (remaining <= TAIL_PROBE_BYTES && log.read(position, remaining.toInt()).all { it == 0.toByte() }) { torn = true; break }
                throw corrupt()
            }
            val bodyLength = header.int
            if (bodyLength < 4 || bodyLength > tuning.maximumCommitBytes + FRAME_SLACK) throw corrupt()
            val frameEnd = position + FRAME_HEADER + bodyLength + 4
            if (frameEnd > size) { torn = true; break }
            val frame = log.read(position, (frameEnd - position).toInt())
            if (crc(frame, 0, frame.size - 4) != ByteBuffer.wrap(frame, frame.size - 4, 4).int) {
                // Only the very last frame can be an interrupted write; a bad frame with data after it is damage.
                if (frameEnd == size) { torn = true; break }
                throw corrupt()
            }
            applyFrame(frame, position, replayed)
            position = frameEnd
        }
        if (torn) {
            log.truncate(position)
            log.sync()
        }
        index = replayed
        goodLength = position
        liveBytes = replayed.values.sumOf { it.length.toLong() }
    }

    private fun applyFrame(frame: ByteArray, frameStart: Long, into: MutableMap<RecordKey, Slot>) {
        try {
            val body = ByteBuffer.wrap(frame, FRAME_HEADER, frame.size - FRAME_HEADER - 4)
            val count = body.int
            if (count < 0 || count > MAXIMUM_OPERATIONS) throw corrupt()
            repeat(count) {
                val type = body.get().toInt()
                val key = readKey(body)
                when (type) {
                    OP_PUT -> {
                        val length = body.int
                        val crc = body.int
                        if (length < 0 || length > key.kind.maximumBytes || length > body.remaining()) throw corrupt()
                        into[key] = Slot(frameStart + body.position(), length, crc)
                        // Through Buffer: ByteBuffer.position(int) only returns ByteBuffer on newer Android runtimes.
                        (body as java.nio.Buffer).position(body.position() + length)
                    }
                    OP_DELETE -> into.remove(key)
                    else -> throw corrupt()
                }
            }
            if (body.hasRemaining()) throw corrupt()
        } catch (failure: ChatStoreException) {
            throw failure
        } catch (_: RuntimeException) {
            throw corrupt()
        }
    }

    private fun readDurable(key: RecordKey): ByteArray? {
        ensureLoaded()
        val slot = index[key] ?: return null
        val bytes = try {
            logFile!!.read(slot.position, slot.length)
        } catch (_: EOFException) {
            throw corrupt()
        } catch (failure: IOException) {
            throw ChatStoreException(kindOf(failure), failure)
        }
        if (crc(bytes, 0, bytes.size) != slot.crc) throw corrupt()
        return bytes
    }

    private fun commitLocked(ops: List<StoreOp>) {
        val log = readyLog()
        val frame = encode(ops)
        val start = goodLength
        try {
            log.append(frame.bytes)
            log.sync()
        } catch (failure: IOException) {
            // Take the failed frame back off the file. If even that fails, the next commit retries it first.
            try { log.truncate(start); log.sync() } catch (_: IOException) { }
            throw ChatStoreException(kindOf(failure), failure)
        }
        goodLength = start + frame.bytes.size
        var put = 0
        for (op in ops) when (op) {
            is StoreOp.Put -> {
                val (_, offset, slot) = frame.puts[put++]
                index.put(op.key, Slot(start + offset, slot.length, slot.crc))?.let { liveBytes -= it.length }
                liveBytes += slot.length
            }
            is StoreOp.Delete -> index.remove(op.key)?.let { liveBytes -= it.length }
        }
        compactIfWorthIt()
    }

    /** The open log, with any unconfirmed tail from an earlier failed write removed first. */
    private fun readyLog(): ChatLogFile {
        ensureLoaded()
        val log = logFile!!
        try {
            val size = log.size()
            if (size < goodLength) throw corrupt()
            if (size > goodLength) { log.truncate(goodLength); log.sync() }
        } catch (failure: IOException) {
            throw ChatStoreException(ChatStoreException.Kind.Unavailable, failure)
        }
        return log
    }

    private fun encode(ops: List<StoreOp>): Encoded {
        val payload = ops.sumOf { (it as? StoreOp.Put)?.bytes?.size ?: 0 }
        val out = ByteArrayOutputStream(FRAME_HEADER + 16 + payload + ops.size * 1_200)
        val data = DataOutputStream(out)
        data.write(FRAME_MAGIC)
        data.writeInt(0)
        data.writeInt(ops.size)
        val puts = ArrayList<Triple<RecordKey, Int, Slot>>()
        for (op in ops) when (op) {
            is StoreOp.Put -> {
                data.writeByte(OP_PUT)
                writeKey(data, op.key)
                val crc = crc(op.bytes, 0, op.bytes.size)
                data.writeInt(op.bytes.size)
                data.writeInt(crc)
                puts += Triple(op.key, out.size(), Slot(0, op.bytes.size, crc))
                data.write(op.bytes)
            }
            is StoreOp.Delete -> {
                data.writeByte(OP_DELETE)
                writeKey(data, op.key)
            }
        }
        val unsealed = out.toByteArray()
        val frame = unsealed.copyOf(unsealed.size + 4)
        ByteBuffer.wrap(frame).putInt(4, unsealed.size - FRAME_HEADER)
        ByteBuffer.wrap(frame).putInt(unsealed.size, crc(frame, 0, unsealed.size))
        return Encoded(frame, puts)
    }

    // ---- compaction

    private fun compactIfWorthIt() {
        val garbage = goodLength - FILE_MAGIC.size - liveBytes
        if (garbage < nextCompactionGarbage || garbage <= liveBytes) return
        try {
            compact()
            nextCompactionGarbage = tuning.compactionMinimumGarbage
        } catch (_: IOException) {
            File(directory, COMPACT_NAME).delete()
            nextCompactionGarbage = garbage + tuning.compactionMinimumGarbage
        } catch (_: ChatStoreException) {
            File(directory, COMPACT_NAME).delete()
            nextCompactionGarbage = garbage + tuning.compactionMinimumGarbage
        }
    }

    /** Live records into a new file, flushed, then an atomic rename over the log. A crash leaves one or the other. */
    private fun compact() {
        val temp = File(directory, COMPACT_NAME)
        temp.delete()
        val rewritten = HashMap<RecordKey, Slot>()
        var position = FILE_MAGIC.size.toLong()
        val out = files.open(temp)
        try {
            out.append(FILE_MAGIC)
            for ((key, slot) in index) {
                val payload = readDurable(key) ?: continue
                val frame = encode(listOf(StoreOp.Put(key, payload)))
                out.append(frame.bytes)
                rewritten[key] = Slot(position + frame.puts[0].second, slot.length, slot.crc)
                position += frame.bytes.size
            }
            out.sync()
        } finally {
            out.close()
        }
        files.replace(temp, logPath)
        files.syncDirectory(directory)
        // The old handle names the replaced file; swap to the new one or force a reload.
        resetHandle()
        try {
            logFile = files.open(logPath)
            index = rewritten
            goodLength = position
        } catch (_: IOException) {
            // The commit that led here is already durable; the next operation reloads from the compacted log.
        }
    }

    private fun resetHandle() {
        try { logFile?.close() } catch (_: IOException) { }
        logFile = null
    }

    // ---- caches

    private fun cacheFile(key: RecordKey) = File(cacheDirectory, sha256(key.canonical) + CACHE_SUFFIX)

    private fun writeCache(key: RecordKey, bytes: ByteArray) {
        val dir = cacheDirectory
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) return
        val target = cacheFile(key)
        val temp = File(dir, ".${target.name}.tmp")
        val head = ByteArrayOutputStream()
        DataOutputStream(head).use { data ->
            data.write(CACHE_MAGIC)
            writeKey(data, key)
            data.writeInt(bytes.size)
            data.writeInt(crc(bytes, 0, bytes.size))
        }
        try {
            FileOutputStream(temp).use { out -> out.write(head.toByteArray()); out.write(bytes) }
            SystemChatStoreFiles.replace(temp, target)
        } finally {
            temp.delete()
        }
        evictCaches(dir, keep = target)
    }

    private fun evictCaches(dir: File, keep: File) {
        val all = dir.listFiles() ?: return
        all.filter { it.name.endsWith(".tmp") }.forEach { it.delete() }
        val cached = all.filter { it.name.endsWith(CACHE_SUFFIX) }
        var total = cached.sumOf { it.length() }
        for (file in cached.sortedWith(compareBy({ it.lastModified() }, { it.name }))) {
            if (total <= tuning.cacheBudgetBytes) break
            if (file == keep) continue
            total -= file.length()
            file.delete()
        }
    }

    private fun readCache(key: RecordKey): ByteArray? {
        val file = cacheFile(key)
        if (!file.isFile) return null
        try {
            if (file.length() > key.kind.maximumBytes + CACHE_HEADER_SLACK) throw corrupt()
            val raw = file.readBytes()
            val buffer = ByteBuffer.wrap(raw)
            val magic = ByteArray(CACHE_MAGIC.size).also { buffer.get(it) }
            if (!magic.contentEquals(CACHE_MAGIC) || readKey(buffer) != key) throw corrupt()
            val length = buffer.int
            val crc = buffer.int
            if (length < 0 || length != buffer.remaining() || length > key.kind.maximumBytes) throw corrupt()
            val payload = ByteArray(length).also { buffer.get(it) }
            if (crc(payload, 0, payload.size) != crc) throw corrupt()
            return payload
        } catch (_: IOException) {
            file.delete()
        } catch (_: ChatStoreException) {
            file.delete()
        } catch (_: RuntimeException) {
            file.delete()
        }
        return null
    }

    private fun readCacheHeader(file: File): RecordKey? {
        val head = file.inputStream().use { stream ->
            val probe = ByteArray(CACHE_HEADER_PROBE_BYTES)
            var filled = 0
            while (filled < probe.size) {
                val count = stream.read(probe, filled, probe.size - filled)
                if (count < 0) break
                filled += count
            }
            probe.copyOf(filled)
        }
        val buffer = ByteBuffer.wrap(head)
        val magic = ByteArray(CACHE_MAGIC.size).also { buffer.get(it) }
        return if (magic.contentEquals(CACHE_MAGIC)) readKey(buffer) else null
    }

    private fun cacheKeys(): List<RecordKey> =
        cacheDirectory.listFiles { file -> file.name.endsWith(CACHE_SUFFIX) }.orEmpty().mapNotNull { file ->
            try { readCacheHeader(file) } catch (_: IOException) { null } catch (_: RuntimeException) { null }
        }

    // ---- encoding

    private fun writeKey(out: DataOutputStream, key: RecordKey) {
        out.writeByte(kindCode(key.kind))
        writeString(out, key.host.computerId)
        writeString(out, key.host.endpoint)
        writeString(out, key.host.principal)
        out.writeByte((if (key.profile != null) 1 else 0) or (if (key.anchor != null) 2 else 0) or (if (key.entry != null) 4 else 0))
        key.profile?.let { writeString(out, it) }
        key.anchor?.let { writeString(out, it) }
        key.entry?.let { writeString(out, it) }
    }

    private fun readKey(buffer: ByteBuffer): RecordKey {
        val kind = kindOf(buffer.get().toInt())
        val host = HostScope(readString(buffer), readString(buffer), readString(buffer))
        val flags = buffer.get().toInt()
        if (flags and 7.inv() != 0) throw corrupt()
        val profile = if (flags and 1 != 0) readString(buffer) else null
        val anchor = if (flags and 2 != 0) readString(buffer) else null
        val entry = if (flags and 4 != 0) readString(buffer) else null
        return try { RecordKey.of(kind, host, profile, anchor, entry) } catch (_: IllegalArgumentException) { throw corrupt() }
    }

    private fun writeString(out: DataOutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        out.writeShort(bytes.size)
        out.write(bytes)
    }

    private fun readString(buffer: ByteBuffer): String {
        val length = buffer.short.toInt() and 0xFFFF
        if (length > buffer.remaining()) throw corrupt()
        val bytes = ByteArray(length).also { buffer.get(it) }
        return try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            throw corrupt()
        }
    }

    // Fixed codes, not ordinals: reordering the enum must never change what a file means.
    private fun kindCode(kind: RecordKind): Int = when (kind) {
        RecordKind.Draft -> 1
        RecordKind.Journal -> 2
        RecordKind.Creation -> 3
        RecordKind.Identity -> 4
        RecordKind.CatalogCache -> 5
        RecordKind.HistoryCache -> 6
    }

    private fun kindOf(code: Int): RecordKind = when (code) {
        1 -> RecordKind.Draft
        2 -> RecordKind.Journal
        3 -> RecordKind.Creation
        4 -> RecordKind.Identity
        5 -> RecordKind.CatalogCache
        6 -> RecordKind.HistoryCache
        else -> throw corrupt()
    }

    private fun kindOf(failure: IOException): ChatStoreException.Kind {
        val text = failure.message.orEmpty().lowercase()
        return if ("no space left" in text || "quota" in text) ChatStoreException.Kind.QuotaExceeded else ChatStoreException.Kind.Unavailable
    }

    private fun corrupt() = ChatStoreException(ChatStoreException.Kind.Corrupt)

    private fun crc(bytes: ByteArray, offset: Int, length: Int): Int = CRC32().apply { update(bytes, offset, length) }.value.toInt()

    private fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    companion object {
        internal const val LOG_NAME = "durable.log"
        internal const val COMPACT_NAME = "durable.log.compact"
        private const val CACHE_NAME = "cache"
        private const val CACHE_SUFFIX = ".cache"
        private val FILE_MAGIC = "BHCHATL1".toByteArray(Charsets.US_ASCII)
        private val FRAME_MAGIC = "BHFR".toByteArray(Charsets.US_ASCII)
        private val CACHE_MAGIC = "BHCHATC1".toByteArray(Charsets.US_ASCII)
        private const val FRAME_HEADER = 8
        private const val FRAME_SLACK = 1 shl 20
        private const val TAIL_PROBE_BYTES = 1 shl 16
        private const val CACHE_HEADER_SLACK = 8_192
        private const val CACHE_HEADER_PROBE_BYTES = 4_096
        private const val OP_PUT = 1
        private const val OP_DELETE = 2
        private const val MAXIMUM_OPERATIONS = 4_096
        private const val PURGE_CHUNK = 1_024

        fun create(context: Context) = AndroidChatStore(File(context.noBackupFilesDir, "chat-store"))
    }
}

/** Sizes that tests shrink; the defaults are the shipping values. */
internal class ChatStoreTuning(
    /** Dead bytes in the log before a rewrite is considered (it must also exceed the live bytes). */
    val compactionMinimumGarbage: Long = 4L * 1024 * 1024,
    /** Total cache bytes kept; the oldest files go first. */
    val cacheBudgetBytes: Long = 96L * 1024 * 1024,
    /** One commit's payload ceiling. No documented record combination comes near it. */
    val maximumCommitBytes: Int = 24 * 1024 * 1024,
)

/** The log file operations, as a seam so a test can fail a write, a flush, a truncate or a rename. */
internal interface ChatLogFile : AutoCloseable {
    fun size(): Long
    fun read(position: Long, length: Int): ByteArray
    fun append(bytes: ByteArray)
    fun sync()
    fun truncate(size: Long)
}

internal interface ChatStoreFiles {
    fun open(file: File): ChatLogFile
    fun replace(from: File, to: File)
    fun syncDirectory(directory: File)
}

internal object SystemChatStoreFiles : ChatStoreFiles {
    override fun open(file: File): ChatLogFile = SystemLogFile(FileChannel.open(file.toPath(), CREATE, READ, WRITE))

    override fun replace(from: File, to: File) {
        Files.move(from.toPath(), to.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
    }

    override fun syncDirectory(directory: File) {
        FileChannel.open(directory.toPath(), READ).use { it.force(true) }
    }
}

private class SystemLogFile(private val channel: FileChannel) : ChatLogFile {
    override fun size(): Long = channel.size()

    override fun read(position: Long, length: Int): ByteArray {
        val buffer = ByteBuffer.allocate(length)
        var at = position
        while (buffer.hasRemaining()) {
            val count = channel.read(buffer, at)
            if (count < 0) throw EOFException()
            at += count
        }
        return buffer.array()
    }

    override fun append(bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        var at = channel.size()
        while (buffer.hasRemaining()) at += channel.write(buffer, at)
    }

    override fun sync() = channel.force(true)

    override fun truncate(size: Long) {
        channel.truncate(size)
    }

    override fun close() = channel.close()
}
