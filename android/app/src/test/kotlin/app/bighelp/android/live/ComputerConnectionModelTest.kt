package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.StoredAuth
import java.io.File
import java.util.UUID
import javax.crypto.KeyGenerator
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ComputerConnectionModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private var indexFiles: app.bighelp.android.storage.RecordFileOperations = app.bighelp.android.storage.SystemRecordFileOperations
    private fun registry() = SavedComputerStore(ProtectedRecordStore(File(temporary.root, "index"), RecordCipher { key }, indexFiles), Dispatchers.Unconfined)
    private fun vault(id: UUID) = AndroidCredentialStore(ProtectedRecordStore(File(temporary.root, "sign-ins"), RecordCipher { key }), id.toString(), Dispatchers.Unconfined)
    private val endpoint = HermesEndpoint.parse("https://example.test/hermes")
    private var consent = true
    private val sessions = mutableListOf<FakeSession>()
    private var prepare: (FakeSession) -> Unit = { }
    private fun model(scope: CoroutineScope) = ComputerConnectionModel(
        registry(), ::vault, { consent }, scope,
    ) { address, credentials, _ -> FakeSession(address, credentials).also { sessions += it; prepare(it) } }

    private class FakeSession(val endpoint: HermesEndpoint, val store: CredentialStore) : ComputerSession {
        override var saved: SavedConnection? = null
        var closed = false
        var connected = false
        var commits = 0
        var failClose = false
        var connectGate: CompletableDeferred<Unit>? = null
        override suspend fun discover() = AuthStatus(false, emptyList(), emptyList())
        override suspend fun signIn(input: SignInInput): SavedConnection = SavedConnection(
            endpoint, StoredAuth.DashboardSession("synthetic-session", true), null, null,
        ).also { saved = it }
        override suspend fun restore(saved: SavedConnection) { this.saved = saved }
        override suspend fun connect() {
            connectGate?.let { withContext(NonCancellable) { it.await() } }
            connected = true
        }
        override suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean) {
            check(connected && stillCurrent())
            store.replace(expected, requireNotNull(saved))
            commits++
        }
        override suspend fun close() {
            closed = true
            if (failClose) throw java.io.IOException("Synthetic close failure")
        }
    }

    @Test fun consentPreventsDiscoveryAndSavedRestoreFromCreatingAnyNetworkClient() = runTest {
        consent = false
        val model = model(backgroundScope)
        model.load().join()
        model.beginSetup(endpoint).join()
        assertEquals(ComputerPhase.ConsentRequired, model.state.value.phase)
        assertTrue(sessions.isEmpty())
        assertTrue(registry().load().computers.isEmpty())
    }

    @Test fun aNewComputerIsCommittedOnlyAfterItsGatewayIsReadyAndRestoresOnTheNextLaunch() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        assertTrue(registry().load().computers.isEmpty())
        assertEquals(ComputerPhase.SignIn, model.state.value.phase)
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        assertEquals(ComputerPhase.Connected, model.state.value.phase)
        val saved = registry().load()
        val row = saved.computers.single()
        assertTrue(row.setupComplete)
        assertEquals(row.id, saved.selectedID)
        assertEquals(1, sessions.single().commits)
        assertEquals(row.authority, vault(row.id).load(row.authority)!!.authority)
        val restored = model(backgroundScope)
        restored.load().join()
        assertEquals(ComputerPhase.Connected, restored.state.value.phase)
        assertEquals(row.id, restored.active.value!!.computer.id)
        assertEquals(0, sessions.last().commits)
        model.disconnect().join()
        restored.disconnect().join()
    }

    @Test fun aCancelledConnectionThatIgnoresCancellationCannotCommitOrBecomeActive() = runTest {
        val gate = CompletableDeferred<Unit>()
        prepare = { it.connectGate = gate }
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        val signIn = model.signIn("Garden computer", SignInInput.Dashboard)
        runCurrent()
        assertEquals(ComputerPhase.Connecting, model.state.value.phase)
        val cancel = model.disconnect()
        runCurrent()
        assertFalse(cancel.isCompleted)
        gate.complete(Unit)
        signIn.join()
        cancel.join()
        assertEquals(0, sessions.single().commits)
        assertTrue(sessions.single().closed)
        assertNull(model.active.value)
        assertTrue(registry().load().computers.isEmpty())
    }

    @Test fun anIncompleteSavedRowRequiresSignInWithoutOpeningANetworkClient() = runTest {
        val row = SavedComputer(UUID.randomUUID(), "Garden computer", endpoint, "dashboard-session", false)
        val registry = registry()
        registry.replace(registry.load(), listOf(row), row.id)
        val model = model(backgroundScope)
        model.load().join()
        assertEquals(ComputerPhase.SignInRequired, model.state.value.phase)
        assertTrue(sessions.isEmpty())
    }

    @Test fun aMissingSignInDoesNotSilentlyBootstrapANewPrincipal() = runTest {
        val row = SavedComputer(UUID.randomUUID(), "Garden computer", endpoint, "dashboard-session", true)
        val registry = registry()
        registry.replace(registry.load(), listOf(row), row.id)
        val model = model(backgroundScope)
        model.load().join()
        assertEquals(ComputerPhase.SignInRequired, model.state.value.phase)
        assertTrue(sessions.isEmpty())
    }

    @Test fun anExistingEndpointAndPrincipalCannotBeAddedTwice() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        model.beginSetup(endpoint).join()
        model.signIn("Another name", SignInInput.Dashboard).join()
        assertEquals(ComputerProblem.AlreadyConfigured, model.state.value.problem)
        assertEquals(1, registry().load().computers.size)
        assertEquals(0, sessions.last().commits)
        assertTrue(sessions.first().closed)
        model.disconnect().join()
    }

    @Test fun removingTheActiveComputerRetiresItBeforeDeletingItsLocalSignIn() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        model.remove(row.id).join()
        assertTrue(sessions.single().closed)
        assertNull(vault(row.id).load(row.authority))
        assertTrue(registry().load().computers.isEmpty())
        assertNull(model.active.value)
    }

    @Test fun selectingAnotherComputerClosesTheOldOwnerAndKeepsBothSignIns() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val first = registry().load().computers.single()
        model.beginSetup(HermesEndpoint.parse("https://second.example.test/prefix")).join()
        model.signIn("Moss computer", SignInInput.Dashboard).join()
        val second = registry().load().computers.last()
        model.select(first.id).join()
        assertEquals(first.id, model.active.value!!.computer.id)
        assertTrue(sessions[1].closed)
        assertNotNull(vault(first.id).load(first.authority))
        assertNotNull(vault(second.id).load(second.authority))
        assertEquals(first.id, registry().load().selectedID)
        model.disconnect().join()
    }
    @Test fun anExpiredSavedSignInCanBeReplacedInTheSameComputerRow() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        model.reauthenticate(row.id).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        assertEquals(ComputerPhase.Connected, model.state.value.phase)
        assertEquals(listOf(row.id), registry().load().computers.map { it.id })
        assertEquals(1, sessions.last().commits)
        model.disconnect().join()
    }

    @Test fun retiringAStoreWaitsForItsStartedWriteAndRefusesAnyLaterSave() = runTest {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val underlying = app.bighelp.hermes.InMemoryCredentialStore()
        val address = endpoint
        val value = SavedConnection(address, StoredAuth.DashboardSession("synthetic-session", true), null, null)
        val delegate = object : CredentialStore by underlying {
            override suspend fun replace(expected: SavedConnection?, next: SavedConnection) {
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                underlying.replace(expected, next)
            }
        }
        val owned = OwnedCredentialStore(delegate) { true }
        val write = backgroundScope.launch { owned.replace(null, value) }
        entered.await()
        owned.invalidate()
        val drain = backgroundScope.launch { owned.awaitIdle() }
        try {
            runCurrent()
            assertFalse(drain.isCompleted)
        } finally { release.complete(Unit) }
        write.join()
        drain.join()
        underlying.delete(value)
        try { owned.replace(null, value); fail("A retired store must not recreate credentials") }
        catch (_: app.bighelp.hermes.StaleCredentialException) { }
        assertNull(underlying.load(value.authority))
    }

    @Test fun aLostIndexAcknowledgementAfterRenameIsReadBackWithoutRepeatingTheSignIn() = runTest {
        var moves = 0
        indexFiles = object : app.bighelp.android.storage.RecordFileOperations by app.bighelp.android.storage.SystemRecordFileOperations {
            override fun move(from: java.nio.file.Path, to: java.nio.file.Path) {
                app.bighelp.android.storage.SystemRecordFileOperations.move(from, to)
                if (++moves == 2) throw java.io.IOException("Synthetic acknowledgement loss")
            }
        }
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        assertEquals(ComputerPhase.Connected, model.state.value.phase)
        assertEquals(2, moves)
        assertEquals(1, sessions.single().commits)
        assertTrue(registry().load().computers.single().setupComplete)
        model.disconnect().join()
    }

    @Test fun lifecycleCloseFinishesCleanupEvenAfterTheViewModelScopeWasCancelled() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        sessions.single().failClose = true
        backgroundScope.cancel()
        val close = model.close()
        close.join()
        assertTrue(sessions.single().closed)
        assertNull(model.active.value)
        assertNotNull(vault(row.id).load(row.authority))
        assertSame(close, model.close())
    }

    @Test fun aThirdActionCannotBypassTheJoinOfAnEarlierCancelledSignIn() = runTest {
        val gate = CompletableDeferred<Unit>()
        prepare = { it.connectGate = gate }
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        val first = model.signIn("Garden computer", SignInInput.Dashboard)
        runCurrent()
        val second = model.disconnect()
        runCurrent()
        val third = model.beginSetup(HermesEndpoint.parse("https://second.example.test"))
        try {
            runCurrent()
            assertFalse(third.isCompleted)
            assertEquals(1, sessions.size)
        } finally { gate.complete(Unit) }
        first.join()
        second.join()
        third.join()
        assertEquals(2, sessions.size)
        assertTrue(sessions.first().closed)
        assertEquals(0, sessions.first().commits)
        model.close().join()
    }

}
