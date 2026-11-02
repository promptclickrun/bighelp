package app.bighelp.hermes.chat

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatStoreTest {
    private val directory = Files.createTempDirectory("chat-store").toFile()
    private val file = File(directory, "snapshot.bin")
    private val host = ChatTestData.host
    private val scope = ConversationScope(host, "research", "anchor-1")

    @After fun clean() { directory.deleteRecursively() }

    private fun draft(text: String, at: ConversationScope = scope) =
        StoreOp.Put(RecordKey.draft(at), DraftRecord(at, text, updatedAtMillis = 5).encode())

    @Test fun aCommitIsAllOrNothingAndSurvivesARestart() = runBlocking {
        val store = FileSnapshotChatStore(file)
        val entryId = UUID.randomUUID().toString()
        val entry = JournalEntry(entryId, scope, "prompt.submit", "hi", "hi", emptyList(), 7)
        store.commit(listOf(draft("typing"), StoreOp.Put(RecordKey.journal(scope, entryId), entry.encode())))

        // A failed transaction applies none of its operations, also not the ones before the failing one.
        store.failNextCommit = ChatStoreException(ChatStoreException.Kind.QuotaExceeded)
        val failure = runCatching { store.commit(listOf(draft("changed"), StoreOp.Delete(RecordKey.journal(scope, entryId)))) }.exceptionOrNull()
        assertEquals(ChatStoreException.Kind.QuotaExceeded, (failure as ChatStoreException).kind)
        assertEquals("typing", DraftRecord.decode(scope, store.read(RecordKey.draft(scope))!!).text)
        assertNotNull(store.read(RecordKey.journal(scope, entryId)))

        // The process "restarts": a new store over the same file sees exactly the committed state.
        val reopened = FileSnapshotChatStore(file)
        assertEquals("typing", DraftRecord.decode(scope, reopened.read(RecordKey.draft(scope))!!).text)
        val journal = reopened.keys(host, RecordKind.Journal, "research", "anchor-1")
        assertEquals(listOf(entryId), journal.map { it.entry })
        assertEquals("hi", JournalEntry.decode(scope, entryId, reopened.read(journal.single())!!).composerText)
    }

    @Test fun anOversizeRecordIsRefusedBeforeAnythingIsApplied() = runBlocking {
        val store = MemoryChatStore()
        store.commit(listOf(draft("keep")))
        val tooBig = StoreOp.Put(RecordKey.draft(scope), ByteArray(RecordKind.Draft.maximumBytes + 1))
        val other = ConversationScope(host, "research", "anchor-2")
        val failure = runCatching { store.commit(listOf(draft("second", other), tooBig)) }.exceptionOrNull() as ChatStoreException
        assertEquals(ChatStoreException.Kind.TooLarge, failure.kind)
        assertNull("The earlier operation of the failed transaction is not applied", store.read(RecordKey.draft(other)))
        assertEquals("keep", DraftRecord.decode(scope, store.read(RecordKey.draft(scope))!!).text)
    }

    @Test fun aCacheKindIsNotADurableCommitAndADurableKindIsNotACacheWrite() = runBlocking {
        val store = MemoryChatStore()
        assertThrows(IllegalArgumentException::class.java) { runBlocking { store.commit(listOf(StoreOp.Put(RecordKey.catalog(host), ByteArray(1)))) } }
        assertThrows(IllegalArgumentException::class.java) { runBlocking { store.putCache(RecordKey.draft(scope), ByteArray(1)) } }
        Unit
    }

    @Test fun evictingTheCacheNeverTouchesUnsentOrUncertainWork() = runBlocking {
        val store = FileSnapshotChatStore(file)
        val entryId = UUID.randomUUID().toString()
        store.commit(listOf(draft("unsent words"), StoreOp.Put(RecordKey.journal(scope, entryId),
            JournalEntry(entryId, scope, "prompt.submit", "x", "x", emptyList(), 1).encode())))
        store.putCache(RecordKey.history(scope), ByteArray(4_000))
        store.putCache(RecordKey.catalog(host), ByteArray(4_000))
        assertNotNull(store.read(RecordKey.history(scope)))

        store.evictCaches()

        assertNull(store.read(RecordKey.history(scope)))
        assertNull(store.read(RecordKey.catalog(host)))
        assertEquals("unsent words", DraftRecord.decode(scope, store.read(RecordKey.draft(scope))!!).text)
        assertNotNull(store.read(RecordKey.journal(scope, entryId)))
    }

    @Test fun anOversizeCacheWriteIsDroppedQuietlyWhileTheCommitPathStaysStrict() = runBlocking {
        val store = MemoryChatStore()
        store.putCache(RecordKey.history(scope), ByteArray(RecordKind.HistoryCache.maximumBytes + 1))
        assertNull(store.read(RecordKey.history(scope)))
    }

    @Test fun everyRecordIsScopedByComputerEndpointPrincipalProfileAndAnchor() = runBlocking {
        val store = MemoryChatStore()
        val variants = listOf(
            scope,
            ConversationScope(host.copy(computerId = UUID.randomUUID().toString()), "research", "anchor-1"),
            ConversationScope(host.copy(endpoint = "https://other.example"), "research", "anchor-1"),
            ConversationScope(host.copy(principal = "basic:someone-else"), "research", "anchor-1"),
            ConversationScope(host, "other-profile", "anchor-1"),
            ConversationScope(host, "research", "anchor-2"),
        )
        variants.forEachIndexed { index, each -> store.commit(listOf(draft("text $index", each))) }
        variants.forEachIndexed { index, each ->
            assertEquals("text $index", DraftRecord.decode(each, store.read(RecordKey.draft(each))!!).text)
        }
        assertEquals("Only the exact scope is listed", 1, store.keys(host, RecordKind.Draft, "research", "anchor-1").size)
    }

    @Test fun aRecordReadUnderAnotherScopeIsCorruptNotSilentlyForeign() {
        val bytes = DraftRecord(scope, "mine", updatedAtMillis = 1).encode()
        val foreign = ConversationScope(host, "research", "anchor-2")
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { DraftRecord.decode(foreign, bytes) }.exceptionOrNull() as ChatStoreException).kind)
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { DraftRecord.decode(scope, "not json".toByteArray()) }.exceptionOrNull() as ChatStoreException).kind)
    }

    @Test fun theDraftRecordHoldsAFullMebibyteOfComposerTextWhichTheCredentialCapCouldNot() {
        val text = "é".repeat(524_288) // 1 MiB of UTF-8
        val bytes = DraftRecord(scope, text, updatedAtMillis = 1).encode()
        assertTrue("A record above 64 KiB is allowed", bytes.size > 65_536)
        assertEquals(text, DraftRecord.decode(scope, bytes).text)
        assertTrue(bytes.size <= ChatStoreLimits.MAXIMUM_DRAFT_RECORD_BYTES)
    }

    @Test fun textThatCannotFitTheRecordAfterEscapingIsRefusedNotTruncated() {
        // 1 MiB of control characters escapes to 6 bytes each, far beyond a frame and a record.
        val text = "\u0001".repeat(ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES)
        val failure = runCatching { DraftRecord(scope, text, updatedAtMillis = 1).encode() }.exceptionOrNull() as ChatStoreException
        assertEquals(ChatStoreException.Kind.TooLarge, failure.kind)
    }

    @Test fun aJournalEntryKeepsTheExactBytesTheComposerTextAndTheirReferences() {
        val id = UUID.randomUUID().toString()
        val entry = JournalEntry(id, scope, "command.dispatch", "expanded text   with  spaces", "/plan  now", listOf("file://a", "file://b"), 99)
        val back = JournalEntry.decode(scope, id, entry.encode())
        assertEquals("command.dispatch", back.method)
        assertEquals("expanded text   with  spaces", back.text)
        assertEquals("/plan  now", back.composerText)
        assertEquals(listOf("file://a", "file://b"), back.attachments)
        assertFalse(back.isRefused)
        assertEquals(true, back.refused(4001).isRefused)
        assertEquals(4001, JournalEntry.decode(scope, id, back.refused(4001).encode()).rejectionCode)
    }

    @Test fun aCreationRecordKeepsTheWholeLogicalCreateAndRejectsIncoherentPhases() {
        val intent = UUID.randomUUID().toString()
        val request = CreateRequest(cwd = "/home/example/project", title = "Plan", model = "m", provider = "p", reasoningEffort = "high", fast = false)
        val record = CreationRecord(host, intent, "research", CreationPurpose.Ordinary, CreationPhase.CreateRequested, request, createdAtMillis = 5)
        val back = CreationRecord.decode(host, "research", record.encode())
        assertEquals(record, back)
        // A created record must carry both coordinates.
        val incoherent = record.copy(phase = CreationPhase.Created)
        assertFalse(incoherent.isCoherent)
        assertEquals(ChatStoreException.Kind.Corrupt, (runCatching { CreationRecord.decode(host, "research", incoherent.encode()) }.exceptionOrNull() as ChatStoreException).kind)
        assertArrayEquals(record.encode(), back.encode())
    }

    @Test fun anIdentityRecordKeepsTheTipAndTheRoutingAliasesAcrossARestart() {
        val identity = ConversationIdentity(scope.ref, "tip-1").withTip("tip-2").withTip("tip-3")
        val back = IdentityRecord.decode(scope, IdentityRecord(scope, identity).encode())
        assertEquals("tip-3", back.storedTip)
        assertEquals(listOf("tip-1", "tip-2"), back.formerStoredIds)
        assertTrue(back.knows("tip-1") && back.knows("tip-3") && back.knows("anchor-1"))
        assertFalse(back.knows("unrelated"))
    }

    @Test fun theConversationRefRoundTripsAndRefusesAnythingItDidNotProduce() {
        val ref = ConversationRef("research", "a/b:c.d-é")
        assertEquals(ref, ConversationRef.parse(ref.id))
        assertNull(ConversationRef.parse("c1.cmVzZWFyY2g.")) // empty anchor
        assertNull(ConversationRef.parse("c1.cmVzZWFyY2g=.YQ")) // padded, not canonical
        assertNull(ConversationRef.parse("c2.cmVzZWFyY2g.YQ"))
        assertThrows(IllegalArgumentException::class.java) { ConversationRef("", "x") }
        assertThrows(IllegalArgumentException::class.java) { ConversationRef("p", " padded ") }
    }
}

/** Shared fixtures for the chat tests. All values are synthetic. */
object ChatTestData {
    val host = HostScope("5c3f4f06-2a41-4f6a-9d38-0a54d3a3a111", "http://127.0.0.1:9", "dashboard-session")
}
