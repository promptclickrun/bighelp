package app.bighelp.android.live

import app.bighelp.android.storage.ProtectedRecordStore
import app.bighelp.android.storage.RecordCipher
import app.bighelp.hermes.AuthProvider
import app.bighelp.hermes.AuthStatus
import app.bighelp.hermes.CredentialStore
import app.bighelp.hermes.HermesEndpoint
import app.bighelp.hermes.HermesException
import app.bighelp.hermes.SavedConnection
import app.bighelp.hermes.SignInInput
import app.bighelp.hermes.StoredAuth
import app.bighelp.hermes.chat.BotChatOutcome
import app.bighelp.hermes.chat.CatalogState
import app.bighelp.hermes.chat.ChatError
import app.bighelp.hermes.chat.ChatException
import app.bighelp.hermes.chat.ConnectionStatus
import app.bighelp.hermes.chat.ConversationIdentity
import app.bighelp.hermes.chat.ConversationPhase
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.CreateOutcome
import app.bighelp.hermes.chat.CreateRequest
import app.bighelp.hermes.chat.DraftResult
import app.bighelp.hermes.chat.HistoryLoad
import app.bighelp.hermes.chat.ModelChange
import app.bighelp.hermes.chat.ModelOptions
import app.bighelp.hermes.chat.PendingCreation
import app.bighelp.hermes.chat.PromptAnswer
import app.bighelp.hermes.chat.PromptResult
import app.bighelp.hermes.chat.ReviewDecision
import app.bighelp.hermes.chat.ReviewResult
import app.bighelp.hermes.chat.SendMode
import app.bighelp.hermes.chat.SendResult
import app.bighelp.hermes.chat.SessionSearchResult
import app.bighelp.hermes.chat.SessionSummary
import app.bighelp.hermes.chat.SlashCommandIndex
import app.bighelp.hermes.chat.SlashSelection
import app.bighelp.hermes.chat.StopResult
import java.io.File
import java.util.UUID
import javax.crypto.KeyGenerator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** A chat service that records calls and answers what a test scripts. Nothing here talks to a network. */
internal class FakeChat : ChatService {
    override val catalog = MutableStateFlow(CatalogState())
    override val conversations = MutableStateFlow<Map<ConversationRef, ConversationState>>(emptyMap())
    override val pendingCreations = MutableStateFlow<List<PendingCreation>>(emptyList())
    override val connection: StateFlow<ConnectionStatus> = MutableStateFlow(ConnectionStatus())

    val drafts = mutableListOf<Pair<ConversationRef, String>>()
    val sends = mutableListOf<Triple<ConversationRef, String, SendMode>>()
    val sendSelections = mutableListOf<SlashSelection?>()
    val released = mutableListOf<ConversationRef>()
    val opened = mutableListOf<ConversationRef>()
    val searches = mutableListOf<Pair<String, String>>()
    var nextSend: SendResult = SendResult.NotSent(ChatError(ChatError.Kind.NotConnected))
    var commandIndex = SlashCommandIndex(emptyList())
    var commandCalls = 0
    var searchResults: (String, String) -> List<SessionSearchResult> = { _, _ -> emptyList() }

    fun state(ref: ConversationRef, running: Boolean = false, prompts: List<app.bighelp.hermes.chat.PromptState> = emptyList()) =
        ConversationState(ref, "Chat", ConversationIdentity(ref, ref.anchor), ConversationPhase.Ready, running = running, prompts = prompts)

    override suspend fun refreshCatalog() = catalog.value
    override suspend fun archivedChats(): List<SessionSummary> = emptyList()
    override suspend fun search(profile: String, query: String): List<SessionSearchResult> { searches += profile to query; return searchResults(profile, query) }
    override suspend fun createChat(profile: String, request: CreateRequest, retryIntent: String?): CreateOutcome = error("unused")
    override suspend fun discardCreation(profile: String) = Unit
    override suspend fun openBotChat(profile: String, createIfMissing: Boolean): BotChatOutcome = error("unused")
    override suspend fun open(ref: ConversationRef): ConversationState { opened += ref; return conversations.value[ref] ?: state(ref) }
    override suspend fun release(ref: ConversationRef) { released += ref }
    override suspend fun updateDraft(ref: ConversationRef, text: String): DraftResult { drafts += ref to text; return DraftResult.Saved }
    override suspend fun send(ref: ConversationRef, text: String, mode: SendMode, selection: SlashSelection?): SendResult {
        sends += Triple(ref, text, mode); sendSelections += selection; return nextSend
    }
    override suspend fun stop(ref: ConversationRef): StopResult = StopResult.Requested
    override suspend fun resolveUnresolved(ref: ConversationRef, entryId: String, decision: ReviewDecision): ReviewResult = ReviewResult.Done
    override suspend fun answerPrompt(promptId: String, answer: PromptAnswer): PromptResult = PromptResult.Answered
    override suspend fun declinePrompt(promptId: String): PromptResult = PromptResult.Answered
    override suspend fun loadOlder(ref: ConversationRef): HistoryLoad = HistoryLoad.NothingOlder
    override suspend fun reloadHistory(ref: ConversationRef) = Unit
    override suspend fun rename(ref: ConversationRef, title: String) = Unit
    override suspend fun archive(ref: ConversationRef) = Unit
    override suspend fun restore(ref: ConversationRef) = Unit
    override suspend fun delete(ref: ConversationRef) = Unit
    override suspend fun fork(ref: ConversationRef, throughRowId: Long): ConversationRef = error("unused")
    override suspend fun commands(ref: ConversationRef): SlashCommandIndex { commandCalls++; return commandIndex }
    override suspend fun commandsForNewChat(profile: String): SlashCommandIndex = commandIndex
    override suspend fun modelOptions(ref: ConversationRef): ModelOptions = error("unused")
    override suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean): ModelChange = error("unused")
    override suspend fun setReasoning(ref: ConversationRef, level: String) = Unit
    override suspend fun setFast(ref: ConversationRef, on: Boolean) = Unit
}

internal class TestSession(val endpoint: HermesEndpoint, private val store: CredentialStore, val chat: FakeChat) : ComputerSession {
    override var saved: SavedConnection? = null
    override val link = MutableStateFlow(ComputerLink.Connected)
    var status = AuthStatus(false, emptyList(), emptyList())
    var discoverFailure: HermesException.Kind? = null
    var signInFailure: HermesException.Kind? = null
    var resumed = 0
    var reconnects = 0
    var reconnectFailures: MutableList<Exception> = mutableListOf()
    var closed = false

    override suspend fun discover(): AuthStatus {
        discoverFailure?.let { throw HermesException(it) }
        return status
    }
    override suspend fun signIn(input: SignInInput): SavedConnection {
        signInFailure?.let { throw HermesException(it) }
        return SavedConnection(endpoint, StoredAuth.DashboardSession("synthetic-session", true), null, null).also { saved = it }
    }
    override suspend fun restore(saved: SavedConnection) { this.saved = saved }
    override suspend fun connect() = Unit
    override suspend fun commit(expected: SavedConnection?, stillCurrent: () -> Boolean) { store.replace(expected, requireNotNull(saved)) }
    override suspend fun resume() { resumed++ }
    override suspend fun reconnect() {
        reconnects++
        if (reconnectFailures.isNotEmpty()) throw reconnectFailures.removeAt(0)
    }
    override suspend fun close() { closed = true }
}

/** A real coordinator over temporary files, with fake sessions, a fake chat and the live model on top. */
internal class LiveRig(private val root: File, scope: CoroutineScope, retryDelays: List<Long> = listOf(2_000, 6_000, 18_000)) {
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    val endpoint: HermesEndpoint = HermesEndpoint.parse("https://example.test/hermes")
    val chat = FakeChat()
    val sessions = mutableListOf<TestSession>()
    var consent = true
    var prepare: (TestSession) -> Unit = {}
    val session get() = sessions.last()
    private fun vault(id: UUID) = AndroidCredentialStore(ProtectedRecordStore(File(root, "sign-ins"), RecordCipher { key }), id.toString(), Dispatchers.Unconfined)
    private val registry = SavedComputerStore(ProtectedRecordStore(File(root, "index"), RecordCipher { key }), Dispatchers.Unconfined)
    val connections = ComputerConnectionModel(registry, ::vault, { consent }, scope) { _, address, _, credentials, _ ->
        TestSession(address, credentials, chat).also { sessions += it; prepare(it) }
    }
    val model = LiveModel(connections, { (it as TestSession).chat }, scope, retryDelays = retryDelays)

    suspend fun connect() {
        connections.beginSetup(endpoint).join()
        connections.signIn("Garden computer", SignInInput.Dashboard).join()
    }
}
