package app.bighelp.android.live

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.StaleCredentialException
import app.bighelp.hermes.StoredAuth
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidCredentialAdapterTest {
    @Test fun credentialCodecRotationAndComputerIsolationUseTheRealAndroidStore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val firstID = UUID.randomUUID()
        val secondID = UUID.randomUUID()
        val endpoint = HermesEndpoint.parse("https://storage-probe.example.test/hermes")
        val first = SavedConnection(endpoint, StoredAuth.Bearer("synthetic-access-one", "synthetic-refresh-one", 1_950_000_000), "basic", "fixture")
        val next = SavedConnection(endpoint, StoredAuth.Bearer("synthetic-access-two", "synthetic-refresh-two", 1_950_000_001), "basic", "fixture")
        val other = SavedConnection(endpoint, StoredAuth.Bearer("synthetic-independent", null, null), "basic", "fixture")
        fun firstVault() = AndroidCredentialStore.create(context, firstID)
        fun secondVault() = AndroidCredentialStore.create(context, secondID)
        try {
            firstVault().replace(null, first)
            secondVault().replace(null, other)
            assertEquals(first, firstVault().load(first.authority))
            assertEquals(other, secondVault().load(other.authority))
            firstVault().replace(first, next)
            try {
                firstVault().delete(first)
                fail("A stale sign-out must not delete the new token")
            } catch (_: StaleCredentialException) {
            }
            assertEquals(next, firstVault().load(next.authority))
            assertEquals(other, secondVault().load(other.authority))
        } finally {
            firstVault().load(first.authority)?.let { firstVault().delete(it) }
            secondVault().load(other.authority)?.let { secondVault().delete(it) }
        }
    }
}
