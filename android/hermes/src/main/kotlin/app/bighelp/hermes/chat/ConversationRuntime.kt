package app.bighelp.hermes.chat

import app.bighelp.hermes.WireMessage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.withContext

/** Everything the chat pieces share: the seams, the store, the one serial dispatcher that guards all mutable state. */
internal class ChatContext(
    val gateway: ChatGateway,
    val rest: ChatRest,
    val store: ChatStore,
    val host: HostScope,
    val config: ChatConfig,
    val scope: CoroutineScope,
    val serial: CoroutineDispatcher,
) {
    /** Runs [block] on the serial dispatcher. Never await a gateway request inside it: events need this dispatcher too. */
    suspend fun <T> onState(block: () -> T): T = withContext(serial) { block() }

    fun conversationScope(ref: ConversationRef) = ConversationScope(host, ref.profile, ref.anchor)
}

/**
 * The live attachment of one conversation to the host: the runtime ID commands target, the stored ID it was
 * resumed from, and the socket generation and replay epoch that make it valid. A binding is proof only for
 * the socket it came from; a new socket needs a new one.
 */
internal data class Binding(val runtimeId: String, val storedId: String, val generation: Long, val epoch: String?, val profile: String)

/** The send being admitted: from the journal write to the owned terminal. Only one at a time per conversation. */
internal class PendingAdmission(val entry: JournalEntry, val isCommand: Boolean, val generation: Long) {
    var admitted = false
    var terminalSeen = false
    var turnFailed = false
    var pendingTurnFailed = false
    var overlapped = false
    var selectedTurn: String? = null

    /** At most two candidate starts, to detect an ambiguous overlap. */
    val candidateTurns = ArrayList<String>(2)
    val settledTurns = HashMap<String, Boolean>()

    fun select() {
        selectedTurn = candidateTurns.firstOrNull()
        terminalSeen = selectedTurn?.let { settledTurns[it] } != null
        pendingTurnFailed = selectedTurn?.let { settledTurns[it] } ?: false
    }
}

/** A confirmed admission whose local waiter ended with the socket; exact same-epoch terminal replay can settle it. */
internal class AcceptedEvidence(val entryId: String, val turnId: String, val epoch: String)

/**
 * The one attach (resume by stored ID, then the recovery bracket, then the newest history page) running for a
 * conversation on one socket generation. Every other caller for the same generation joins [done].
 */
internal class AttachFlight(val generation: Long) {
    val done = CompletableDeferred<Unit>()

    /** Set when something happened that this attach cannot cover (a newer socket, dropped events): it then leaves the decisions to the next one. */
    @Volatile var superseded = false
}

/** The one recovery bracket running for a runtime on a socket; a caller asking for the same one joins [done]. */
internal class RecoveryFlight(val generation: Long, val runtimeId: String) {
    val done = CompletableDeferred<Unit>()
}

/** Mutable state of one conversation. Touched only on the serial dispatcher. */
internal class ConversationRuntime(val scope: ConversationScope, var identity: ConversationIdentity, var title: String) {
    val ref: ConversationRef get() = scope.ref
    var phase = ConversationPhase.Opening
    var binding: Binding? = null
    val reducer = TurnReducer()

    var saved: HistoryWindow? = null
    var savedItems: List<TranscriptItem> = emptyList()
    var historyToken = 0L
    var loadingOlder = false
    var liveBaselineRowId = -1L
    var needsHistoryReseed = false

    var runtimeInfo = RuntimeInfo()
    var draft = ""
    var draftAttachments: List<String> = emptyList()
    val unresolved = ArrayList<JournalEntry>()
    var pending: PendingAdmission? = null
    var acceptedEvidence: AcceptedEvidence? = null

    var needsRecovery = false
    var requiresReattach = false
    var hydrating = false
    var heldEvents = ArrayList<WireMessage.Event>()
    var heldOverflow = false
    var attachFlight: AttachFlight? = null
    var recoveryFlight: RecoveryFlight? = null
    var hasRecovered = false

    var status: String? = null
    var stopRequested = false
    var legacyPromptHost = false
    var lastError: ChatError? = null
    var compactingConfirmed = false

    fun isBound(generation: Long): Boolean = binding?.generation == generation
}
