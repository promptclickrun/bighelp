package app.bighelp.android.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.security.KeyStore
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the real Android Keystore and app filesystem rather than the JVM crypto provider. */
@RunWith(AndroidJUnit4::class)
class AndroidCredentialStorageTest {
    @Test fun deviceKeyIsNonExportable() {
        val key = AndroidCredentialKey.getOrCreate()
        assertEquals("AES", key.algorithm)
        assertNull(key.encoded)
    }

    @Test fun protectedRecordReopensAndAStaleAuthenticatorCannotReplaceOrDeleteIt() = withStore { root ->
        val binding = "storage-probe:https://example.test/hermes|basic|synthetic-person"
        val original = "synthetic-refresh-one".toByteArray()
        val replacement = "synthetic-refresh-two".toByteArray()
        fun vault() = ProtectedRecordStore(root, RecordCipher(AndroidCredentialKey))
        assertTrue(vault().compareAndSet(binding, null, original))
        assertArrayEquals(original, vault().read(binding))
        assertTrue(vault().compareAndSet(binding, original, replacement))
        assertFalse(vault().compareAndSet(binding, original, "stale".toByteArray()))
        assertFalse(vault().compareAndSet(binding, original, null))
        assertArrayEquals(replacement, vault().read(binding))
        assertTrue(vault().compareAndSet(binding, replacement, null))
        assertNull(vault().read(binding))
    }

    @Test fun aModifiedCiphertextIsRefusedOnAndroid() = withStore { root ->
        val vault = ProtectedRecordStore(root, RecordCipher(AndroidCredentialKey))
        val binding = "storage-probe:synthetic-authority"
        assertTrue(vault.compareAndSet(binding, null, "synthetic-token".toByteArray()))
        val file = root.listFiles()!!.single { it.extension == "sealed" }
        val bytes = file.readBytes()
        assertFalse(bytes.toString(Charsets.ISO_8859_1).contains("synthetic-token"))
        file.writeBytes(bytes.also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() })
        try {
            vault.read(binding)
            fail("Modified ciphertext must not be adopted")
        } catch (failure: RecordStorageException) {
            assertEquals(StorageProblem.CorruptRecord, failure.problem)
        }
    }

    @Test fun maximumRecordRoundTripsWithTheAndroidKey() = withStore { root ->
        val vault = ProtectedRecordStore(root, RecordCipher(AndroidCredentialKey))
        val value = ByteArray(65_536) { (it % 127).toByte() }
        assertTrue(vault.compareAndSet("storage-probe:maximum", null, value))
        assertArrayEquals(value, vault.read("storage-probe:maximum"))
    }

    @Test fun missingKeyIsNotRecreatedByReadingAndAllowsExplicitLocalRecovery() = withStore { root ->
        val alias = "bighelp.storage-probe.${UUID.randomUUID()}"
        val keys = AndroidKeyStoreRecordKeys(alias)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val vault = ProtectedRecordStore(root, RecordCipher(keys))
        val binding = "storage-probe:missing-key"
        try {
            assertTrue(vault.compareAndSet(binding, null, "synthetic-first".toByteArray()))
            keyStore.deleteEntry(alias)
            try {
                vault.read(binding)
                fail("Reading must not create a replacement key")
            } catch (failure: RecordStorageException) {
                assertEquals(StorageProblem.KeyMissing, failure.problem)
            }
            assertFalse(keyStore.containsAlias(alias))
            assertTrue(vault.discardUnreadable(binding))
            val next = "synthetic-new-sign-in".toByteArray()
            assertTrue(vault.compareAndSet(binding, null, next))
            assertArrayEquals(next, vault.read(binding))
        } finally {
            keyStore.deleteEntry(alias)
        }
    }

    private fun withStore(block: (File) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.noBackupFilesDir, "storage-probe-${UUID.randomUUID()}")
        try {
            block(root)
        } finally {
            root.deleteRecursively()
        }
    }
}
