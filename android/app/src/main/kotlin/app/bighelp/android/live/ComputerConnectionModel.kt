package app.bighelp.android.live

import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.CredentialAuthority
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.StaleCredentialException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal enum class ComputerPhase { Idle, Loading, ConsentRequired, Discovering, SignIn, Connecting, Connected, SignInRequired, Failed }
internal enum class ComputerProblem { Connection, StorageUnavailable, UnreadableStorage, AlreadyConfigured, ComputerLimit, InvalidName }

internal data class ComputerConnectionState(
    val computers: List<SavedComputer> = emptyList(),
    val selectedID: UUID? = null,
    val phase: ComputerPhase = ComputerPhase.Idle,
    val authStatus: AuthStatus? = null,
    val problem: ComputerProblem? = null,
    val authFailure: HermesException.Kind? = null,
)

/** Network work is separate from the owner/index transaction, making retirement testable. */
internal interface ComputerSession {
    val saved: SavedConnection?

    /** The live connection as the gateway reports it: what a screen may truthfully say beyond the first connect. */
    val link: StateFlow<ComputerLink>
    suspend fun discover(): AuthStatus
    suspend fun signIn(input: SignInInput): SavedConnection
    suspend fun restore(saved: SavedConnection)
    suspend fun connect()
    suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean)

    /** The app is back in front: verify or reconnect, then read the lists again. Never throws for a host problem. */
    suspend fun resume()

    /** The person's own Reconnect. Throws the typed failure so the screen can say what happened. */
    suspend fun reconnect()
    suspend fun close()
}

internal class ConnectedComputer<T : ComputerSession>(val computer: SavedComputer, val session: T, val scope: CoroutineScope)

/** Retirement blocks new writes and waits for any disk operation already in progress. */
internal class OwnedCredentialStore(private val delegate: CredentialStore, private val ownerAlive: () -> Boolean) : CredentialStore {
    private val active = AtomicBoolean(true)
    private val lock = Mutex()
    private fun requireOwner() { if (!active.get() || !ownerAlive()) throw StaleCredentialException() }
    override suspend fun load(authority: CredentialAuthority): SavedConnection? = lock.withLock {
        requireOwner()
        delegate.load(authority).also { requireOwner() }
    }
    override suspend fun replace(expected: SavedConnection?, next: SavedConnection) = lock.withLock {
        requireOwner()
        delegate.replace(expected, next)
    }
    override suspend fun delete(expected: SavedConnection) = lock.withLock {
        requireOwner()
        delegate.delete(expected)
    }
    fun invalidate() { active.set(false) }
    suspend fun awaitIdle() { lock.withLock { } }
}

/**
 * Called on the UI thread. Every replacement first invalidates, cancels and joins the previous operation.
 * The session's child scope is also retired before local sign-out, so a late refresh cannot recreate it.
 * A pending setup row survives an uncertain disk acknowledgement for explicit recovery on next launch.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class ComputerConnectionModel<T : ComputerSession>(
    private val registry: SavedComputerStore,
    private val credentials: (UUID) -> AndroidCredentialStore,
    private val consentGranted: () -> Boolean,
    private val scope: CoroutineScope,
    private val localData: ComputerLocalData = ComputerLocalData.None,
    private val factory: (UUID, HermesEndpoint, AccessSetup, CredentialStore, CoroutineScope) -> T,
) {
    private val mutableState = MutableStateFlow(ComputerConnectionState())
    val state: StateFlow<ComputerConnectionState> = mutableState.asStateFlow()
    private val mutableActive = MutableStateFlow<ConnectedComputer<T>?>(null)
    val active: StateFlow<ConnectedComputer<T>?> = mutableActive.asStateFlow()

    /** The active computer's live link; null when none is active. It keeps following the gateway after setup. */
    val link: StateFlow<ComputerLink?> =
        mutableActive.flatMapLatest { it?.session?.link ?: flowOf(null) }.stateIn(scope, SharingStarted.Eagerly, null)
    private var generation = 0L
    private var operation: Job? = null
    private var owner: Owner<T>? = null
    private var cleanup: Job? = null

    /** ViewModel disposal can cancel its scope first; resource cleanup still has to finish. */
    fun close(): Job {
        cleanup?.let { return it }
        ++generation
        val previous = operation
        previous?.cancel()
        return CoroutineScope(scope.coroutineContext.minusKey(Job) + NonCancellable).launch {
            previous?.join()
            try { retire() } catch (_: Exception) { /* The owner is invalid even if socket cleanup fails. */ }
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.Idle)
        }.also { cleanup = it }
    }

    private class Owner<T : ComputerSession>(
        val id: UUID, val endpoint: HermesEndpoint, val access: AccessSetup, val session: T, val job: Job, val scope: CoroutineScope,
        val credentials: OwnedCredentialStore,
    )

    fun load(): Job = launchOperation { token ->
        retire()
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Loading, problem = null, authFailure = null)
        val saved = registry.load()
        requireCurrent(token)
        publishIndex(saved)
        if (!consentGranted()) {
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.ConsentRequired)
        } else {
            saved.selectedID?.let { restore(it, token) }
                ?: run { mutableState.value = mutableState.value.copy(phase = ComputerPhase.Idle) }
        }
    }

    /** [access] holds the proxy details the person entered for this address; they are saved with the sign-in. */
    fun beginSetup(endpoint: HermesEndpoint, access: AccessSetup = AccessSetup.None): Job = launchOperation { token ->
        retire()
        if (!hasConsent()) return@launchOperation
        val next = newOwner(UUID.randomUUID(), endpoint, access)
        owner = next
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Discovering, problem = null, authFailure = null, authStatus = null)
        val status = next.session.discover()
        requireOwner(next, token)
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, authStatus = status)
    }

    fun reauthenticate(id: UUID): Job = launchOperation { token ->
        retire()
        if (!hasConsent()) return@launchOperation
        val snapshot = registry.load()
        requireCurrent(token)
        publishIndex(snapshot)
        val row = snapshot.computers.firstOrNull { it.id == id } ?: return@launchOperation
        val access = localData.loadAccess(id)
        requireCurrent(token)
        val next = newOwner(id, row.endpoint, access)
        owner = next
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Discovering, problem = null, authFailure = null, authStatus = null)
        val status = next.session.discover()
        requireOwner(next, token)
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, authStatus = status)
    }

    fun signIn(name: String, input: SignInInput): Job = launchOperation { token ->
        if (!hasConsent()) return@launchOperation
        val current = owner ?: return@launchOperation
        val cleanName = name.trim()
        if (cleanName.isEmpty() || cleanName.codePointCount(0, cleanName.length) > 60 || cleanName.any { Character.isISOControl(it) }) {
            mutableState.value = mutableState.value.copy(problem = ComputerProblem.InvalidName)
            return@launchOperation
        }
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Connecting, problem = null, authFailure = null)
        val candidate = current.session.signIn(input)
        requireOwner(current, token)
        // A duplicate or a full list is decided before the session may connect, so a refused sign-in never
        // leaves a socket open under credentials that were not accepted.
        rejection(registry.load(), current.id, candidate)?.let { problem ->
            requireOwner(current, token)
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, problem = problem)
            return@launchOperation
        }
        requireOwner(current, token)
        current.session.connect()
        requireOwner(current, token)
        var snapshot = registry.load()
        requireOwner(current, token)
        val existing = snapshot.computers.firstOrNull { it.id == current.id }
        rejection(snapshot, current.id, candidate)?.let { problem ->
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, problem = problem)
            return@launchOperation
        }
        val expected = existing?.let { credentials(it.id).load(it.authority) }
        requireOwner(current, token)
        val pending = SavedComputer(current.id, cleanName, candidate.endpoint, candidate.principal, false)
        val rows = if (existing == null) snapshot.computers + pending
            else snapshot.computers.map { if (it.id == current.id) pending else it }
        snapshot = replaceIndex(snapshot, rows, current.id)
        requireOwner(current, token)
        // The gate details are durable before the sign-in is: a restore needs both to reach the computer.
        localData.saveAccess(current.id, current.access)
        requireOwner(current, token)
        // The row is recoverable even if cancellation or a lost disk acknowledgement interrupts promotion.
        current.session.commit(expected) { owner === current && generation == token && current.job.isActive }
        requireOwner(current, token)
        val complete = pending.copy(setupComplete = true)
        snapshot = replaceIndex(snapshot, snapshot.computers.map { if (it.id == current.id) complete else it }, current.id)
        requireOwner(current, token)
        publishIndex(snapshot)
        mutableActive.value = ConnectedComputer(complete, current.session, current.scope)
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Connected, authStatus = null)
    }

    fun select(id: UUID): Job = launchOperation { token ->
        retire()
        if (!hasConsent()) return@launchOperation
        restore(id, token)
    }

    fun disconnect(): Job = launchOperation {
        retire()
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Idle, authStatus = null, problem = null, authFailure = null)
    }

    fun remove(id: UUID): Job = launchOperation { token ->
        // Joining the old operation happened before this block, including any cancelled disk write.
        if (owner?.id == id || mutableActive.value == null) retire(forRemoval = owner?.id == id)
        var snapshot = registry.load()
        val row = snapshot.computers.firstOrNull { it.id == id } ?: return@launchOperation
        val vault = credentials(id)
        vault.load(row.authority)?.let { stored ->
            try { vault.delete(stored) }
            catch (failure: RecordStorageException) {
                if (failure.problem != StorageProblem.DiskUnavailable || vault.load(row.authority) != null) throw failure
            }
        }
        requireCurrent(token)
        localData.forget(id)
        requireCurrent(token)
        snapshot = replaceIndex(snapshot, snapshot.computers.filterNot { it.id == id }, snapshot.selectedID.takeUnless { it == id })
        requireCurrent(token)
        publishIndex(snapshot)
        if (mutableActive.value == null) mutableState.value = mutableState.value.copy(phase = ComputerPhase.Idle)
    }

    private suspend fun restore(id: UUID, token: Long) {
        val snapshot = registry.load()
        requireCurrent(token)
        publishIndex(snapshot)
        val row = snapshot.computers.firstOrNull { it.id == id } ?: return
        if (!row.setupComplete) {
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignInRequired, selectedID = id)
            return
        }
        val saved = credentials(id).load(row.authority)
        requireCurrent(token)
        if (saved == null) {
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignInRequired, selectedID = id)
            return
        }
        val access = localData.loadAccess(id)
        requireCurrent(token)
        val next = newOwner(id, row.endpoint, access)
        owner = next
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Connecting, problem = null, authFailure = null)
        next.session.restore(saved)
        next.session.connect()
        requireOwner(next, token)
        val selected = if (snapshot.selectedID == id) snapshot else replaceIndex(snapshot, snapshot.computers, id)
        requireOwner(next, token)
        publishIndex(selected)
        mutableActive.value = ConnectedComputer(row, next.session, next.scope)
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.Connected)
    }

    private fun newOwner(id: UUID, endpoint: HermesEndpoint, access: AccessSetup): Owner<T> {
        val job = SupervisorJob(scope.coroutineContext[Job])
        val ownedScope = CoroutineScope(scope.coroutineContext + job)
        val store = OwnedCredentialStore(credentials(id)) { job.isActive }
        return try { Owner(id, endpoint, access, factory(id, endpoint, access, store, ownedScope), job, ownedScope, store) }
        catch (failure: Exception) { store.invalidate(); job.cancel(); throw failure }
    }

    private fun launchOperation(block: suspend (Long) -> Unit): Job {
        cleanup?.let { return it }
        val token = ++generation
        val previous = operation
        previous?.cancel()
        val next = scope.launch(start = CoroutineStart.LAZY) {
            // A cancelled waiter must still outlast its predecessor, or a third action could bypass it.
            if (previous != null) withContext(NonCancellable) { previous.join() }
            ensureActive()
            if (generation != token) return@launch
            try { block(token) }
            catch (failure: CancellationException) { throw failure }
            catch (failure: Exception) {
                if (generation != token) return@launch
                val authFailure = (failure as? HermesException)?.kind
                val problem = when (failure) {
                    is RecordStorageException -> if (failure.problem in setOf(StorageProblem.CorruptRecord, StorageProblem.RecordTooLarge, StorageProblem.KeyMissing))
                        ComputerProblem.UnreadableStorage else ComputerProblem.StorageUnavailable
                    is SavedComputersException -> if (failure.problem == SavedComputersProblem.Unreadable)
                        ComputerProblem.UnreadableStorage else ComputerProblem.StorageUnavailable
                    is HermesException -> if (failure.kind == HermesException.Kind.SavedConnectionInvalid)
                        ComputerProblem.UnreadableStorage else ComputerProblem.Connection
                    else -> ComputerProblem.Connection
                }
                retire()
                mutableState.value = mutableState.value.copy(phase = ComputerPhase.Failed, problem = problem, authFailure = authFailure)
            }
        }
        operation = next
        next.start()
        return next
    }

    /** Why a sign-in may not become a saved computer, or null. An address+principal already saved, or 32 rows. */
    private fun rejection(snapshot: SavedComputerSnapshot, id: UUID, candidate: SavedConnection): ComputerProblem? {
        val existing = snapshot.computers.firstOrNull { it.id == id }
        if (existing != null && existing.authority != candidate.authority) throw HermesException(HermesException.Kind.IdentityChanged)
        if (snapshot.computers.any { it.id != id && it.authority == candidate.authority }) return ComputerProblem.AlreadyConfigured
        if (existing == null && snapshot.computers.size >= 32) return ComputerProblem.ComputerLimit
        return null
    }

    private fun hasConsent(): Boolean {
        if (consentGranted()) return true
        mutableState.value = mutableState.value.copy(phase = ComputerPhase.ConsentRequired)
        return false
    }

    private suspend fun requireCurrent(token: Long) {
        currentCoroutineContext().ensureActive()
        if (generation != token) throw CancellationException("Connection retired")
    }

    private suspend fun requireOwner(expected: Owner<T>, token: Long) {
        requireCurrent(token)
        if (owner !== expected || !expected.job.isActive) throw CancellationException("Connection retired")
    }

    /**
     * Ends the current owner. Two orders, because two different things must not happen:
     *  - **Ordinary teardown** (switching, disconnecting, closing): the session closes first, while the owner's
     *    scope and its credential store are still alive. `gateway.disconnect()` lets a refresh that is already
     *    on the wire finish and save its rotated token (up to its own 8 s settle window) and the gateway's
     *    hard-close fallback runs on a live scope. Only then are writes refused and the scope cancelled. Nothing
     *    new can start meanwhile: [mutableActive] and [owner] are already cleared, and operations run one at a time.
     *  - **Removal**: refuse writes and cancel first, so a late refresh can never recreate the deleted sign-in.
     */
    private suspend fun retire(forRemoval: Boolean = false) = withContext(NonCancellable) {
        val old = owner
        owner = null
        mutableActive.value = null
        if (old != null) {
            if (forRemoval) {
                old.credentials.invalidate()
                try {
                    old.job.cancelAndJoin()
                    old.session.close()
                } finally { old.credentials.awaitIdle() }
            } else {
                try {
                    old.session.close()
                } finally {
                    old.credentials.invalidate()
                    try { old.job.cancelAndJoin() } finally { old.credentials.awaitIdle() }
                }
            }
        }
    }

    private fun publishIndex(snapshot: SavedComputerSnapshot) {
        mutableState.value = mutableState.value.copy(computers = snapshot.computers, selectedID = snapshot.selectedID)
    }

    private suspend fun replaceIndex(
        expected: SavedComputerSnapshot,
        rows: List<SavedComputer>,
        selectedID: UUID?,
    ): SavedComputerSnapshot = try {
        registry.replace(expected, rows, selectedID)
    } catch (failure: RecordStorageException) {
        if (failure.problem != StorageProblem.DiskUnavailable) throw failure
        // Rename may have committed before its acknowledgement failed. Observe; never repeat the write.
        val observed = registry.load()
        if (observed.revision == expected.revision || observed.computers != rows || observed.selectedID != selectedID) throw failure
        observed
    }
}
