package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.hermes.AccessCredential
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.CustomHeader
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.StoredAuth
import java.io.File
import java.util.UUID
import javax.crypto.KeyGenerator
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
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
    private val localData = FakeLocalData()
    private val factoryCalls = mutableListOf<Triple<UUID, HermesEndpoint, AccessSetup>>()
    private fun model(scope: CoroutineScope) = ComputerConnectionModel(
        registry(), ::vault, { consent }, scope, localData,
    ) { id, address, access, credentials, ownedScope ->
        factoryCalls += Triple(id, address, access)
        FakeSession(address, credentials, localData, id, ownedScope).also { sessions += it; prepare(it) }
    }

    /** Stands in for the access-header store and the chat records, and remembers what happened to them. */
    private class FakeLocalData : ComputerLocalData {
        val access = mutableMapOf<UUID, AccessSetup>()
        val forgotten = mutableListOf<UUID>()
        override suspend fun loadAccess(id: UUID) = access[id] ?: AccessSetup.None
        override suspend fun saveAccess(id: UUID, access: AccessSetup) { this.access[id] = access }
        override suspend fun forget(id: UUID) { forgotten += id; access.remove(id) }
    }

    private class FakeSession(
        val endpoint: HermesEndpoint, val store: CredentialStore, val local: FakeLocalData, val id: UUID, val scope: CoroutineScope,
    ) : ComputerSession {
        override var saved: SavedConnection? = null
        override val link = kotlinx.coroutines.flow.MutableStateFlow(ComputerLink.Connected)
        var accessSavedBeforeCommit: Boolean? = null
        var resumed = 0
        var reconnects = 0
        override suspend fun resume() { resumed++ }
        override suspend fun reconnect() { reconnects++ }
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
            accessSavedBeforeCommit = local.access.containsKey(id)
            store.replace(expected, requireNotNull(saved))
            commits++
        }
        /** A refresh that finishes while the session shuts down: it tries to save its rotated sign-in, as the real one does. */
        var rotateOnClose = false
        var closeWrite: Boolean? = null
        var scopeActiveOnClose: Boolean? = null
        override suspend fun close() {
            scopeActiveOnClose = scope.isActive
            if (rotateOnClose) {
                val rotated = SavedConnection(endpoint, StoredAuth.DashboardSession("rotated-session", true), null, null)
                closeWrite = try { store.replace(requireNotNull(saved), rotated); true } catch (_: app.bighelp.hermes.StaleCredentialException) { false }
            }
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

    @Test fun theLinkFollowsTheActiveSessionsGatewayAfterSetupAndEndsWithIt() = runTest {
        val model = model(backgroundScope)
        runCurrent()
        assertNull(model.link.value)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        runCurrent()
        assertEquals(ComputerLink.Connected, model.link.value)
        val session = sessions.single()
        for (next in listOf(ComputerLink.Reconnecting, ComputerLink.Offline, ComputerLink.SignInRequired, ComputerLink.Connected)) {
            session.link.value = next
            runCurrent()
            assertEquals(next, model.link.value)
        }
        model.disconnect().join()
        runCurrent()
        assertNull("A closed computer has no link to report", model.link.value)
    }

    @Test fun aDuplicateOrAFullListIsRefusedBeforeTheNewSessionMayConnect() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        model.beginSetup(endpoint).join()
        model.signIn("Another name", SignInInput.Dashboard).join()
        assertEquals(ComputerProblem.AlreadyConfigured, model.state.value.problem)
        assertFalse("A refused duplicate never opened a socket with its credentials", sessions.last().connected)

        val registry = registry()
        val rows = (1..32).map { SavedComputer(UUID.randomUUID(), "Computer $it", HermesEndpoint.parse("https://c$it.example.test"), "dashboard-session", true) }
        registry.replace(registry.load(), rows, null)
        model.beginSetup(HermesEndpoint.parse("https://thirty-three.example.test")).join()
        model.signIn("One too many", SignInInput.Dashboard).join()
        assertEquals(ComputerProblem.ComputerLimit, model.state.value.problem)
        assertFalse(sessions.last().connected)
        model.disconnect().join()
    }

    @Test fun gateCredentialsAreSavedBeforeTheSignInCommitAndComeBackOnTheNextLaunch() = runTest {
        val gate = AccessSetup(AccessCredential.proxyBasic("gate-user", "gate-password"), CustomHeader.list(listOf("X-Access-Id" to "synthetic")))
        val model = model(backgroundScope)
        model.beginSetup(endpoint, gate).join()
        assertEquals(gate, factoryCalls.single().third)
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        assertEquals("The gate details were durable before the sign-in was", true, sessions.single().accessSavedBeforeCommit)
        assertEquals(gate, localData.access[row.id])
        model.disconnect().join()

        val restored = model(backgroundScope)
        restored.load().join()
        assertEquals("The saved gate details reach the new session", gate, factoryCalls.last().third)
        restored.disconnect().join()
    }

    @Test fun removingAComputerAlsoForgetsItsGateDetailsAndLocalChatRecords() = runTest {
        val model = model(backgroundScope)
        model.beginSetup(endpoint, AccessSetup(AccessCredential.proxyBasic("gate-user", "gate-password"), emptyList())).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        model.remove(row.id).join()
        assertEquals(listOf(row.id), localData.forgotten)
        assertTrue(localData.access.isEmpty())
        assertTrue(registry().load().computers.isEmpty())
    }

    @Test fun reauthenticatingReusesTheSavedGateDetails() = runTest {
        val gate = AccessSetup(AccessCredential.cloudflareAccess("id-0123", "secret-0123"), emptyList())
        val model = model(backgroundScope)
        model.beginSetup(HermesEndpoint.parse("https://gated.example.test"), gate).join()
        model.signIn("Gated computer", SignInInput.Dashboard).join()
        val row = registry().load().computers.single()
        model.reauthenticate(row.id).join()
        assertEquals(gate, factoryCalls.last().third)
        model.disconnect().join()
    }

    private suspend fun kotlinx.coroutines.test.TestScope.connectedComputer(): Pair<ComputerConnectionModel<FakeSession>, SavedComputer> {
        val model = model(backgroundScope)
        model.beginSetup(endpoint).join()
        model.signIn("Garden computer", SignInInput.Dashboard).join()
        sessions.single().rotateOnClose = true
        return model to registry().load().computers.single()
    }

    private suspend fun rotatedToken(row: SavedComputer) =
        (vault(row.id).load(row.authority)?.auth as? StoredAuth.DashboardSession)?.token

    @Test fun aRefreshFinishingWhileTheComputerIsReplacedStillSavesItsRotatedSignIn() = runTest {
        val (model, row) = connectedComputer()
        model.select(row.id).join()
        val old = sessions.first()
        assertEquals("The renewal could still save while the session shut down", true, old.closeWrite)
        assertEquals("The owner's scope outlived the gateway's disconnect", true, old.scopeActiveOnClose)
        assertEquals("rotated-session", rotatedToken(row))
        model.disconnect().join()
    }

    @Test fun aRefreshFinishingWhileTheComputerIsDisconnectedStillSavesItsRotatedSignIn() = runTest {
        val (model, row) = connectedComputer()
        model.disconnect().join()
        assertEquals(true, sessions.single().closeWrite)
        assertEquals(true, sessions.single().scopeActiveOnClose)
        assertEquals("rotated-session", rotatedToken(row))
    }

    @Test fun aRefreshFinishingWhileTheModelIsClosedStillSavesItsRotatedSignIn() = runTest {
        val (model, row) = connectedComputer()
        model.close().join()
        assertEquals(true, sessions.single().closeWrite)
        assertEquals(true, sessions.single().scopeActiveOnClose)
        assertEquals("rotated-session", rotatedToken(row))
    }

    @Test fun removalKeepsTheFastOrderSoALateRefreshCannotRecreateTheDeletedSignIn() = runTest {
        val (model, row) = connectedComputer()
        model.remove(row.id).join()
        assertEquals("A deleted computer's late refresh is refused", false, sessions.single().closeWrite)
        assertNull(rotatedToken(row))
        assertTrue(registry().load().computers.isEmpty())
    }

}
