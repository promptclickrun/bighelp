package app.bighelp.android.live

import app.bighelp.android.storage.RecordStorageException
import app.bighelp.android.storage.StorageProblem
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.BrowserLauncher
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.CredentialAuthority
import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.HermesAuthenticator
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.OkHttpHermesHttp
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
import kotlinx.coroutines.flow.MutableStateFlow
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
    suspend fun discover(): AuthStatus
    suspend fun signIn(input: SignInInput): SavedConnection
    suspend fun restore(saved: SavedConnection)
    suspend fun connect()
    suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean)
    suspend fun close()
}

/** The real session stays available to the chat repository without exposing credentials to screens. */
internal class NetworkComputerSession(
    endpoint: HermesEndpoint,
    credentials: CredentialStore,
    scope: CoroutineScope,
    browser: BrowserLauncher?,
) : ComputerSession {
    private val http = OkHttpHermesHttp(endpoint)
    val authenticator = HermesAuthenticator(endpoint, http, credentials, browser)
    val gateway = GatewayClient(authenticator, scope)
    init { scope.coroutineContext[Job]?.invokeOnCompletion { authenticator.close() } }
    override val saved get() = authenticator.savedConnection
    override suspend fun discover() = authenticator.discover()
    override suspend fun signIn(input: SignInInput) = authenticator.signIn(input)
    override suspend fun restore(saved: SavedConnection) {
        authenticator.restore(saved)
    }
    override suspend fun connect() { gateway.connect() }
    override suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean) {
        authenticator.commit(expected, stillCurrent)
    }
    override suspend fun close() {
        try { gateway.disconnect() } finally { authenticator.close() }
    }
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
internal class ComputerConnectionModel<T : ComputerSession>(
    private val registry: SavedComputerStore,
    private val credentials: (UUID) -> AndroidCredentialStore,
    private val consentGranted: () -> Boolean,
    private val scope: CoroutineScope,
    private val factory: (HermesEndpoint, CredentialStore, CoroutineScope) -> T,
) {
    private val mutableState = MutableStateFlow(ComputerConnectionState())
    val state: StateFlow<ComputerConnectionState> = mutableState.asStateFlow()
    private val mutableActive = MutableStateFlow<ConnectedComputer<T>?>(null)
    val active: StateFlow<ConnectedComputer<T>?> = mutableActive.asStateFlow()
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
        owner?.credentials?.invalidate()
        return CoroutineScope(scope.coroutineContext.minusKey(Job) + NonCancellable).launch {
            previous?.join()
            try { retire() } catch (_: Exception) { /* The owner is invalid even if socket cleanup fails. */ }
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.Idle)
        }.also { cleanup = it }
    }

    private class Owner<T : ComputerSession>(
        val id: UUID, val endpoint: HermesEndpoint, val session: T, val job: Job, val scope: CoroutineScope,
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

    fun beginSetup(endpoint: HermesEndpoint): Job = launchOperation { token ->
        retire()
        if (!hasConsent()) return@launchOperation
        val next = newOwner(UUID.randomUUID(), endpoint)
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
        val next = newOwner(id, row.endpoint)
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
        current.session.connect()
        requireOwner(current, token)
        var snapshot = registry.load()
        requireOwner(current, token)
        val existing = snapshot.computers.firstOrNull { it.id == current.id }
        if (existing != null && existing.authority != candidate.authority) {
            throw HermesException(HermesException.Kind.IdentityChanged)
        }
        if (snapshot.computers.any { it.id != current.id && it.authority == candidate.authority }) {
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, problem = ComputerProblem.AlreadyConfigured)
            return@launchOperation
        }
        if (existing == null && snapshot.computers.size >= 32) {
            mutableState.value = mutableState.value.copy(phase = ComputerPhase.SignIn, problem = ComputerProblem.ComputerLimit)
            return@launchOperation
        }
        val expected = existing?.let { credentials(it.id).load(it.authority) }
        requireOwner(current, token)
        val pending = SavedComputer(current.id, cleanName, candidate.endpoint, candidate.principal, false)
        val rows = if (existing == null) snapshot.computers + pending
            else snapshot.computers.map { if (it.id == current.id) pending else it }
        snapshot = replaceIndex(snapshot, rows, current.id)
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
        if (owner?.id == id || mutableActive.value == null) retire()
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
        val next = newOwner(id, row.endpoint)
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

    private fun newOwner(id: UUID, endpoint: HermesEndpoint): Owner<T> {
        val job = SupervisorJob(scope.coroutineContext[Job])
        val ownedScope = CoroutineScope(scope.coroutineContext + job)
        val store = OwnedCredentialStore(credentials(id)) { job.isActive }
        return try { Owner(id, endpoint, factory(endpoint, store, ownedScope), job, ownedScope, store) }
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

    private suspend fun retire() = withContext(NonCancellable) {
        val old = owner
        owner = null
        mutableActive.value = null
        if (old != null) {
            old.credentials.invalidate()
            try {
                old.job.cancelAndJoin()
                old.session.close()
            } finally { old.credentials.awaitIdle() }
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
