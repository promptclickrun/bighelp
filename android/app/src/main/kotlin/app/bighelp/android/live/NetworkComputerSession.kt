package app.bighelp.android.live

import app.bighelp.hermes.BrowserLauncher
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.HermesAuthenticator
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.OkHttpHermesHttp
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.chat.ChatStore
import app.bighelp.hermes.chat.HermesChatRepository
import app.bighelp.hermes.chat.HostScope
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * One computer's real authenticator, gateway and chat repository, all on the owner's [scope] so they end
 * together. The repository is built as soon as the sign-in names its principal and always before
 * `gateway.connect()`, which is what lets the first socket advertise handlers that really exist. It is closed
 * with the session. The catalog is read once the socket is up and again whenever the app returns to the front;
 * a failed read is shown by the catalog's own error and never fails the sign-in.
 */
internal class NetworkComputerSession(
    private val computerId: UUID,
    private val endpoint: HermesEndpoint,
    access: AccessSetup,
    credentials: CredentialStore,
    private val scope: CoroutineScope,
    browser: BrowserLauncher?,
    private val chatStore: ChatStore,
) : ComputerSession {
    private val http = OkHttpHermesHttp(endpoint, access.headers(endpoint))
    val authenticator = HermesAuthenticator(endpoint, http, credentials, browser)
    val gateway = GatewayClient(authenticator, scope)
    private var repository: HermesChatRepository? = null
    private var repositoryPrincipal: String? = null

    init { scope.coroutineContext[Job]?.invokeOnCompletion { authenticator.close() } }

    val chatOrNull: HermesChatRepository? get() = repository
    val chat: HermesChatRepository get() = checkNotNull(repository) { "The chat repository exists after sign-in" }

    override val link: StateFlow<ComputerLink> =
        gateway.state.map(::linkOf).stateIn(scope, SharingStarted.Eagerly, ComputerLink.Connecting)

    override val saved get() = authenticator.savedConnection
    override suspend fun discover() = authenticator.discover()

    override suspend fun signIn(input: SignInInput): SavedConnection =
        authenticator.signIn(input).also(::bindChat)

    override suspend fun restore(saved: SavedConnection) {
        authenticator.restore(saved)
        bindChat(saved)
    }

    private fun bindChat(connection: SavedConnection) {
        val principal = connection.principal
        if (repositoryPrincipal == principal && repository != null) return
        repository?.close()
        repository = HermesChatRepository(gateway, authenticator, scope, HostScope(computerId.toString(), endpoint.canonical, principal), chatStore)
        repositoryPrincipal = principal
    }

    override suspend fun connect() {
        gateway.connect()
        scope.launch { try { chat.refreshCatalog() } catch (failure: CancellationException) { throw failure } catch (_: Exception) { } }
    }

    override suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean) {
        authenticator.commit(expected, stillCurrent)
    }

    /** Back in front: a silent socket is replaced, a dropped one reconnected, then the lists are read again. */
    override suspend fun resume() {
        val chat = repository ?: return
        try {
            if (gateway.state.value.connection == GatewayConnection.Connected) chat.verifyConnection() else chat.reconnect()
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Exception) {
            // The link reports what happened; Reconnect is the person's next step.
            return
        }
        try { chat.refreshCatalog() } catch (failure: CancellationException) { throw failure } catch (_: Exception) { }
    }

    /** The person's own Reconnect. Fails with the repository's typed error. */
    override suspend fun reconnect() {
        chat.reconnect()
        try { chat.refreshCatalog() } catch (failure: CancellationException) { throw failure } catch (_: Exception) { }
    }

    override suspend fun close() {
        try { repository?.close() } finally {
            try { gateway.disconnect() } finally { authenticator.close() }
        }
    }
}
