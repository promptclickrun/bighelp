package app.bighelp.android.live

import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.chat.ChatError
import app.bighelp.hermes.chat.ChatException
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.CreateOutcome
import app.bighelp.hermes.chat.CreateRequest
import app.bighelp.hermes.chat.HistoryLoad
import app.bighelp.hermes.chat.ModelChange
import app.bighelp.hermes.chat.ModelOptions
import app.bighelp.hermes.chat.PromptAnswer
import app.bighelp.hermes.chat.PromptResult
import app.bighelp.hermes.chat.ReviewDecision
import app.bighelp.hermes.chat.ReviewResult
import app.bighelp.hermes.chat.SendMode
import app.bighelp.hermes.chat.SendResult
import app.bighelp.hermes.chat.SessionSummary
import app.bighelp.hermes.chat.SlashCommandIndex
import app.bighelp.hermes.chat.StopResult
import app.bighelp.hermes.chat.BotChatOutcome
import app.bighelp.hermes.chat.CatalogState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

internal sealed interface SendOutcome {
    /** Hermes took it, or it is kept for review: the message box can be cleared. */
    data object Sent : SendOutcome

    /** Nothing left the phone as a message: the text stays in the box and [message] says why. */
    data class Kept(val message: String) : SendOutcome
}

internal sealed interface SetupOutcome {
    data class Ready(val status: AuthStatus) : SetupOutcome
    data class Failed(val message: String) : SetupOutcome
    data object Cancelled : SetupOutcome
}

/** A short message for the screen to show once; [id] makes the same words shown twice distinct. */
internal class Notice(val id: Long, val text: String)

internal data class SearchHit(val ref: ConversationRef, val title: String, val agentName: String, val snippet: String)

/**
 * Everything the live screens do, on top of the connection coordinator and one computer's [ChatService]. Plain
 * Kotlin, called from the main thread, with no Android types, so every rule runs in JVM tests. It owns what
 * a screen must not: coming back to the front, retrying a lost connection (in front only, with growing pauses,
 * never after a refused sign-in), saving drafts after a pause, which chats stay retained, and what a failed
 * action says. Every message comes from [LiveText].
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class LiveModel<T : ComputerSession>(
    val connections: ComputerConnectionModel<T>,
    private val chatOf: (T) -> ChatService,
    private val scope: CoroutineScope,
    private val retryDelays: List<Long> = listOf(2_000L, 6_000L, 18_000L),
    private val draftDelayMillis: Long = 300L,
    private val searchDelayMillis: Long = 400L,
) {
    val chat: StateFlow<ChatService?> =
        connections.active.map { it?.let { computer -> chatOf(computer.session) } }.stateIn(scope, SharingStarted.Eagerly, null)
    val catalog: StateFlow<CatalogState> =
        chat.flatMapLatest { it?.catalog ?: flowOf(CatalogState()) }.stateIn(scope, SharingStarted.Eagerly, CatalogState())
    val conversations: StateFlow<Map<ConversationRef, ConversationState>> =
        chat.flatMapLatest { it?.conversations ?: flowOf(emptyMap()) }.stateIn(scope, SharingStarted.Eagerly, emptyMap())
    val pendingCreations = chat.flatMapLatest { it?.pendingCreations ?: flowOf(emptyList()) }
        .stateIn(scope, SharingStarted.Eagerly, emptyList())
    val link: StateFlow<ComputerLink?> get() = connections.link

    private val mutableForeground = MutableStateFlow(false)
    private val mutableProblem = MutableStateFlow<ChatError.Kind?>(null)

    /** Why reconnecting cannot help by itself (the host refused the saved sign-in); null otherwise. */
    val reconnectProblem: StateFlow<ChatError.Kind?> = mutableProblem.asStateFlow()

    private val mutableNotice = MutableStateFlow<Notice?>(null)
    val notice: StateFlow<Notice?> = mutableNotice.asStateFlow()
    private var noticeCounter = 0L

    private val mutableSearch = MutableStateFlow("")
    val searchText: StateFlow<String> = mutableSearch.asStateFlow()
    private val mutableHits = MutableStateFlow<List<SearchHit>>(emptyList())

    /** Chats whose messages matched the search text, asked of the host agent by agent. */
    val contentHits: StateFlow<List<SearchHit>> = mutableHits.asStateFlow()
    private var searchJob: Job? = null

    private val picked = MutableStateFlow<String?>(null)

    /** The agent new chats start with: the person's pick, else the default agent, else the first one. */
    val selectedAgentId: StateFlow<String?> = combine(catalog, picked) { current, pick ->
        pick?.takeIf { id -> current.agents.any { it.id == id } }
            ?: current.agents.firstOrNull { it.id == "default" }?.id
            ?: current.agents.firstOrNull()?.id
    }.stateIn(scope, SharingStarted.Eagerly, null)

    private var activeBeforeSetup: java.util.UUID? = null
    private var restartSetup: (suspend () -> Unit)? = null
    private val draftJobs = HashMap<ConversationRef, Job>()
    private val latestDrafts = HashMap<ConversationRef, String>()
    private val commandIndexes = HashMap<ConversationRef, SlashCommandIndex>()

    init {
        // Offline while in front: try again with growing pauses. The restart on every change of either input
        // is what makes "backgrounded", "back online" and "a different computer" all end an attempt at once.
        scope.launch {
            combine(connections.link, mutableForeground) { current, foreground -> current == ComputerLink.Offline && foreground }
                .distinctUntilChanged()
                .collectLatest { shouldRetry -> if (shouldRetry) retryConnection() }
        }
        scope.launch { connections.link.collect { if (it == ComputerLink.Connected) mutableProblem.value = null } }
    }

    // ---- lifecycle

    fun start(): Job = connections.load()

    fun onForeground() {
        mutableForeground.value = true
        val active = connections.active.value
        if (active != null) {
            scope.launch { active.session.resume() }
        } else {
            val state = connections.state.value
            // A saved computer that failed to open gets another try; one the person disconnected does not.
            if (state.phase == ComputerPhase.Failed) state.selectedID?.let { connections.select(it) }
        }
    }

    fun onBackground() {
        mutableForeground.value = false
    }

    private suspend fun retryConnection() {
        for (pause in retryDelays) {
            delay(pause)
            val session = connections.active.value?.session ?: return
            try {
                session.reconnect()
                return
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Exception) {
                if (isSignInLoss(failure)) { mutableProblem.value = ChatError.Kind.SignInRequired; return }
            }
        }
    }

    /** The person's own Reconnect. */
    fun reconnectNow() {
        scope.launch {
            val session = connections.active.value?.session ?: return@launch
            try {
                session.reconnect()
                mutableProblem.value = null
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Exception) {
                if (isSignInLoss(failure)) mutableProblem.value = ChatError.Kind.SignInRequired else notify(describe(failure))
            }
        }
    }

    private fun isSignInLoss(failure: Exception) =
        (failure is ChatException && failure.error.kind == ChatError.Kind.SignInRequired) ||
            (failure is HermesException && failure.kind in SIGN_IN_LOSS)

    private fun describe(failure: Exception): String = when (failure) {
        is ChatException -> LiveText.describe(failure.error)
        is HermesException -> LiveText.describe(failure.kind)
        else -> "Couldn't reconnect."
    }

    // ---- computers and setup

    /** Checks the address with the person's access details and returns the host's sign-in options or a reason. */
    suspend fun beginSetup(endpoint: HermesEndpoint, access: AccessSetup): SetupOutcome {
        // Adding a computer closes the open one (one owner at a time); cancelling the add opens it again.
        connections.active.value?.computer?.id?.let { activeBeforeSetup = it }
        restartSetup = { connections.beginSetup(endpoint, access).join() }
        connections.beginSetup(endpoint, access).join()
        val state = connections.state.value
        return when (state.phase) {
            ComputerPhase.SignIn -> SetupOutcome.Ready(state.authStatus ?: AuthStatus(false, emptyList(), emptyList()))
            ComputerPhase.Failed -> SetupOutcome.Failed(
                state.authFailure?.let(LiveText::describe) ?: state.problem?.let(LiveText::problem) ?: "Couldn't connect to this computer.",
            )
            ComputerPhase.ConsentRequired -> SetupOutcome.Failed("Agree to share chat data first.")
            else -> SetupOutcome.Cancelled
        }
    }

    /** Ends a check or a sign-in in progress, and reopens the computer that was open before it started, if any. */
    fun cancelSetup(): Job = scope.launch {
        val previous = activeBeforeSetup
        activeBeforeSetup = null
        // Selecting retires the setup's own session first, so the open computer is never reported gone in between.
        if (previous != null && consentIsKept()) connections.select(previous).join() else connections.disconnect().join()
    }

    private fun consentIsKept() = connections.state.value.phase != ComputerPhase.ConsentRequired

    /**
     * Signs in the computer being set up. A refused sign-in ends its session, so trying again on the same screen
     * first starts the same setup over (same address, same access details) rather than doing nothing.
     */
    fun signIn(name: String, input: SignInInput): Job = scope.launch {
        if (connections.state.value.phase == ComputerPhase.Failed) {
            restartSetup?.invoke()
            if (connections.state.value.phase != ComputerPhase.SignIn) return@launch
        }
        connections.signIn(name, input).join()
        if (connections.state.value.phase == ComputerPhase.Connected) activeBeforeSetup = null
    }

    fun select(id: java.util.UUID): Job = connections.select(id)
    fun remove(id: java.util.UUID): Job = connections.remove(id)
    fun reauthenticate(id: java.util.UUID): Job {
        restartSetup = { connections.reauthenticate(id).join() }
        return connections.reauthenticate(id)
    }
    fun disconnect(): Job = connections.disconnect()

    // ---- notices

    fun notify(text: String) { mutableNotice.value = Notice(++noticeCounter, text) }
    fun dismissNotice(id: Long) { if (mutableNotice.value?.id == id) mutableNotice.value = null }

    // ---- lists

    fun selectAgent(id: String) { picked.value = id }

    suspend fun refresh() { guarded { it.refreshCatalog() } }

    suspend fun archived(): List<SessionSummary>? = guarded { it.archivedChats() }

    fun setSearch(query: String) {
        mutableSearch.value = query
        searchJob?.cancel()
        val trimmed = query.trim()
        if (trimmed.length < 2) {
            searchJob = null
            mutableHits.value = emptyList()
            return
        }
        searchJob = scope.launch {
            delay(searchDelayMillis)
            val service = chat.value ?: return@launch
            val agents = catalog.value.agents.take(MAXIMUM_SEARCHED_AGENTS)
            val names = agents.associate { it.id to it.displayName.ifBlank { it.id } }
            val found = coroutineScope {
                agents.map { agent ->
                    async {
                        try { service.search(agent.id, trimmed) } catch (failure: CancellationException) { throw failure } catch (_: Exception) { emptyList() }
                    }
                }.awaitAll()
            }
            mutableHits.value = found.flatten().distinctBy { it.session.ref }.map { SearchHit(it.session.ref, it.session.title.ifBlank { "Chat" }, names[it.session.profile] ?: it.session.profile, it.snippet) }
        }
    }

    // ---- creating and opening

    /** A new chat with [profile]; the ref to open, or null with a notice. An unconfirmed create is kept to retry. */
    suspend fun newChat(profile: String, request: CreateRequest = CreateRequest()): ConversationRef? =
        when (val outcome = guarded { it.createChat(profile, request) }) {
            is CreateOutcome.Created -> outcome.ref
            is CreateOutcome.Unconfirmed -> { notify(LiveText.describe(outcome.error)); null }
            is CreateOutcome.Failed -> { notify(LiveText.describe(outcome.error)); null }
            null -> null
        }

    suspend fun retryCreation(profile: String, intentId: String): ConversationRef? =
        when (val outcome = guarded { it.createChat(profile, CreateRequest(), intentId) }) {
            is CreateOutcome.Created -> outcome.ref
            is CreateOutcome.Unconfirmed -> { notify(LiveText.describe(outcome.error)); null }
            is CreateOutcome.Failed -> { notify(LiveText.describe(outcome.error)); null }
            null -> null
        }

    suspend fun discardCreation(profile: String) { guarded { it.discardCreation(profile) } }

    suspend fun openBotChat(profile: String): ConversationRef? =
        when (val outcome = guarded { it.openBotChat(profile, createIfMissing = true) }) {
            is BotChatOutcome.Opened -> outcome.ref
            is BotChatOutcome.Unconfirmed -> { notify(LiveText.describe(outcome.error)); null }
            is BotChatOutcome.Failed -> { notify(LiveText.describe(outcome.error)); null }
            BotChatOutcome.NotCreated -> null
            null -> null
        }

    suspend fun openChat(ref: ConversationRef): ConversationState? {
        val service = chat.value ?: return null
        val state = guarded { it.open(ref) }
        releaseIdle(service, except = ref)
        return state
    }

    /** Leaving a chat saves its draft now, and lets go of it unless it is working or waiting on the reader. */
    suspend fun leaveChat(ref: ConversationRef) {
        flushDraft(ref)
        commandIndexes.remove(ref)
        val service = chat.value ?: return
        val state = service.conversations.value[ref] ?: return
        if (!state.running && state.prompts.isEmpty()) quietly { service.release(ref) }
    }

    private suspend fun releaseIdle(service: ChatService, except: ConversationRef) {
        for ((ref, state) in service.conversations.value) {
            if (ref != except && !state.running && state.prompts.isEmpty()) quietly { service.release(ref) }
        }
    }

    // ---- composing and sending

    fun editDraft(ref: ConversationRef, text: String) {
        latestDrafts[ref] = text
        draftJobs[ref]?.cancel()
        draftJobs[ref] = scope.launch {
            delay(draftDelayMillis)
            draftJobs.remove(ref)
            saveDraft(ref)
        }
    }

    suspend fun flushDraft(ref: ConversationRef) {
        draftJobs.remove(ref)?.cancel()
        saveDraft(ref)
    }

    private suspend fun saveDraft(ref: ConversationRef) {
        val text = latestDrafts.remove(ref) ?: return
        val service = chat.value ?: return
        val result = try { service.updateDraft(ref, text) } catch (failure: CancellationException) { throw failure } catch (_: Exception) { null }
        if (result is app.bighelp.hermes.chat.DraftResult.NotSaved) notify(LiveText.describe(result.error))
    }

    suspend fun send(ref: ConversationRef, text: String, mode: SendMode): SendOutcome {
        val service = chat.value ?: return SendOutcome.Kept(LiveText.describe(ChatError(ChatError.Kind.NotConnected)))
        // The send clears the draft itself; a save still waiting would put the sent words back.
        draftJobs.remove(ref)?.cancel()
        latestDrafts.remove(ref)
        val selection = if (text.startsWith("/")) commandIndex(service, ref)?.selection(text) else null
        val result = try {
            service.send(ref, text, mode, selection)
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: ChatException) {
            return SendOutcome.Kept(LiveText.describe(failure.error))
        }
        return when (result) {
            is SendResult.Admitted -> SendOutcome.Sent
            is SendResult.Uncertain -> {
                notify("We couldn't confirm that message arrived. Review it above the message box. Nothing is sent again by itself.")
                SendOutcome.Sent
            }
            is SendResult.Refused -> SendOutcome.Kept(
                if (result.reachedSessionLimit) LiveText.describe(HermesException.Kind.ActiveSessionLimit) else LiveText.describe(result.error),
            )
            is SendResult.NotSent -> SendOutcome.Kept(result.block?.let(LiveText::sendBlock) ?: LiveText.describe(result.error))
        }
    }

    private suspend fun commandIndex(service: ChatService, ref: ConversationRef): SlashCommandIndex? {
        commandIndexes[ref]?.let { return it }
        return try {
            service.commands(ref).also { commandIndexes[ref] = it }
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Exception) {
            null
        }
    }

    /** Commands to suggest for a draft that is just `/word`. Empty when the list cannot be read. */
    suspend fun suggestions(ref: ConversationRef, draft: String): List<app.bighelp.hermes.chat.SlashCommand> {
        if (!draft.startsWith("/")) return emptyList()
        val service = chat.value ?: return emptyList()
        return commandIndex(service, ref)?.suggestions(draft).orEmpty()
    }

    suspend fun stop(ref: ConversationRef) {
        when (val result = guarded { it.stop(ref) }) {
            is StopResult.Refused -> notify(LiveText.describe(result.error))
            is StopResult.Uncertain -> notify("We couldn't confirm the stop. The chat will show when it ends.")
            StopResult.Requested, null -> Unit
        }
    }

    suspend fun review(ref: ConversationRef, entryId: String, decision: ReviewDecision) {
        when (val result = guarded { it.resolveUnresolved(ref, entryId, decision) }) {
            ReviewResult.ComposerNotEmpty -> notify("Clear the message box first to put that message back.")
            is ReviewResult.Failed -> notify(LiveText.describe(result.error))
            ReviewResult.Done, ReviewResult.NotFound, null -> Unit
        }
    }

    // ---- questions from the agent

    suspend fun answerPrompt(promptId: String, answer: PromptAnswer): PromptResult? {
        val result = guarded { it.answerPrompt(promptId, answer) }
        when (result) {
            PromptResult.NoLongerActive -> notify("That question is no longer waiting.")
            is PromptResult.Invalid -> notify("That answer can't be used. Check it and try again.")
            PromptResult.Answered, null -> Unit
        }
        return result
    }

    suspend fun declinePrompt(promptId: String) { guarded { it.declinePrompt(promptId) } }

    // ---- history and chat edits

    suspend fun loadOlder(ref: ConversationRef): HistoryLoad? = guarded { it.loadOlder(ref) }

    suspend fun rename(ref: ConversationRef, title: String) { guarded { it.rename(ref, title) } }
    suspend fun archive(ref: ConversationRef) { guarded { it.archive(ref) } }
    suspend fun restore(ref: ConversationRef) { guarded { it.restore(ref) } }
    suspend fun delete(ref: ConversationRef) { guarded { it.delete(ref) } }
    suspend fun fork(ref: ConversationRef, throughRowId: Long): ConversationRef? = guarded { it.fork(ref, throughRowId) }

    // ---- model, reasoning and speed

    suspend fun modelOptions(ref: ConversationRef): ModelOptions? = guarded { it.modelOptions(ref) }
    suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean): ModelChange? =
        guarded { it.setModel(ref, model, provider, confirmed) }
    suspend fun setReasoning(ref: ConversationRef, level: String) { guarded { it.setReasoning(ref, level) } }
    suspend fun setFast(ref: ConversationRef, on: Boolean) { guarded { it.setFast(ref, on) } }

    // ---- helpers

    /** Runs an action on the active computer's chat; a typed failure becomes one plain notice and null. */
    private suspend fun <R> guarded(action: suspend (ChatService) -> R): R? {
        val service = chat.value ?: run { notify(LiveText.describe(ChatError(ChatError.Kind.NotConnected))); return null }
        return try {
            action(service)
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: ChatException) {
            notify(LiveText.describe(failure.error)); null
        } catch (failure: HermesException) {
            notify(LiveText.describe(failure.kind)); null
        }
    }

    private suspend fun quietly(block: suspend () -> Unit) {
        try { block() } catch (failure: CancellationException) { throw failure } catch (_: Exception) { }
    }

    private companion object {
        const val MAXIMUM_SEARCHED_AGENTS = 8
        val SIGN_IN_LOSS = setOf(HermesException.Kind.AuthenticationRequired, HermesException.Kind.InvalidCredentials)
    }
}
