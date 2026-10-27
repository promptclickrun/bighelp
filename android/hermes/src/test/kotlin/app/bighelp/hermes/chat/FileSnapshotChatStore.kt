package app.bighelp.hermes.chat

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * A reopenable, file-backed [ChatStore] for tests: every commit rewrites one snapshot file through a temp file
 * and an atomic move, so a crash (or an injected failure) leaves either the old or the new snapshot, never a mix.
 * A second instance over the same file is the "process restarted" store. Cache records are not persisted:
 * a store may drop them at any time, and a reopen does.
 */
class FileSnapshotChatStore(private val file: File) : MemoryChatStore() {
    /** When non-null the next commit fails with this and applies nothing (a full disk, a revoked directory). */
    @Volatile var failNextCommit: ChatStoreException? = null

    /** Commits that reached [beforeApply] successfully. */
    @Volatile var commits = 0
        private set

    init {
        if (file.exists()) load()
    }

    override fun beforeApply(ops: List<StoreOp>) {
        failNextCommit?.let { failNextCommit = null; throw it }
        // Build the next snapshot first and write it; only after the move succeeds does memory change.
        val next = LinkedHashMap(records.filterKeys { it.kind.durable })
        for (op in ops) when (op) {
            is StoreOp.Put -> next[op.key] = op.bytes.copyOf()
            is StoreOp.Delete -> next.remove(op.key)
        }
        write(next)
        commits++
    }

    /** Drops every cache record, as a storage-pressure pass may. Durable records stay. */
    fun evictCaches() {
        records.keys.removeAll { !it.kind.durable }
    }

    private fun write(snapshot: Map<RecordKey, ByteArray>) {
        val temp = File(file.parentFile, file.name + ".tmp")
        try {
            DataOutputStream(temp.outputStream().buffered()).use { out ->
                out.writeInt(snapshot.size)
                for ((key, bytes) in snapshot) {
                    out.writeInt(key.kind.ordinal)
                    out.writeUTF(key.host.computerId); out.writeUTF(key.host.endpoint); out.writeUTF(key.host.principal)
                    for (part in listOf(key.profile, key.anchor, key.entry)) {
                        out.writeBoolean(part != null)
                        if (part != null) out.writeUTF(part)
                    }
                    out.writeInt(bytes.size); out.write(bytes)
                }
            }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: IOException) {
            temp.delete()
            throw ChatStoreException(ChatStoreException.Kind.Unavailable, e)
        }
    }

    private fun load() {
        DataInputStream(file.inputStream().buffered()).use { input ->
            repeat(input.readInt()) {
                val kind = RecordKind.entries[input.readInt()]
                val host = HostScope(input.readUTF(), input.readUTF(), input.readUTF())
                val parts = List(3) { if (input.readBoolean()) input.readUTF() else null }
                val bytes = ByteArray(input.readInt()).also { input.readFully(it) }
                records[RecordKey.of(kind, host, parts[0], parts[1], parts[2])] = bytes
            }
        }
    }
}
