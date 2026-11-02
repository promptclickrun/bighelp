package app.bighelp.android.storage

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.CREATE
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Encrypted, atomic compare-and-replace for records in an app-private, backup-excluded directory.
 * Run on an I/O dispatcher. The credential adapter supplies an unambiguous authority-bound record key.
 */
class ProtectedRecordStore internal constructor(
    private val directory: File,
    private val cipher: RecordCipher,
    private val files: RecordFileOperations,
) {
    constructor(directory: File, cipher: RecordCipher) : this(directory, cipher, SystemRecordFileOperations)

    fun read(key: String): ByteArray? = locked(key) { file -> readRecord(key, file) }

    /** A disk error after rename/delete can mean it committed. Read back before retrying any write. */
    fun compareAndSet(key: String, expected: ByteArray?, replacement: ByteArray?): Boolean = locked(key) { file ->
        if (replacement != null && replacement.size > RecordCipher.MAXIMUM_RECORD_BYTES) {
            throw RecordStorageException(StorageProblem.RecordTooLarge)
        }
        val current = readRecord(key, file)
        val matches = if (expected == null || current == null) expected == null && current == null
            else MessageDigest.isEqual(expected, current)
        if (!matches) return@locked false
        if (replacement == null) {
            Files.deleteIfExists(file.toPath())
            syncDirectory()
        } else {
            writeRecord(file, cipher.encrypt(key, replacement))
        }
        true
    }

    /** Deliberate local recovery only. A valid record or a transient failure is never discarded. */
    fun discardUnreadable(key: String): Boolean = locked(key) { file ->
        try {
            readRecord(key, file)
            false
        } catch (failure: RecordStorageException) {
            if (failure.problem !in setOf(StorageProblem.CorruptRecord, StorageProblem.RecordTooLarge, StorageProblem.KeyMissing)) {
                throw failure
            }
            Files.deleteIfExists(file.toPath())
            syncDirectory()
            true
        }
    }

    private fun readRecord(key: String, file: File): ByteArray? {
        val stream = try {
            files.read(file)
        } catch (_: NoSuchFileException) {
            return null
        }
        val bytes = stream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = input.read(buffer, 0, minOf(buffer.size, RecordCipher.MAXIMUM_ENVELOPE_BYTES + 1 - output.size()))
                if (count < 0) break
                output.write(buffer, 0, count)
                if (output.size() > RecordCipher.MAXIMUM_ENVELOPE_BYTES) {
                    throw RecordStorageException(StorageProblem.RecordTooLarge)
                }
            }
            output.toByteArray()
        }
        return cipher.decrypt(key, bytes)
    }

    private fun writeRecord(file: File, bytes: ByteArray) {
        val pending = File.createTempFile(".record-", ".pending", directory)
        try {
            files.write(pending).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            // Never replace a valid credential with a partly written file.
            files.move(pending.toPath(), file.toPath())
            syncDirectory()
        } finally {
            Files.deleteIfExists(pending.toPath())
        }
    }

    private fun syncDirectory() {
        FileChannel.open(directory.toPath(), READ).use { it.force(true) }
    }

    private fun <T> locked(key: String, body: (File) -> T): T {
        val binding = recordBindingBytes(key)
        try {
            Files.createDirectories(directory.toPath())
            val digest = MessageDigest.getInstance("SHA-256").digest(binding)
                .joinToString("") { "%02x".format(it) }
            val file = File(directory, "$digest.sealed")
            val monitor = monitors.computeIfAbsent(file.canonicalPath) { Any() }
            return synchronized(monitor) {
                FileChannel.open(File(directory, "$digest.lock").toPath(), CREATE, WRITE).use { channel ->
                    // The monitor handles multiple authenticators in this process; the lock covers another process.
                    channel.lock().use { body(file) }
                }
            }
        } catch (_: IOException) {
            throw RecordStorageException(StorageProblem.DiskUnavailable)
        }
    }

    private companion object {
        val monitors = ConcurrentHashMap<String, Any>()
    }
}

internal interface RecordFileOperations {
    fun read(file: File): InputStream
    fun write(file: File): FileOutputStream
    fun move(from: Path, to: Path)
}

internal object SystemRecordFileOperations : RecordFileOperations {
    override fun read(file: File): InputStream = Files.newInputStream(file.toPath())
    override fun write(file: File) = FileOutputStream(file)
    override fun move(from: Path, to: Path) {
        Files.move(from, to, ATOMIC_MOVE, REPLACE_EXISTING)
    }
}
