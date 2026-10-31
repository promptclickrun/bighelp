package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.hermes.AccessCredential
import app.bighelp.hermes.CustomHeader
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import java.io.File
import java.util.UUID
import javax.crypto.KeyGenerator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AccessSetupTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun store() = AndroidAccessSetupStore(ProtectedRecordStore(File(temporary.root, "access"), RecordCipher { key }), Dispatchers.Unconfined)
    private val endpoint = HermesEndpoint.parse("https://gated.example.test")

    @Test fun everyKindOfGateRoundTripsAndNothingSecretReachesToString() = runBlocking {
        val id = UUID.randomUUID()
        val setups = listOf(
            AccessSetup(AccessCredential.cloudflareAccess("cf-id-0123", "cf-secret-0123"), emptyList()),
            AccessSetup(AccessCredential.proxyBasic("gate-user", "gate pass with spaces"), CustomHeader.list(listOf("X-Access-Id" to "synthetic"))),
            AccessSetup(null, CustomHeader.list(listOf("X-First" to "1", "X-Second" to "2"))),
        )
        for (setup in setups) {
            store().saveAccess(id, setup)
            assertEquals(setup, store().loadAccess(id))
            val text = setup.toString()
            assertFalse(text.contains("secret") || text.contains("pass") || text.contains("synthetic"))
        }
        assertEquals("The same headers reach the HTTP client either way", setups.last().headers(endpoint).values, store().loadAccess(id).headers(endpoint).values)
    }

    @Test fun anEmptySetupIsNothingStoredAndRemovesWhatWasThere() = runBlocking {
        val id = UUID.randomUUID()
        store().saveAccess(id, AccessSetup(AccessCredential.proxyBasic("u", "p"), emptyList()))
        store().saveAccess(id, AccessSetup.None)
        assertEquals(AccessSetup.None, store().loadAccess(id))
        assertEquals(0, File(temporary.root, "access").listFiles { f -> f.name.endsWith(".sealed") }!!.size)
    }

    @Test fun eachComputerHasItsOwnGateDetails() = runBlocking {
        val one = UUID.randomUUID(); val two = UUID.randomUUID()
        store().saveAccess(one, AccessSetup(AccessCredential.proxyBasic("one", "pw"), emptyList()))
        assertEquals(AccessSetup.None, store().loadAccess(two))
        store().saveAccess(two, AccessSetup(AccessCredential.proxyBasic("two", "pw"), emptyList()))
        store().deleteAccess(one)
        assertEquals(AccessSetup.None, store().loadAccess(one))
        assertNotEquals(AccessSetup.None, store().loadAccess(two))
    }

    @Test fun aRecordThatIsNotOursIsReportedAsUnreadableNotSilentlyEmpty() = runBlocking {
        val id = UUID.randomUUID()
        val records = ProtectedRecordStore(File(temporary.root, "access"), RecordCipher { key })
        records.compareAndSet(accessRecordKey(id), null, "{\"schemaVersion\":9}".toByteArray())
        try { store().loadAccess(id); fail("A newer or foreign record must not read as empty") }
        catch (failure: RecordStorageException) { assertEquals(StorageProblem.CorruptRecord, failure.problem) }
    }

    @Test fun aCloudflareCredentialCannotBeSetUpForPlainHttp() {
        val plain = HermesEndpoint.parse("http://192.168.1.20:9119", allowPrivateHttp = true)
        val setup = AccessSetup(AccessCredential.cloudflareAccess("cf-id-0123", "cf-secret-0123"), emptyList())
        try { setup.headers(plain); fail() } catch (failure: HermesException) { assertEquals(HermesException.Kind.InvalidAccessCredentials, failure.kind) }
        assertTrue(AccessSetup.None.isEmpty)
    }
}
