package app.bighelp.android.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.bighelp.hermes.chat.ChatStoreException
import app.bighelp.hermes.chat.ConversationScope
import app.bighelp.hermes.chat.DraftRecord
import app.bighelp.hermes.chat.HostScope
import app.bighelp.hermes.chat.RecordKey
import app.bighelp.hermes.chat.RecordKind
import app.bighelp.hermes.chat.StoreOp
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The chat store on the phone's own filesystem: flushing, the atomic rename that compaction relies on, the
 * directory sync and a restart (a second store over the same folder). Synthetic data, in a folder of its own.
 */
@RunWith(AndroidJUnit4::class)
class AndroidChatStoreDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.noBackupFilesDir, "chat-store-device-test-${UUID.randomUUID()}")
    private val host = HostScope(UUID.randomUUID().toString(), "https://device-probe.example.test", "dashboard-session")
    private val scope = ConversationScope(host, "default", "anchor-1")

    @After fun clean() { directory.deleteRecursively() }

    private fun draft(text: String) = StoreOp.Put(RecordKey.draft(scope), DraftRecord(scope, text, updatedAtMillis = 1).encode())

    @Test fun aCommitAndACacheSurviveANewStoreOverTheSameFolderOnTheRealFilesystem() = runBlocking {
        val first = AndroidChatStore(directory, Dispatchers.IO)
        first.commit(listOf(draft("typed on the device")))
        first.putCache(RecordKey.history(scope), ByteArray(2_000) { 5 })
        first.close()

        val second = AndroidChatStore(directory, Dispatchers.IO)
        assertEquals("typed on the device", DraftRecord.decode(scope, second.read(RecordKey.draft(scope))!!).text)
        assertEquals(2_000, second.read(RecordKey.history(scope))!!.size)
        assertEquals(listOf("anchor-1"), second.keys(host, RecordKind.Draft).map { it.anchor })
    }

    @Test fun compactionRenamesTheNewLogOverTheOldOneAndTheRecordsAreStillThere() = runBlocking {
        val store = AndroidChatStore(directory, Dispatchers.IO, SystemChatStoreFiles, ChatStoreTuning(compactionMinimumGarbage = 20_000))
        repeat(120) { store.commit(listOf(draft("edit $it " + "x".repeat(500)))) }
        assertTrue("The log stayed small: ${File(directory, AndroidChatStore.LOG_NAME).length()}", File(directory, AndroidChatStore.LOG_NAME).length() < 120_000)
        store.close()
        val reopened = AndroidChatStore(directory, Dispatchers.IO)
        assertEquals("edit 119 " + "x".repeat(500), DraftRecord.decode(scope, reopened.read(RecordKey.draft(scope))!!).text)
        assertNull(File(directory, AndroidChatStore.COMPACT_NAME).takeIf { it.exists() })
    }

    @Test fun anOversizeDraftIsRefusedOnTheDeviceToo() = runBlocking {
        val store = AndroidChatStore(directory, Dispatchers.IO)
        val failure = runCatching { store.commit(listOf(StoreOp.Put(RecordKey.draft(scope), ByteArray(RecordKind.Draft.maximumBytes + 1)))) }.exceptionOrNull()
        assertEquals(ChatStoreException.Kind.TooLarge, (failure as ChatStoreException).kind)
        assertTrue(store.keys(host, RecordKind.Draft).isEmpty())
    }
}
