package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.android.storage.RecordFileOperations
import app.bighelp.android.storage.SystemRecordFileOperations
import app.bighelp.hermes.CredentialAuthority
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.StaleCredentialException
import app.bighelp.hermes.StoredAuth
import javax.crypto.KeyGenerator
import java.io.File
import java.io.InputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AndroidCredentialStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun store() = AndroidCredentialStore(ProtectedRecordStore(temporary.root, RecordCipher { key }))
    private fun saved(user: String = "synthetic-person", token: String = "access-one") = SavedConnection(
        HermesEndpoint.parse("https://example.test/hermes"),
        StoredAuth.Bearer(token, "synthetic-refresh", 1_900_000_000), "basic", user,
    )

    @Test fun savesARealCredentialRecordAndReopensItsExactAuthority() = runBlocking {
        val value = saved()
        store().replace(null, value)
        assertEquals(value, store().load(value.authority))
        assertNull(store().load(saved("another-person").authority))
        assertNull(store().load(CredentialAuthority("https://other.example.test/hermes", value.principal)))
    }

    @Test fun rotatingCredentialCannotOverwriteANewerRotationOrSignOut() = runBlocking {
        val first = saved()
        val next = saved(token = "access-two")
        val vault = store()
        vault.replace(null, first)
        store().replace(first, next)
        try {
            vault.replace(first, saved(token = "stale-answer"))
            fail("A stale refresh must not write")
        } catch (_: StaleCredentialException) {
        }
        try {
            vault.delete(first)
            fail("A stale sign-out must not erase a newer sign-in")
        } catch (_: StaleCredentialException) {
        }
        assertEquals(next, vault.load(next.authority))
        vault.delete(next)
        assertNull(store().load(next.authority))
        try {
            vault.replace(next, first)
            fail("A retired rotation must not recreate a deleted record")
        } catch (_: StaleCredentialException) {
        }
    }

    @Test fun differentPrincipalsOnTheSameComputerKeepSeparateRecords() = runBlocking {
        val first = saved("caf\u00e9")
        val second = saved("cafe\u0301")
        val vault = store()
        vault.replace(null, first)
        vault.replace(null, second)
        assertEquals(first, store().load(first.authority))
        assertEquals(second, store().load(second.authority))
        vault.delete(first)
        assertEquals(second, store().load(second.authority))
    }

    @Test fun replacementCannotMoveCredentialsToAnotherPrincipal() = runBlocking {
        val first = saved()
        val other = saved("another-person")
        val vault = store()
        vault.replace(null, first)
        try {
            vault.replace(first, other)
            fail("Replacing a credential must retain its authority")
        } catch (_: IllegalArgumentException) {
        }
        assertEquals(first, store().load(first.authority))
        assertNull(store().load(other.authority))
    }

    @Test fun invalidCredentialsAreRejectedBeforeSaving() = runBlocking {
        val invalid = saved(token = "contains a space")
        try {
            store().replace(null, invalid)
            fail("An invalid credential must not be saved")
        } catch (failure: HermesException) {
            assertEquals(HermesException.Kind.InvalidCredentials, failure.kind)
        }
        assertNull(store().load(invalid.authority))
    }

    @Test fun anUnreadableRecordNeedsExplicitRecoveryAndDoesNotBecomeMissing() = runBlocking {
        val value = saved()
        val vault = store()
        vault.replace(null, value)
        assertFalse(vault.discardUnreadable(value.authority))
        temporary.root.listFiles()!!.single { it.extension == "sealed" }.writeBytes(byteArrayOf(1))
        try {
            vault.load(value.authority)
            fail("An unreadable saved sign-in must not look absent")
        } catch (failure: RecordStorageException) {
            assertEquals(StorageProblem.CorruptRecord, failure.problem)
        }
        assertTrue(vault.discardUnreadable(value.authority))
        assertNull(vault.load(value.authority))
        vault.replace(null, value)
        assertEquals(value, vault.load(value.authority))
    }

    @Test fun malformedPrincipalNeverAliasesAValidQuestionMark() = runBlocking {
        try {
            store().load(CredentialAuthority("https://example.test", "\ud800"))
            fail("Malformed UTF-16 must not be replaced while deriving a record key")
        } catch (failure: RecordStorageException) {
            assertEquals(StorageProblem.InvalidBinding, failure.problem)
        }
    }

    @Test fun aDecodedSnapshotCanRotateARecordWithDifferentJsonOrderAndOptionalFields() = runBlocking {
        val first = saved()
        val fields = Json.parseToJsonElement(first.toBytes().toString(Charsets.UTF_8)) as JsonObject
        val reordered = JsonObject((fields + ("futureOptionalField" to JsonPrimitive("ignored"))).toSortedMap())
            .toString().toByteArray(Charsets.UTF_8)
        val records = ProtectedRecordStore(temporary.root, RecordCipher { key })
        assertTrue(records.compareAndSet(credentialRecordKey(first.authority), null, reordered))
        val vault = AndroidCredentialStore(records)
        assertEquals(first, vault.load(first.authority))
        val next = saved(token = "rotated-token")
        vault.replace(first, next)
        assertEquals(next, store().load(first.authority))
    }

    @Test fun aMismatchedDecodedAuthorityIsRefusedAndCanBeExplicitlyRemoved() = runBlocking {
        val first = saved()
        val records = ProtectedRecordStore(temporary.root, RecordCipher { key })
        assertTrue(records.compareAndSet(credentialRecordKey(first.authority), null, saved("another-person").toBytes()))
        val vault = AndroidCredentialStore(records)
        try {
            vault.load(first.authority)
            fail("A decoded sign-in must match the requested authority")
        } catch (failure: HermesException) {
            assertEquals(HermesException.Kind.SavedConnectionInvalid, failure.kind)
        }
        assertTrue(vault.discardUnreadable(first.authority))
        assertNull(vault.load(first.authority))
    }

    @Test fun twoComputerEntriesCanKeepIndependentSignInsForTheSameAuthority() = runBlocking {
        val records = ProtectedRecordStore(temporary.root, RecordCipher { key })
        val first = saved()
        val second = saved(token = "independent-sign-in")
        val firstComputer = AndroidCredentialStore(records, "computer-one")
        val secondComputer = AndroidCredentialStore(records, "computer-two")
        firstComputer.replace(null, first)
        secondComputer.replace(null, second)
        assertEquals(first, firstComputer.load(first.authority))
        assertEquals(second, secondComputer.load(first.authority))
        firstComputer.delete(first)
        assertEquals(second, secondComputer.load(first.authority))
    }

    @Test fun anAutomaticDashboardTokenKeepsItsModeAndNoProviderIdentity() = runBlocking {
        val value = SavedConnection(
            HermesEndpoint.parse("https://example.test/hermes"),
            StoredAuth.DashboardSession("synthetic-dashboard-token", automatic = true), null, null,
        )
        val vault = store()
        vault.replace(null, value)
        val loaded = vault.load(value.authority)!!
        assertEquals(value, loaded)
        assertNull(loaded.provider)
        assertNull(loaded.userId)
    }

    @Test fun cancellingDuringTheSnapshotReadPreventsTheInitialWrite() = runBlocking {
        val value = saved()
        supervisorScope {
            lateinit var job: Deferred<Unit>
            var reads = 0
            val io = object : RecordFileOperations by SystemRecordFileOperations {
                override fun read(file: File): InputStream {
                    reads++
                    job.cancel()
                    return SystemRecordFileOperations.read(file)
                }
            }
            val vault = AndroidCredentialStore(ProtectedRecordStore(temporary.root, RecordCipher { key }, io))
            job = async(start = CoroutineStart.LAZY) { vault.replace(null, value) }
            job.start()
            try { job.await(); fail("Cancelled work must not write") } catch (_: CancellationException) { }
            assertEquals(1, reads)
        }
        assertNull(store().load(value.authority))
    }

    @Test fun cancellingDuringTheDeleteSnapshotReadKeepsTheSignIn() = runBlocking {
        val value = saved()
        store().replace(null, value)
        supervisorScope {
            lateinit var job: Deferred<Unit>
            var reads = 0
            val io = object : RecordFileOperations by SystemRecordFileOperations {
                override fun read(file: File): InputStream {
                    reads++
                    job.cancel()
                    return SystemRecordFileOperations.read(file)
                }
            }
            val vault = AndroidCredentialStore(ProtectedRecordStore(temporary.root, RecordCipher { key }, io))
            job = async(start = CoroutineStart.LAZY) { vault.delete(value) }
            job.start()
            try { job.await(); fail("Cancelled work must not delete") } catch (_: CancellationException) { }
            assertEquals(1, reads)
        }
        assertEquals(value, store().load(value.authority))
    }

    @Test fun anUnreadableRecordCannotBeOverwrittenByANewSignInOrDeletedAsAValidOne() = runBlocking {
        val value = saved()
        store().replace(null, value)
        val file = temporary.root.listFiles()!!.single { it.extension == "sealed" }
        val broken = byteArrayOf(1, 2, 3)
        file.writeBytes(broken)
        for (action in listOf<suspend () -> Unit>({ store().replace(null, value) }, { store().delete(value) })) {
            try { action(); fail("Unreadable data must not be overwritten") }
            catch (failure: RecordStorageException) { assertEquals(StorageProblem.CorruptRecord, failure.problem) }
            assertArrayEquals(broken, file.readBytes())
        }
    }

    @Test fun aFutureSchemaMustNotBeOverwrittenWithoutExplicitRecovery() = runBlocking {
        val value = saved()
        val raw = """{"schemaVersion":2}""".toByteArray()
        val records = ProtectedRecordStore(temporary.root, RecordCipher { key })
        val binding = credentialRecordKey(value.authority)
        assertTrue(records.compareAndSet(binding, null, raw))
        try { store().replace(null, value); fail("Future data must not be replaced") }
        catch (failure: HermesException) { assertEquals(HermesException.Kind.SavedConnectionInvalid, failure.kind) }
        assertArrayEquals(raw, records.read(binding))
        assertTrue(store().discardUnreadable(value.authority))
        assertNull(store().load(value.authority))
    }

    @Test fun recoveryCannotDiscardAConcurrentValidCredentialReplacement() = runBlocking {
        val value = saved(token = "concurrent-sign-in")
        val replacementRoot = temporary.newFolder("replacement")
        val replacementStore = AndroidCredentialStore(ProtectedRecordStore(replacementRoot, RecordCipher { key }))
        replacementStore.replace(null, value)
        val envelope = replacementRoot.listFiles()!!.single { it.extension == "sealed" }.readBytes()
        val records = ProtectedRecordStore(temporary.root, RecordCipher { key })
        assertTrue(records.compareAndSet(credentialRecordKey(value.authority), null, """{"schemaVersion":2}""".toByteArray()))
        var reads = 0
        val io = object : RecordFileOperations by SystemRecordFileOperations {
            override fun read(file: File): InputStream {
                if (++reads == 3) file.writeBytes(envelope)
                return SystemRecordFileOperations.read(file)
            }
        }
        val racing = AndroidCredentialStore(ProtectedRecordStore(temporary.root, RecordCipher { key }, io))
        assertFalse(racing.discardUnreadable(value.authority))
        assertEquals(value, store().load(value.authority))
    }

    @Test fun persistedKeyAndFileNameStayStableAcrossSerializationLibraryUpdates() = runBlocking {
        val value = saved(user = "fixture")
        val scope = "11111111-1111-4111-8111-111111111111"
        val expected = "[\"bighelp.credential.v1\",\"11111111-1111-4111-8111-111111111111\",\"https://example.test/hermes\",\"basic\\u001ffixture\"]"
        assertEquals(expected, credentialRecordKey(value.authority, scope))
        val vault = AndroidCredentialStore(ProtectedRecordStore(temporary.root, RecordCipher { key }), scope)
        vault.replace(null, value)
        assertEquals(
            "856540a6c667754b7e7e0c88ac378baa15a2803dccc9df8a12fa4553adfb20ca.sealed",
            temporary.root.listFiles()!!.single { it.extension == "sealed" }.name,
        )
    }
}
