package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.android.storage.RecordFileOperations
import app.bighelp.android.storage.SystemRecordFileOperations
import app.bighelp.hermes.HermesEndpoint
import java.util.UUID
import javax.crypto.KeyGenerator
import java.io.File
import java.io.InputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SavedComputerStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun records() = ProtectedRecordStore(temporary.root, RecordCipher { key })
    private fun store() = SavedComputerStore(records())
    private fun computer(name: String = "Garden computer") = SavedComputer(
        UUID.randomUUID(), name, HermesEndpoint.parse("https://example.test/hermes"), "dashboard-session", false,
    )

    @Test fun namesSelectionAndSetupStateSurviveReopening() = runBlocking {
        val first = computer()
        val second = computer("Research computer").copy(setupComplete = true)
        val initial = store().load()
        assertTrue(initial.computers.isEmpty())
        assertNull(initial.selectedID)
        val saved = store().replace(initial, listOf(first, second), second.id)
        assertEquals(saved, store().load())
        assertFalse(saved.computers.first().setupComplete)
        assertTrue(saved.computers.last().setupComplete)
    }

    @Test fun aStaleWindowCannotOverwriteAChangedComputerList() = runBlocking {
        val initial = store().load()
        val first = computer()
        val saved = store().replace(initial, listOf(first), first.id)
        try {
            store().replace(initial, emptyList(), null)
            fail("A stale computer list must not overwrite a new one")
        } catch (failure: SavedComputersException) {
            assertEquals(SavedComputersProblem.Changed, failure.problem)
        }
        assertEquals(saved, store().load())
    }

    @Test fun renamingAndRemovingSelectionPreserveOtherComputers() = runBlocking {
        val first = computer()
        val second = computer("Moss").copy(setupComplete = true)
        val original = store().replace(store().load(), listOf(first, second), first.id)
        val renamed = store().replace(original, listOf(first.copy(name = "Garden 🌿"), second), first.id)
        assertEquals("Garden 🌿", store().load().computers.first().name)
        assertNotEquals(original.revision, renamed.revision)
        val removed = store().replace(renamed, listOf(second), null)
        assertEquals(listOf(second), removed.computers)
        assertNull(store().load().selectedID)
    }

    @Test fun invalidSelectionAndDuplicateIdentifiersAreRefusedWithoutWriting() = runBlocking {
        val empty = store().load()
        val first = computer()
        for ((items, selected) in listOf(listOf(first) to UUID.randomUUID(), listOf(first, first) to first.id)) {
            try {
                store().replace(empty, items, selected)
                fail("Invalid computer list must be refused")
            } catch (failure: SavedComputersException) {
                assertEquals(SavedComputersProblem.InvalidChange, failure.problem)
            }
        }
        assertEquals(empty, store().load())
    }

    @Test fun theConfiguredHostCeilingMatchesTheNativeApp() = runBlocking {
        val items = List(32) { computer("Computer $it") }
        val saved = store().replace(store().load(), items, items.first().id)
        try {
            store().replace(saved, items + computer("Another computer"), null)
            fail("The 33rd configured computer must be refused")
        } catch (failure: SavedComputersException) {
            assertEquals(SavedComputersProblem.InvalidChange, failure.problem)
        }
        assertEquals(saved, store().load())
    }

    @Test fun unreadableDataDoesNotSilentlyEraseTheSavedComputerList() = runBlocking {
        val item = computer()
        store().replace(store().load(), listOf(item), item.id)
        temporary.root.listFiles()!!.single { it.extension == "sealed" }.writeBytes(byteArrayOf(1))
        try {
            store().load()
            fail("Unreadable storage must not be presented as an empty list")
        } catch (failure: RecordStorageException) {
            assertEquals(StorageProblem.CorruptRecord, failure.problem)
        }
    }

    @Test fun unknownSchemaIsRefusedWithoutReplacingOrDroppingIt() = runBlocking {
        val bytes = """{"schemaVersion":999,"computers":[]}""".toByteArray()
        assertTrue(records().compareAndSet(SAVED_COMPUTERS_RECORD_KEY, null, bytes))
        try {
            store().load()
            fail("A future schema must not be silently reset")
        } catch (failure: SavedComputersException) {
            assertEquals(SavedComputersProblem.Unreadable, failure.problem)
        }
        assertArrayEquals(bytes, records().read(SAVED_COMPUTERS_RECORD_KEY))
    }

    @Test fun onlyExplicitRecoveryCanDiscardAnUnreadableList() = runBlocking {
        val item = computer()
        val saved = store().replace(store().load(), listOf(item), item.id)
        assertFalse(store().discardUnreadable())
        assertEquals(saved, store().load())
        temporary.root.listFiles()!!.single { it.extension == "sealed" }.writeBytes(byteArrayOf(1))
        assertTrue(store().discardUnreadable())
        assertTrue(store().load().computers.isEmpty())
    }

    @Test fun cancellationDuringTheReadPreventsAComputerListWrite() = runBlocking {
        val empty = store().load()
        supervisorScope {
            lateinit var job: Deferred<SavedComputerSnapshot>
            var reads = 0
            val io = object : RecordFileOperations by SystemRecordFileOperations {
                override fun read(file: File): InputStream {
                    reads++
                    job.cancel()
                    return SystemRecordFileOperations.read(file)
                }
            }
            val vault = SavedComputerStore(ProtectedRecordStore(temporary.root, RecordCipher { key }, io))
            val first = computer()
            job = async(start = CoroutineStart.LAZY) { vault.replace(empty, listOf(first), first.id) }
            job.start()
            try { job.await(); fail("Cancelled work must not write") } catch (_: CancellationException) { }
            assertEquals(1, reads)
        }
        assertEquals(empty, store().load())
    }

    @Test fun aNewComputerCannotOverwriteAnUnreadableOrFutureSchemaIndex() = runBlocking {
        val empty = store().load()
        val item = computer()
        val records = records()
        val future = """{"schemaVersion":999}""".toByteArray()
        assertTrue(records.compareAndSet(SAVED_COMPUTERS_RECORD_KEY, null, future))
        try { store().replace(empty, listOf(item), item.id); fail("Future data must not be replaced") }
        catch (failure: SavedComputersException) { assertEquals(SavedComputersProblem.Unreadable, failure.problem) }
        assertArrayEquals(future, records.read(SAVED_COMPUTERS_RECORD_KEY))
        val file = temporary.root.listFiles()!!.single { it.extension == "sealed" }
        val corrupt = byteArrayOf(1, 2, 3)
        file.writeBytes(corrupt)
        try { store().replace(empty, listOf(item), item.id); fail("Corrupt data must not be replaced") }
        catch (failure: RecordStorageException) { assertEquals(StorageProblem.CorruptRecord, failure.problem) }
        assertArrayEquals(corrupt, file.readBytes())
    }

    @Test fun recoveryCannotDeleteAConcurrentValidIndexReplacement() = runBlocking {
        val item = computer()
        val replacementRoot = temporary.newFolder("replacement")
        val replacement = SavedComputerStore(ProtectedRecordStore(replacementRoot, RecordCipher { key }))
        val valid = replacement.replace(replacement.load(), listOf(item), item.id)
        val envelope = replacementRoot.listFiles()!!.single { it.extension == "sealed" }.readBytes()
        assertTrue(records().compareAndSet(SAVED_COMPUTERS_RECORD_KEY, null, """{"schemaVersion":999}""".toByteArray()))
        var reads = 0
        val io = object : RecordFileOperations by SystemRecordFileOperations {
            override fun read(file: File): InputStream {
                if (++reads == 3) file.writeBytes(envelope)
                return SystemRecordFileOperations.read(file)
            }
        }
        val racing = SavedComputerStore(ProtectedRecordStore(temporary.root, RecordCipher { key }, io))
        assertFalse(racing.discardUnreadable())
        assertEquals(valid, store().load())
    }
}
