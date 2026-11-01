package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayClient
import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.HermesAuthenticator
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.ServerRequestHandler
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The screen-facing live chat repository of one signed-in computer.
 *
 * **Construction.** Build it with the owner's [GatewayClient], [HermesAuthenticator] and lifetime scope when the
 * computer's session object is made, *before* `gateway.connect()`. The constructor registers the server-request
 * handlers (approval, clarify and the secure inputs) and starts collecting the gateway's events, so the very first
 * socket's `client.capabilities` advertisement is already backed by real handlers and `gateway.ready` is seen.
 * Handlers are registered again before every [reconnect].
 *
 * **State.** Everything observable is a [StateFlow] of immutable values: [catalog] (agents and chats), [connection],
 * [conversations] (every retained conversation with its transcript, real activity, prompts, drafts and unresolved
 * sends), [prompts] (every actionable question across conversations) and [pendingCreations]. Nothing is shown that
 * the host did not report.
 *
 * **Actions** are suspend functions returning typed results. A send is never retried by the repository: its exact
 * bytes are journaled first, a lost receipt stays reviewable, and a persistence failure sends nothing.
 *
 * This object does not own the gateway or the authenticator: [close] stops its own work and leaves them to the owner.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HermesChatRepository private constructor(wiring: Wiring) : AutoCloseable {
    internal class Wiring(
        val gateway: ChatGateway, val rest: ChatRest, val scope: CoroutineScope, val host: HostScope, val store: ChatStore, val config: ChatConfig,
    )

    constructor(
        gateway: GatewayClient,
        authenticator: HermesAuthenticator,
        scope: CoroutineScope,
        host: HostScope,
        store: ChatStore,
        config: ChatConfig = ChatConfig(),
    ) : this(Wiring(GatewayClientAdapter(gateway), AuthenticatedRest(authenticator), scope, host, store, config))

    internal constructor(
        gateway: ChatGateway, rest: ChatRest, scope: CoroutineScope, host: HostScope, store: ChatStore, config: ChatConfig = ChatConfig(),
    ) : this(Wiring(gateway, rest, scope, host, store, config))

    private val serial: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)
    private val ctx = ChatContext(wiring.gateway, wiring.rest, wiring.store, wiring.host, wiring.config, wiring.scope, serial)
    private val creations = CreationBook(ctx)
    private val binder = SessionBinder(ctx, creations)
    private val engine = ConversationEngine(ctx, binder)
    private val catalogEngine = CatalogEngine(ctx, binder)
    private val submissions = SubmissionEngine(ctx, engine)
    private val promptCenter = PromptCenter(ctx, engine)
    private val controls = RuntimeControls(ctx, engine)
    private val operations = SessionOperations(ctx, engine, binder, catalogEngine)
    private val mutableConnection = MutableStateFlow(ConnectionStatus())
    private val mutablePending = MutableStateFlow<List<PendingCreation>>(emptyList())
    private val jobs = ArrayList<Job>()

    init {
        engine.prompts = promptCenter
        engine.submissions = submissions
        registerHandlers()
        // Subscribe before anything can connect: UNDISPATCHED hands the collector to the serial queue right here,
        // ahead of any later connect() from the same owner. A late collector would still get the retained ready.
        jobs += ctx.scope.launch(start = CoroutineStart.UNDISPATCHED) { collectEvents() }
        jobs += ctx.scope.launch(start = CoroutineStart.UNDISPATCHED) { collectConnection() }
        jobs += ctx.scope.launch { runCatching { creations.load(); mutablePending.value = creations.pending() } }
    }

    // ---- observation

    /** Agents and saved chats, merged with the hidden canonical Bot Chat; deliberately archived chats are not in `sessions`. */
    val catalog: StateFlow<CatalogState> get() = catalogEngine.state

    val connection: StateFlow<ConnectionStatus> = mutableConnection.asStateFlow()

    /** Every retained conversation. A screen shows `conversations.value[ref]` and observes changes with [observe]. */
    val conversations: StateFlow<Map<ConversationRef, ConversationState>> get() = engine.states

    /** Every actionable question from any retained conversation, oldest first. */
    val prompts: StateFlow<List<PromptState>> get() = promptCenter.states

    /** Unfinished creates that can be retried under their own key or dropped. */
    val pendingCreations: StateFlow<List<PendingCreation>> = mutablePending.asStateFlow()

    fun observe(ref: ConversationRef): Flow<ConversationState?> = conversations.map { it[ref] }.distinctUntilChanged()

    // ---- catalog

    suspend fun refreshCatalog(): CatalogState = catalogEngine.refresh()

    suspend fun archivedChats(): List<SessionSummary> = try {
        catalogEngine.loadArchived()
    } catch (e: HermesException) {
        throw ChatException(SessionBinder.chatError(e))
    }

    suspend fun search(profile: String, query: String, limit: Int = 20): List<SessionSearchResult> = try {
        catalogEngine.search(profile, query, limit)
    } catch (e: HermesException) {
        throw ChatException(SessionBinder.chatError(e))
    }

    // ---- create and open

    /**
     * A new chat for [profile]. The intent is persisted before `session.create` is sent; [retryIntent] (from
     * [CreateOutcome.Unconfirmed] or [pendingCreations]) retries that same logical create under the same key, while
     * a call without it is an independent new chat.
     */
    suspend fun createChat(profile: String, request: CreateRequest = CreateRequest(), retryIntent: String? = null): CreateOutcome {
        if (!Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) return CreateOutcome.Failed(ChatError(ChatError.Kind.InvalidInput))
        // A cancelled caller still changed the book (an intent kept or dropped): the list people see follows it.
        val step = try {
            binder.createOrdinary(profile, request, retryIntent)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            mutablePending.value = creations.pending()
            throw e
        }
        val outcome = when (step) {
            is CreateStep.Failed -> CreateOutcome.Failed(step.error)
            is CreateStep.Unconfirmed -> CreateOutcome.Unconfirmed(step.intentId, step.error)
            is CreateStep.Created -> {
                val ref = ConversationRef(profile, step.attached.storedId)
                val title = step.record.request.title ?: "New chat"
                engine.adoptCreated(ref, step.attached, title)
                creations.remove(profile)
                catalogEngine.add(newChatSummary(ref, step.attached.storedId, title, step.record.request.cwd))
                CreateOutcome.Created(ref)
            }
        }
        mutablePending.value = creations.pending()
        return outcome
    }

    private fun newChatSummary(ref: ConversationRef, stored: String, title: String, cwd: String?) = SessionSummary(
        ref, ref.profile, stored, title, "", ctx.config.clock() / 1000.0, ctx.config.clock() / 1000.0, 0, "bighelp", cwd, false,
        ArchiveState.None, null, null, false, false,
    )

    /** Abandons an unfinished create the person no longer wants retried. */
    suspend fun discardCreation(profile: String) {
        creations.remove(profile)
        mutablePending.value = creations.pending()
    }

    /**
     * The agent's canonical Bot Chat, resolved by the host's registry. With no registry chat and
     * [createIfMissing] false nothing is created; with it true the first Bot Chat is created, titled and read back,
     * and an unfinished first creation recovers by its own intent, never by a new chat.
     */
    suspend fun openBotChat(profile: String, createIfMissing: Boolean = false): BotChatOutcome {
        if (!Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) return BotChatOutcome.Failed(ChatError(ChatError.Kind.InvalidInput))
        val chat = try {
            binder.registry(profile)
        } catch (e: HermesException) {
            return BotChatOutcome.Failed(SessionBinder.chatError(e))
        } catch (e: ChatException) {
            return BotChatOutcome.Failed(e.error)
        }
        val outcome: BotChatStep = when {
            chat != null -> BotChatStep.Registered(chat)
            createIfMissing -> try {
                binder.createFirstBotChat(profile)
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                mutablePending.value = creations.pending()
                throw e
            }
            else -> return BotChatOutcome.NotCreated
        }
        mutablePending.value = creations.pending()
        return when (outcome) {
            is BotChatStep.Failed -> BotChatOutcome.Failed(outcome.error)
            is BotChatStep.Unconfirmed -> BotChatOutcome.Unconfirmed(outcome.intentId, outcome.error)
            is BotChatStep.Registered -> {
                val ref = ConversationRef(profile, outcome.chat.id)
                engine.open(ref, CatalogDecoder.registryOnly(profile, outcome.chat))
                BotChatOutcome.Opened(ref)
            }
        }
    }

    /**
     * Opens a saved chat: loads its draft, unsent entries and identity, resumes it by its stored ID on the current
     * socket, proves coverage and reads its newest history page. Safe to call again; it reattaches a suspended chat.
     * Failures appear as [ConversationState.lastError]; the transcript already held stays.
     */
    suspend fun open(ref: ConversationRef): ConversationState {
        val hint = catalog.value.sessions.firstOrNull { it.ref == ref }
        val rt = engine.open(ref, hint)
        return ctx.onState { engine.snapshot(rt) }
    }

    /** Stops retaining a conversation on this device (nothing on the host or in the durable store is deleted). */
    suspend fun release(ref: ConversationRef) {
        ctx.onState {
            engine.conversations.remove(ref)?.let { engine.historyCache.remove(ref); promptCenter.retireFor(ref) }
            engine.publishAll()
        }
    }

    // ---- composing and sending

    /** Saves the composer text and attachment references durably. Newer edits always win over an older send's restore. */
    suspend fun updateDraft(ref: ConversationRef, text: String, attachments: List<String> = emptyList()): DraftResult = submissions.updateDraft(ref, text, attachments)

    /**
     * Sends [text]. Idle: a new turn. Running: steer (default), or [SendMode.Queue] / [SendMode.InterruptAndSend].
     * A leading `/` runs the command router; pass the [selection] the person chose from [commands] (it is checked
     * against the text). The result says what Hermes did; a turn's answer arrives as events.
     */
    suspend fun send(
        ref: ConversationRef,
        text: String,
        mode: SendMode = SendMode.Default,
        attachments: List<String> = emptyList(),
        selection: SlashSelection? = null,
    ): SendResult = submissions.send(ref, text, mode, attachments, selection)

    /** `session.interrupt`; the turn is over only when the host reports `running:false`. */
    suspend fun stop(ref: ConversationRef): StopResult = submissions.stop(ref)

    /** Discards a retained entry, or puts its text back in an empty composer. Never sends anything. */
    suspend fun resolveUnresolved(ref: ConversationRef, entryId: String, decision: ReviewDecision): ReviewResult = submissions.review(ref, entryId, decision)

    // ---- prompts

    suspend fun answerPrompt(promptId: String, answer: PromptAnswer): PromptResult = promptCenter.answer(promptId, answer)
    suspend fun declinePrompt(promptId: String): PromptResult = promptCenter.decline(promptId)

    // ---- history

    suspend fun loadOlder(ref: ConversationRef): HistoryLoad = engine.loadOlder(ref)

    suspend fun reloadHistory(ref: ConversationRef) {
        val rt = ctx.onState { engine.conversations[ref] } ?: throw ChatException(ChatError.Kind.NotOpen)
        try { engine.refreshNewest(rt) } catch (e: HermesException) { throw ChatException(SessionBinder.chatError(e)) }
    }

    // ---- session edits

    suspend fun rename(ref: ConversationRef, title: String) = operations.rename(ref, title)
    suspend fun archive(ref: ConversationRef) = operations.setArchived(ref, archived = true)

    /** Restores an archived chat and refreshes the catalog so its row returns. */
    suspend fun restore(ref: ConversationRef) {
        operations.setArchived(ref, archived = false)
        catalogEngine.refresh()
    }

    suspend fun delete(ref: ConversationRef) = operations.delete(ref)

    /** A branch through the saved row [throughRowId]; opens and returns the new conversation. */
    suspend fun fork(ref: ConversationRef, throughRowId: Long): ConversationRef = operations.fork(ref, throughRowId)

    // ---- commands and runtime controls

    suspend fun commands(ref: ConversationRef): SlashCommandIndex = SlashCommandIndex(controls.commands(ref))
    suspend fun commandsForNewChat(profile: String, cwd: String? = null): SlashCommandIndex = SlashCommandIndex(controls.commandsForNewChat(profile, cwd))
    suspend fun modelOptions(ref: ConversationRef): ModelOptions = controls.options(ref)
    suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean = false): ModelChange = controls.setModel(ref, model, provider, confirmed)
    suspend fun setReasoning(ref: ConversationRef, level: String) = controls.setReasoning(ref, level)
    suspend fun setFast(ref: ConversationRef, on: Boolean) = controls.setFast(ref, on)
    suspend fun setYolo(ref: ConversationRef, on: Boolean) = controls.setYolo(ref, on)

    // ---- connection

    /**
     * Reconnects the gateway (re-verifying the sign-in first). Handlers are registered again, because a connection
     * that ended without automatic recovery forgets them. Nothing is resent: the new socket's `gateway.ready`
     * reattaches every retained chat by its stored ID and recovers coverage.
     */
    suspend fun reconnect(): ConnectionStatus {
        registerHandlers()
        try {
            ctx.gateway.reconnect()
        } catch (e: HermesException) {
            publishConnection()
            throw ChatException(SessionBinder.chatError(e))
        }
        publishConnection()
        return mutableConnection.value
    }

    /** Foreground check: a silent socket is replaced at once. */
    suspend fun verifyConnection() = ctx.gateway.verifyLiveness()

    override fun close() {
        jobs.forEach { it.cancel() }
        promptCenter.methods.forEach { ctx.gateway.setServerRequestHandler(it, null) }
    }

    // ---- internals

    private fun registerHandlers() {
        for (method in promptCenter.methods) ctx.gateway.setServerRequestHandler(method, ServerRequestHandler { promptCenter.handle(it) })
    }

    private suspend fun collectEvents() {
        while (ctx.scope.isActive) {
            try {
                ctx.gateway.events.collect { gatewayEvent ->
                    ctx.onState { engine.onEvent(gatewayEvent) }
                    if (gatewayEvent.event.type == "gateway.ready") {
                        val generation = gatewayEvent.generation
                        ctx.scope.launch { reattachWhenConnected(generation) }
                    }
                }
                return
            } catch (e: HermesException) {
                // The collector fell too far behind: events were lost. Close admission and reattach everything.
                ctx.onState { engine.onEventsLost() }
                ctx.scope.launch { reattachWhenConnected(ctx.gateway.state.value.generation) }
            }
        }
    }

    private suspend fun reattachWhenConnected(generation: Long) {
        val connected = ctx.gateway.state.first { (it.connection == GatewayConnection.Connected && it.generation == generation) || it.generation != generation }
        if (connected.generation != generation) return
        engine.reattachAll(generation)
    }

    private suspend fun collectConnection() {
        ctx.gateway.state.collect {
            // Decide from the state as it is now, not as it was when this notification was queued: a late "idle" must not
            // suspend a chat that a newer socket has already begun to recover.
            ctx.onState {
                if (ctx.gateway.state.value.connection != GatewayConnection.Connected) engine.onDisconnected() else engine.publishAll()
            }
            publishConnection()
        }
    }

    private fun publishConnection() {
        val state = ctx.gateway.state.value
        mutableConnection.value = ConnectionStatus(state.connection, state.generation, state.capabilities?.perSessionExclusiveSubmit, state.lastFailure?.kind)
    }
}
