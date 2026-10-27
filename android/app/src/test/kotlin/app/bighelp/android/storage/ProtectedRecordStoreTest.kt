package app.bighelp.android.storage

import java.nio.file.Files
import java.nio.file.Path
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.security.ProviderException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.KeyGenerator
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProtectedRecordStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val binding = "https://example.test/hermes|basic|synthetic-person"
    private fun store() = ProtectedRecordStore(temporary.root, RecordCipher { key })
    private fun bytes(value: String) = value.toByteArray(Charsets.UTF_8)

    @Test fun savedCredentialSurvivesReopeningWithoutPlaintextOnDisk() {
        val value = bytes("synthetic-access-token and synthetic-refresh-token")
        assertTrue(store().compareAndSet(binding, null, value))
        assertArrayEquals(value, store().read(binding))
        val saved = temporary.root.listFiles()!!.single { it.extension == "sealed" }.readBytes()
        assertFalse(saved.toString(Charsets.ISO_8859_1).contains("synthetic-access-token"))
        assertFalse(saved.toString(Charsets.ISO_8859_1).contains("synthetic-refresh-token"))
    }

    @Test fun oldRefreshCannotOverwriteOrEraseANewerSignIn() {
        val first = bytes("refresh-1")
        val rotated = bytes("refresh-2")
        val newer = bytes("newer-sign-in")
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, first))
        assertTrue(vault.compareAndSet(binding, first, rotated))
        assertTrue(store().compareAndSet(binding, rotated, newer))
        assertFalse(vault.compareAndSet(binding, rotated, bytes("stale-answer")))
        assertFalse(vault.compareAndSet(binding, rotated, null))
        assertArrayEquals(newer, store().read(binding))
    }

    @Test fun concurrentAuthenticatorsHaveOnlyOneReplacementWinner() {
        val initial = bytes("initial")
        assertTrue(store().compareAndSet(binding, null, initial))
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val attempts = listOf("answer-a", "answer-b").map { answer ->
                executor.submit<Boolean> {
                    start.await()
                    store().compareAndSet(binding, initial, bytes(answer))
                }
            }
            start.countDown()
            assertEquals(1, attempts.count { it.get(5, TimeUnit.SECONDS) })
            assertTrue(store().read(binding)!!.toString(Charsets.UTF_8) in setOf("answer-a", "answer-b"))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test fun ciphertextCannotBeMovedToAnotherAuthority() {
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, bytes("first")))
        val first = temporary.root.listFiles()!!.single { it.extension == "sealed" }
        val other = "https://other.example.test|basic|synthetic-person"
        assertTrue(vault.compareAndSet(other, null, bytes("second")))
        val second = temporary.root.listFiles()!!.single { it.extension == "sealed" && it != first }
        Files.copy(first.toPath(), second.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        refuses(StorageProblem.CorruptRecord) { vault.read(other) }
        assertArrayEquals(bytes("first"), vault.read(binding))
    }

    @Test fun modifiedOrTruncatedRecordRequiresRecoveryInsteadOfBecomingSignedOut() {
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, bytes("secret")))
        val file = temporary.root.listFiles()!!.single { it.extension == "sealed" }
        val original = file.readBytes()
        file.writeBytes(original.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() })
        refuses(StorageProblem.CorruptRecord) { vault.read(binding) }
        file.writeBytes(original.copyOf(12))
        refuses(StorageProblem.CorruptRecord) { vault.read(binding) }
        file.writeBytes(original.copyOf(original.size - 1))
        refuses(StorageProblem.CorruptRecord) { vault.read(binding) }
        file.writeBytes(original.copyOf().also { it[8] = (it[8].toInt() xor 1).toByte() })
        refuses(StorageProblem.CorruptRecord) { vault.read(binding) }
    }

    @Test fun wrongDeviceKeyCannotReadARecord() {
        assertTrue(store().compareAndSet(binding, null, bytes("secret")))
        val anotherKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val anotherDevice = ProtectedRecordStore(temporary.root, RecordCipher { anotherKey })
        refuses(StorageProblem.CorruptRecord) { anotherDevice.read(binding) }
    }

    @Test fun sizeLimitIsInBytesAndRefusalPreservesThePriorRecord() {
        val limit = ByteArray(65_536) { 0x61 }
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, limit))
        assertArrayEquals(limit, store().read(binding))
        refuses(StorageProblem.RecordTooLarge) {
            vault.compareAndSet(binding, limit, ByteArray(65_537))
        }
        assertArrayEquals(limit, store().read(binding))
    }

    @Test fun anOversizedFileIsRejectedBeforeDecode() {
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, bytes("secret")))
        temporary.root.listFiles()!!.single { it.extension == "sealed" }.writeBytes(ByteArray(70_000))
        refuses(StorageProblem.RecordTooLarge) { vault.read(binding) }
    }

    @Test fun successfulLocalSignOutRemovesOnlyTheExpectedRecord() {
        val vault = store()
        val value = bytes("saved")
        assertNull(vault.read(binding))
        assertTrue(vault.compareAndSet(binding, null, value))
        assertTrue(vault.compareAndSet(binding, value, null))
        assertNull(store().read(binding))
        assertFalse(vault.compareAndSet(binding, value, bytes("late-refresh")))
    }

    @Test fun encryptingTheSameRecordUsesANewNonce() {
        val cipher = RecordCipher { key }
        val plain = bytes("same-token")
        val first = cipher.encrypt(binding, plain)
        val second = cipher.encrypt(binding, plain)
        assertFalse(first.contentEquals(second))
        assertArrayEquals(plain, cipher.decrypt(binding, first))
        assertArrayEquals(plain, cipher.decrypt(binding, second))
    }

    @Test fun failureToEncryptAReplacementKeepsThePreviousCredential() {
        val value = bytes("saved-sign-in")
        assertTrue(store().compareAndSet(binding, null, value))
        val calls = AtomicInteger()
        val failing = ProtectedRecordStore(temporary.root, RecordCipher {
            if (calls.getAndIncrement() == 0) key else throw IllegalStateException("device key unavailable")
        })
        refuses(StorageProblem.KeyUnavailable) { failing.compareAndSet(binding, value, bytes("new-token")) }
        assertArrayEquals(value, store().read(binding))
        assertFalse(temporary.root.listFiles()!!.any { it.extension == "pending" })
    }

    @Test fun unavailableDiskDoesNotLookLikeAnAbsentSignIn() {
        val notDirectory = temporary.newFile("not-a-directory")
        val vault = ProtectedRecordStore(notDirectory, RecordCipher { key })
        refuses(StorageProblem.DiskUnavailable) { vault.read(binding) }
        refuses(StorageProblem.DiskUnavailable) { vault.compareAndSet(binding, null, bytes("value")) }
    }

    @Test fun distinctOpaquePrincipalStringsHaveSeparateRecords() {
        val first = "https://example.test|basic|caf\u00e9"
        val second = "https://example.test|basic|cafe\u0301"
        val vault = store()
        assertTrue(vault.compareAndSet(first, null, bytes("one")))
        assertTrue(vault.compareAndSet(second, null, bytes("two")))
        assertArrayEquals(bytes("one"), vault.read(first))
        assertArrayEquals(bytes("two"), vault.read(second))
    }

    @Test fun aStatFailureIsNeverTreatedAsAnAbsentRecord() {
        val vault = store()
        assertTrue(vault.compareAndSet(binding, null, bytes("saved")))
        val file = temporary.root.listFiles()!!.single { it.extension == "sealed" }.toPath()
        Files.delete(file)
        Files.createSymbolicLink(file, file.fileName)
        refuses(StorageProblem.DiskUnavailable) { vault.read(binding) }
        refuses(StorageProblem.DiskUnavailable) { vault.compareAndSet(binding, null, bytes("replacement")) }
        refuses(StorageProblem.DiskUnavailable) { vault.discardUnreadable(binding) }
        assertTrue(Files.isSymbolicLink(file))
    }

    @Test fun readingWithAMissingDeviceKeyNeverCreatesAnotherKey() {
        assertTrue(store().compareAndSet(binding, null, bytes("saved")))
        var created = false
        val missing = object : RecordKeyProvider {
            override fun existing() = null
            override fun getOrCreate() = key.also { created = true }
        }
        val vault = ProtectedRecordStore(temporary.root, RecordCipher(missing))
        refuses(StorageProblem.KeyMissing) { vault.read(binding) }
        assertFalse(created)
        assertArrayEquals(bytes("saved"), store().read(binding))
    }

    @Test fun providerRuntimeFailuresAreTypedOnEncryptAndDecrypt() {
        val provider = object : RecordKeyProvider {
            override fun existing() = key
            override fun getOrCreate() = key
        }
        val broken = RecordCipher(provider) { throw ProviderException("synthetic provider failure") }
        refuses(StorageProblem.KeyUnavailable) { broken.encrypt(binding, bytes("secret")) }
        val envelope = RecordCipher { key }.encrypt(binding, bytes("secret"))
        refuses(StorageProblem.KeyUnavailable) { broken.decrypt(binding, envelope) }
    }

    @Test fun unreadableRecordsCanBeExplicitlyDiscardedWithoutDeletingValidOnes() {
        val vault = store()
        assertFalse(vault.discardUnreadable(binding))
        assertTrue(vault.compareAndSet(binding, null, bytes("saved")))
        assertFalse(vault.discardUnreadable(binding))
        val file = temporary.root.listFiles()!!.single { it.extension == "sealed" }
        file.writeBytes(byteArrayOf(1, 2, 3))
        assertTrue(vault.discardUnreadable(binding))
        assertNull(vault.read(binding))
        assertTrue(vault.compareAndSet(binding, null, bytes("new-sign-in")))
    }

    @Test fun aTransientKeyFailureCannotDiscardAnyRecord() {
        assertTrue(store().compareAndSet(binding, null, bytes("saved")))
        val broken = ProtectedRecordStore(temporary.root, RecordCipher { throw ProviderException("unavailable") })
        refuses(StorageProblem.KeyUnavailable) { broken.discardUnreadable(binding) }
        assertArrayEquals(bytes("saved"), store().read(binding))
    }

    @Test fun theReadBudgetStopsAnOversizedInputAfterOneExcessByte() {
        assertTrue(store().compareAndSet(binding, null, bytes("saved")))
        var consumed = 0
        val io = object : RecordFileOperations by SystemRecordFileOperations {
            override fun read(file: File): InputStream = object : FilterInputStream(ByteArray(70_000).inputStream()) {
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                    super.read(bytes, offset, length).also { if (it > 0) consumed += it }
            }
        }
        val vault = ProtectedRecordStore(temporary.root, RecordCipher { key }, io)
        refuses(StorageProblem.RecordTooLarge) { vault.read(binding) }
        assertEquals(RecordCipher.MAXIMUM_ENVELOPE_BYTES + 1, consumed)
    }

    @Test fun partialWriteAndMoveFailureLeaveThePreviousRecordReadable() {
        val original = bytes("saved")
        assertTrue(store().compareAndSet(binding, null, original))
        val failures = listOf(
            object : RecordFileOperations by SystemRecordFileOperations {
                override fun write(file: File): FileOutputStream = object : FileOutputStream(file) {
                    override fun write(bytes: ByteArray) {
                        super.write(bytes, 0, minOf(8, bytes.size))
                        throw IOException("synthetic interrupted write")
                    }
                }
            },
            object : RecordFileOperations by SystemRecordFileOperations {
                override fun move(from: Path, to: Path) { throw IOException("synthetic failed move") }
            },
        )
        for (io in failures) {
            val vault = ProtectedRecordStore(temporary.root, RecordCipher { key }, io)
            refuses(StorageProblem.DiskUnavailable) { vault.compareAndSet(binding, original, bytes("replacement")) }
            assertArrayEquals(original, store().read(binding))
            assertFalse(temporary.root.listFiles()!!.any { it.extension == "pending" })
        }
    }

    @Test fun malformedOpaqueKeysNeverCollapseToAQuestionMark() {
        val vault = store()
        assertTrue(vault.compareAndSet("?", null, bytes("valid")))
        refuses(StorageProblem.InvalidBinding) { vault.read("\ud800") }
        refuses(StorageProblem.InvalidBinding) { vault.compareAndSet("\udc00", null, bytes("invalid")) }
        assertArrayEquals(bytes("valid"), vault.read("?"))
    }

    @Test fun directorySyncFailureCanFollowACommittedReplaceAndNeedsReadback() {
        assumeTrue(System.getProperty("user.name") != "root")
        assumeTrue(temporary.root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
        val vault = store()
        val original = bytes("saved")
        val next = bytes("rotated")
        assertTrue(vault.compareAndSet(binding, null, original))
        val mode = Files.getPosixFilePermissions(temporary.root.toPath())
        try {
            Files.setPosixFilePermissions(
                temporary.root.toPath(),
                java.nio.file.attribute.PosixFilePermissions.fromString("-wx------"),
            )
            refuses(StorageProblem.DiskUnavailable) { vault.compareAndSet(binding, original, next) }
        } finally {
            Files.setPosixFilePermissions(temporary.root.toPath(), mode)
        }
        assertArrayEquals(next, vault.read(binding))
    }

    private fun refuses(problem: StorageProblem, action: () -> Unit) {
        try {
            action()
            fail("Expected $problem")
        } catch (failure: RecordStorageException) {
            assertEquals(problem, failure.problem)
        }
    }
}
