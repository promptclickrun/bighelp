package app.bighelp.android.storage

import app.bighelp.hermes.chat.ChatStoreException
import app.bighelp.hermes.chat.ConversationScope
import app.bighelp.hermes.chat.DraftRecord
import app.bighelp.hermes.chat.HostScope
import app.bighelp.hermes.chat.JournalEntry
import app.bighelp.hermes.chat.RecordKey
import app.bighelp.hermes.chat.RecordKind
import app.bighelp.hermes.chat.StoreOp
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The adapter behind the chat repository's durable writes. "Process death" is a second store over the same
 * directory, with the log cut or damaged first, so every case proves what a restart would really see.
 */
class AndroidChatStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val directory get() = File(temporary.root, "chat")
    private val host = HostScope("5c3f4f06-2a41-4f6a-9d38-0a54d3a3a111", "http://127.0.0.1:9", "dashboard-session")
    private val scope = ConversationScope(host, "research", "anchor-1")

    private fun open(files: ChatStoreFiles = SystemChatStoreFiles, tuning: ChatStoreTuning = ChatStoreTuning()) =
        AndroidChatStore(directory, Dispatchers.Unconfined, files, tuning)

    private fun draft(text: String, at: ConversationScope = scope) =
        StoreOp.Put(RecordKey.draft(at), DraftRecord(at, text, updatedAtMillis = 5).encode())

    private fun journal(entryId: String, text: String = "hi") =
        StoreOp.Put(RecordKey.journal(scope, entryId), JournalEntry(entryId, scope, "prompt.submit", text, text, emptyList(), 7).encode())

    private fun draftText(store: AndroidChatStore, at: ConversationScope = scope): String? =
        runBlocking { store.read(RecordKey.draft(at))?.let { DraftRecord.decode(at, it).text } }

    private val log get() = File(directory, AndroidChatStore.LOG_NAME)

    // ---- the contract the repository relies on

    @Test fun aCommitIsAllOrNothingAndSurvivesARestart() = runBlocking {
        val store = open()
        val entryId = UUID.randomUUID().toString()
        store.commit(listOf(draft("typing"), journal(entryId)))

        val files = FaultyFiles().apply { appendFailsAfterBytes = 40 }
        val failing = open(files)
        val failure = runCatching { failing.commit(listOf(draft("changed"), StoreOp.Delete(RecordKey.journal(scope, entryId)))) }.exceptionOrNull()
        assertEquals(ChatStoreException.Kind.Unavailable, (failure as ChatStoreException).kind)
        assertEquals("typing", draftText(failing))
        assertNotNull(failing.read(RecordKey.journal(scope, entryId)))

        val reopened = open()
        assertEquals("typing", draftText(reopened))
        val keys = reopened.keys(host, RecordKind.Journal, "research", "anchor-1")
        assertEquals(listOf(entryId), keys.map { it.entry })
        assertEquals("hi", JournalEntry.decode(scope, entryId, reopened.read(keys.single())!!).composerText)
    }

    @Test fun everyDurableKindAcceptsExactlyItsLimitAndRefusesOneByteMoreWithoutApplyingAnythingElse() = runBlocking {
        val store = open()
        store.commit(listOf(draft("keep")))
        val entry = UUID.randomUUID().toString()
        val keys = listOf(
            RecordKey.draft(scope), RecordKey.journal(scope, entry), RecordKey.creation(host, "research"), RecordKey.identity(scope),
        )
        for (key in keys) {
            val limit = key.kind.maximumBytes
            store.commit(listOf(StoreOp.Put(key, ByteArray(limit) { 7 })))
            assertEquals("${key.kind} holds exactly its limit", limit, store.read(key)!!.size)
            val other = ConversationScope(host, "research", "other-${key.kind}")
            val failure = runCatching {
                store.commit(listOf(draft("never applied", other), StoreOp.Put(key, ByteArray(limit + 1))))
            }.exceptionOrNull()
            assertEquals(ChatStoreException.Kind.TooLarge, (failure as ChatStoreException).kind)
            assertNull("The earlier operation of a refused transaction is not applied", store.read(RecordKey.draft(other)))
            assertEquals("${key.kind} keeps its last good value", limit, store.read(key)!!.size)
        }
        // The credential record cap (64 KiB) is not reused: records far above it are normal here.
        assertTrue(RecordKind.Journal.maximumBytes > 65_536)
        val reopened = open()
        for (key in keys) assertEquals(key.kind.maximumBytes, reopened.read(key)!!.size)
    }

    @Test fun aCacheKindIsNotADurableCommitAndADurableKindIsNotACacheWrite() = runBlocking {
        val store = open()
        assertThrows(IllegalArgumentException::class.java) { runBlocking { store.commit(listOf(StoreOp.Put(RecordKey.catalog(host), ByteArray(1)))) } }
        assertThrows(IllegalArgumentException::class.java) { runBlocking { store.putCache(RecordKey.draft(scope), ByteArray(1)) } }
        assertThrows(IllegalArgumentException::class.java) { runBlocking { store.deleteCache(RecordKey.draft(scope)) } }
        Unit
    }

    @Test fun everyRecordIsScopedByComputerEndpointPrincipalProfileAndAnchor() = runBlocking {
        val store = open()
        val variants = listOf(
            scope,
            ConversationScope(host.copy(computerId = UUID.randomUUID().toString()), "research", "anchor-1"),
            ConversationScope(host.copy(endpoint = "https://other.example"), "research", "anchor-1"),
            ConversationScope(host.copy(principal = "basic:someone-else"), "research", "anchor-1"),
            ConversationScope(host, "other-profile", "anchor-1"),
            ConversationScope(host, "research", "anchor-2"),
        )
        variants.forEachIndexed { index, each -> store.commit(listOf(draft("text $index", each))) }
        val reopened = open()
        variants.forEachIndexed { index, each -> assertEquals("text $index", draftText(reopened, each)) }
        assertEquals(1, reopened.keys(host, RecordKind.Draft, "research", "anchor-1").size)
        assertEquals(setOf("anchor-1", "anchor-2"), reopened.keys(host, RecordKind.Draft, "research").map { it.anchor }.toSet())
        // Only the variants that share this exact computer, endpoint and principal are listed for it.
        assertEquals(3, reopened.keys(host, RecordKind.Draft).size)
    }

    // ---- atomicity and restart

    @Test fun aRestartAtEveryByteOfAnInterruptedCommitSeesTheOldStateOrTheWholeNewOne() = runBlocking {
        val entry = UUID.randomUUID().toString()
        val first = open()
        first.commit(listOf(draft("one")))
        first.commit(listOf(journal(entry)))
        val before = log.readBytes()
        val other = ConversationScope(host, "research", "anchor-9")
        first.commit(listOf(draft("two"), draft("elsewhere", other), StoreOp.Delete(RecordKey.journal(scope, entry))))
        val after = log.readBytes()
        assertTrue(after.size > before.size)
        for (cut in before.size..after.size) {
            log.writeBytes(after.copyOf(cut))
            val store = open()
            if (cut == after.size) {
                assertEquals("two", draftText(store))
                assertEquals("elsewhere", draftText(store, other))
                assertNull(store.read(RecordKey.journal(scope, entry)))
            } else {
                assertEquals("cut at $cut", "one", draftText(store))
                assertNull("cut at $cut", store.read(RecordKey.draft(other)))
                assertNotNull("cut at $cut", store.read(RecordKey.journal(scope, entry)))
                // The torn tail is gone, so the next commit appends to a clean log and survives another restart.
                store.commit(listOf(draft("later")))
                assertEquals("later", draftText(open()))
            }
        }
    }

    @Test fun aZeroFilledTailLeftByACrashIsATornWriteNotCorruption() = runBlocking {
        val store = open()
        store.commit(listOf(draft("kept")))
        log.appendBytes(ByteArray(300))
        assertEquals("kept", draftText(open()))
    }

    @Test fun aFailedCommitLeavesNothingAndTheNextCommitWorksAfterEveryKindOfFault() = runBlocking {
        val files = FaultyFiles()
        val store = open(files)
        store.commit(listOf(draft("base")))
        val size = log.length()

        files.appendFailsAfterBytes = 0
        assertThrows(ChatStoreException::class.java) { runBlocking { store.commit(listOf(draft("a"))) } }
        files.appendFailsAfterBytes = 25
        assertThrows(ChatStoreException::class.java) { runBlocking { store.commit(listOf(draft("b"))) } }
        files.appendFailsAfterBytes = null
        files.syncFails = true
        assertThrows(ChatStoreException::class.java) { runBlocking { store.commit(listOf(draft("c"))) } }
        files.syncFails = false

        assertEquals("base", draftText(store))
        assertEquals("A refused write leaves no bytes behind", size, log.length())
        store.commit(listOf(draft("d")))
        assertEquals("d", draftText(store))
        assertEquals("d", draftText(open()))
    }

    @Test fun ifTheFailedWriteCannotBeRemovedNothingElseIsAppendedUntilItIs() = runBlocking {
        val files = FaultyFiles()
        val store = open(files)
        store.commit(listOf(draft("base")))
        files.appendFailsAfterBytes = 30
        files.truncateFails = true
        assertThrows(ChatStoreException::class.java) { runBlocking { store.commit(listOf(draft("x"))) } }
        // The garbage tail is still there; appending after it would hide every later commit from a restart.
        assertThrows(ChatStoreException::class.java) { runBlocking { store.commit(listOf(draft("y"))) } }
        assertEquals("base", draftText(open()))
        files.appendFailsAfterBytes = null
        files.truncateFails = false
        store.commit(listOf(draft("z")))
        assertEquals("z", draftText(open()))
    }

    @Test fun aFullDiskIsReportedAsQuota() = runBlocking {
        val files = FaultyFiles().apply { appendFailsAfterBytes = 0; failureMessage = "No space left on device" }
        val failure = runCatching { open(files).commit(listOf(draft("x"))) }.exceptionOrNull() as ChatStoreException
        assertEquals(ChatStoreException.Kind.QuotaExceeded, failure.kind)
    }

    @Test fun concurrentCommitsAreAllAppliedAndNoneTornOrInterleaved() = runBlocking {
        val store = open()
        val scopes = (1..40).map { ConversationScope(host, "research", "anchor-$it") }
        scopes.map { each -> async(Dispatchers.IO) { store.commit(listOf(draft("text ${each.anchor}", each))) } }.awaitAll()
        val reopened = open()
        for (each in scopes) assertEquals("text ${each.anchor}", draftText(reopened, each))
    }

    // ---- damage is reported, never silently dropped

    @Test fun damageInTheMiddleOfTheLogFailsClosedUntilAnExplicitReset() = runBlocking {
        val store = open()
        store.commit(listOf(draft("first")))
        val firstEnd = log.length()
        store.commit(listOf(draft("second")))
        val bytes = log.readBytes()
        bytes[(firstEnd - 20).toInt()] = (bytes[(firstEnd - 20).toInt()] + 1).toByte()
        log.writeBytes(bytes)

        val damaged = open()
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { damaged.read(RecordKey.draft(scope)) }.exceptionOrNull() as ChatStoreException).kind)
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { damaged.commit(listOf(draft("x"))) }.exceptionOrNull() as ChatStoreException).kind)
        // The caches do not depend on the log, and a cache never throws.
        damaged.putCache(RecordKey.catalog(host), ByteArray(10))
        assertEquals(10, damaged.read(RecordKey.catalog(host))!!.size)

        assertTrue(damaged.discardUnreadable())
        assertNull(damaged.read(RecordKey.draft(scope)))
        damaged.commit(listOf(draft("fresh")))
        assertEquals("fresh", draftText(open()))
    }

    @Test fun aRecordThatChangesOnDiskAfterItWasIndexedIsCorruptNotReturned() = runBlocking {
        val store = open()
        store.commit(listOf(draft("a reasonably long draft that is easy to find in the file")))
        val bytes = log.readBytes()
        val at = String(bytes, Charsets.ISO_8859_1).indexOf("easy to find")
        bytes[at] = (bytes[at] + 1).toByte()
        log.writeBytes(bytes)
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { store.read(RecordKey.draft(scope)) }.exceptionOrNull() as ChatStoreException).kind)
    }

    @Test fun aFileThatIsNotOurLogIsNeverOverwritten() = runBlocking {
        directory.mkdirs()
        log.writeBytes("not a bighelp log, keep out of it".toByteArray())
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { open().read(RecordKey.draft(scope)) }.exceptionOrNull() as ChatStoreException).kind)
        assertEquals("not a bighelp log, keep out of it", log.readText())
    }

    // ---- compaction

    @Test fun repeatedDraftEditsCompactTheLogWithoutChangingWhatIsStored() = runBlocking {
        val tuning = ChatStoreTuning(compactionMinimumGarbage = 20_000)
        val store = open(tuning = tuning)
        val entry = UUID.randomUUID().toString()
        store.commit(listOf(journal(entry, "an uncertain send that must outlive every compaction")))
        repeat(200) { store.commit(listOf(draft("edit $it " + "x".repeat(400)))) }
        assertTrue("The log stayed bounded: ${log.length()}", log.length() < 60_000)
        assertEquals("edit 199 " + "x".repeat(400), draftText(store))
        val reopened = open(tuning = tuning)
        assertEquals("edit 199 " + "x".repeat(400), draftText(reopened))
        assertEquals("an uncertain send that must outlive every compaction",
            JournalEntry.decode(scope, entry, reopened.read(RecordKey.journal(scope, entry))!!).composerText)
        reopened.commit(listOf(draft("after compaction")))
        assertEquals("after compaction", draftText(open(tuning = tuning)))
    }

    @Test fun aFailedCompactionKeepsTheOldLogAndLaterCommitsStillWork() = runBlocking {
        val files = FaultyFiles().apply { replaceFails = true }
        val tuning = ChatStoreTuning(compactionMinimumGarbage = 5_000)
        val store = open(files, tuning)
        repeat(60) { store.commit(listOf(draft("edit $it " + "y".repeat(300)))) }
        assertEquals("edit 59 " + "y".repeat(300), draftText(open(tuning = tuning)))
        assertFalse("A failed compaction leaves no temporary file", File(directory, AndroidChatStore.COMPACT_NAME).exists())
        files.replaceFails = false
        repeat(30) { store.commit(listOf(draft("again $it " + "y".repeat(300)))) }
        assertEquals("again 29 " + "y".repeat(300), draftText(open(tuning = tuning)))
    }

    @Test fun aHalfWrittenCompactionLeftByADeadProcessIsIgnored() = runBlocking {
        val store = open()
        store.commit(listOf(draft("live")))
        File(directory, AndroidChatStore.COMPACT_NAME).writeBytes(ByteArray(100) { 9 })
        assertEquals("live", draftText(open()))
        assertFalse(File(directory, AndroidChatStore.COMPACT_NAME).exists())
    }

    // ---- caches

    @Test fun cachesNeverTouchDurableRecordsAndTheOldestAreEvictedFirst() = runBlocking {
        val store = open(tuning = ChatStoreTuning(cacheBudgetBytes = 10_000))
        val entry = UUID.randomUUID().toString()
        store.commit(listOf(draft("unsent words"), journal(entry)))
        val scopes = (1..5).map { ConversationScope(host, "research", "cached-$it") }
        for ((index, each) in scopes.withIndex()) {
            store.putCache(RecordKey.history(each), ByteArray(3_000) { index.toByte() })
            File(directory, "cache").listFiles()!!.maxByOrNull { it.lastModified() }!!.setLastModified(1_000_000L + index * 1_000)
        }
        val surviving = scopes.filter { store.read(RecordKey.history(it)) != null }
        assertTrue("The newest are kept: $surviving", surviving.contains(scopes.last()))
        assertFalse("The oldest are evicted first", surviving.contains(scopes.first()))
        assertEquals("unsent words", draftText(store))
        assertNotNull(store.read(RecordKey.journal(scope, entry)))
    }

    @Test fun aCacheWriteOverItsLimitIsDroppedQuietlyAndTheExactLimitIsKept() = runBlocking {
        val store = open()
        store.putCache(RecordKey.history(scope), ByteArray(RecordKind.HistoryCache.maximumBytes + 1))
        assertNull(store.read(RecordKey.history(scope)))
        val exact = ByteArray(RecordKind.CatalogCache.maximumBytes) { (it % 251).toByte() }
        store.putCache(RecordKey.catalog(host), exact)
        assertArrayEquals(exact, open().read(RecordKey.catalog(host)))
    }

    @Test fun aDamagedCacheFileIsDroppedNotReportedAsCorruptDraftsAreDifferent() = runBlocking {
        val store = open()
        store.putCache(RecordKey.history(scope), ByteArray(500) { 3 })
        val file = File(directory, "cache").listFiles()!!.single()
        val bytes = file.readBytes()
        bytes[bytes.size - 5] = (bytes[bytes.size - 5] + 1).toByte()
        file.writeBytes(bytes)
        assertNull(store.read(RecordKey.history(scope)))
        assertFalse("The damaged cache file is removed", file.exists())
    }

    @Test fun aCacheNeverThrowsEvenWhenItsFolderCannotBeMade() = runBlocking {
        directory.mkdirs()
        File(directory, "cache").writeText("a file where the folder should be")
        val store = open()
        store.putCache(RecordKey.history(scope), ByteArray(10))
        store.deleteCache(RecordKey.history(scope))
        assertNull(store.read(RecordKey.history(scope)))
    }

    @Test fun cacheKeysSurviveARestartForTheirComputer() = runBlocking {
        val store = open()
        store.putCache(RecordKey.history(scope), ByteArray(10))
        store.putCache(RecordKey.catalog(host), ByteArray(10))
        val reopened = open()
        assertEquals(listOf("anchor-1"), reopened.keys(host, RecordKind.HistoryCache).map { it.anchor })
        assertEquals(1, reopened.keys(host, RecordKind.CatalogCache).size)
    }

    // ---- removing a computer

    @Test fun removingAComputerDeletesItsDurableAndCachedRecordsAndNobodyElses() = runBlocking {
        val store = open()
        val gone = host
        val kept = HostScope(UUID.randomUUID().toString(), "https://example.test", "dashboard-session")
        val keptScope = ConversationScope(kept, "research", "anchor-1")
        val entry = UUID.randomUUID().toString()
        store.commit(listOf(draft("mine"), journal(entry), draft("theirs", keptScope)))
        store.putCache(RecordKey.history(scope), ByteArray(10))
        store.putCache(RecordKey.history(keptScope), ByteArray(10))
        store.putCache(RecordKey.catalog(gone), ByteArray(10))

        store.purge(gone.computerId)

        val reopened = open()
        assertNull(draftText(reopened))
        assertNull(reopened.read(RecordKey.journal(scope, entry)))
        assertNull(reopened.read(RecordKey.history(scope)))
        assertNull(reopened.read(RecordKey.catalog(gone)))
        assertEquals("theirs", draftText(reopened, keptScope))
        assertNotNull(reopened.read(RecordKey.history(keptScope)))
    }
}

/** Real files with scripted failures: a short write, a failed flush, a failed truncate or a failed rename. */
internal class FaultyFiles : ChatStoreFiles {
    var appendFailsAfterBytes: Int? = null
    var syncFails = false
    var truncateFails = false
    var replaceFails = false
    var failureMessage = "synthetic disk failure"

    override fun open(file: File): ChatLogFile {
        val inner = SystemChatStoreFiles.open(file)
        return object : ChatLogFile by inner {
            override fun append(bytes: ByteArray) {
                val limit = appendFailsAfterBytes ?: return inner.append(bytes)
                if (limit > 0) inner.append(bytes.copyOf(minOf(limit, bytes.size)))
                throw IOException(failureMessage)
            }
            override fun sync() { if (syncFails) throw IOException(failureMessage) else inner.sync() }
            override fun truncate(size: Long) { if (truncateFails) throw IOException(failureMessage) else inner.truncate(size) }
        }
    }

    override fun replace(from: File, to: File) { if (replaceFails) throw IOException(failureMessage) else SystemChatStoreFiles.replace(from, to) }
    override fun syncDirectory(directory: File) = SystemChatStoreFiles.syncDirectory(directory)
}
