package app.bighelp.android.storage

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
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
class ProtectedRecordStore(private val directory: File, private val cipher: RecordCipher) {
    fun read(key: String): ByteArray? = locked(key) { file -> readRecord(key, file) }

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

    private fun readRecord(key: String, file: File): ByteArray? {
        if (!file.exists()) return null
        val bytes = file.inputStream().use { input ->
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
            FileOutputStream(pending).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            // Never replace a valid credential with a partly written file.
            Files.move(pending.toPath(), file.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
            syncDirectory()
        } finally {
            Files.deleteIfExists(pending.toPath())
        }
    }

    private fun syncDirectory() {
        FileChannel.open(directory.toPath(), READ).use { it.force(true) }
    }

    private fun <T> locked(key: String, body: (File) -> T): T {
        require(key.isNotEmpty() && key.toByteArray(Charsets.UTF_8).size <= 8_192)
        try {
            Files.createDirectories(directory.toPath())
            val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
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
