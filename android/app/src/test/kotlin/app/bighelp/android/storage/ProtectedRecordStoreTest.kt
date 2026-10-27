package app.bighelp.android.storage

import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.KeyGenerator
import org.junit.Assert.*
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

    private fun refuses(problem: StorageProblem, action: () -> Unit) {
        try {
            action()
            fail("Expected $problem")
        } catch (failure: RecordStorageException) {
            assertEquals(problem, failure.problem)
        }
    }
}
