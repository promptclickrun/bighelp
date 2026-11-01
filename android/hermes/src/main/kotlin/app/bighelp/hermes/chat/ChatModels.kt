package app.bighelp.hermes.chat

import app.bighelp.hermes.GatewayConnection
import app.bighelp.hermes.HermesException
import kotlinx.serialization.json.JsonObject

// The values a screen observes and the results its actions return. Every one is immutable; the repository
// publishes a new value on each change. Nothing here carries a secret, and nothing is invented: a field is
// null or empty when the host did not say.

/** Why an action or load did not complete. [cause] and [code] are Hermes' own classification when it gave one. */
class ChatError(val kind: Kind, val cause: HermesException.Kind? = null, val code: Long? = null, val reason: String? = null) {
    enum class Kind {
        /** Not connected, or the socket was replaced while the action ran. */
        NotConnected,

        /** The host answered that it is unavailable, rate limited, or could not be reached. */
        HostUnavailable,

        /** The host wants a new sign-in. */
        SignInRequired,

        /** The conversation is not open in this repository, or the host named no such chat. */
        NotOpen,

        /** The session has no live runtime on this connection; open it again. */
        NoLiveSession,

        /** The durable store refused a write, so nothing was sent. */
        PersistenceFailed,

        /** The host or plugin answered in a shape this client does not accept. */
        InvalidResponse,

        /** Hermes answered with a refusal (see [code] and [reason]). */
        Rejected,

        /** The request or answer exceeded a documented bound. */
        TooLarge,

        /** The host does not offer this operation. */
        Unsupported,

        /** History changed between pages; the transcript was reloaded from the newest page instead of merged. */
        HistoryChanged,

        /** A chosen model was not the one the session reported. */
        ModelNotConfirmed,

        /** A requested folder was not the session's folder. */
        WorkspaceNotConfirmed,

        /** A create was sent and no answer came; its intent is retained (see [PendingCreation]). */
        CreationUnconfirmed,

        /** A create for this profile is already in flight. */
        CreationInProgress,

        /** The outcome of a mutation is unknown; reconcile before trying again. */
        OutcomeUnknown,

        /** The action does not apply now (a turn is running, the chat is not idle, it is already archived). */
        Conflict,

        /** The input is empty, or a chosen command no longer matches the text. Nothing was sent. */
        InvalidInput,

        /** Steer needs a turn that was observed running; an idle chat is never silently sent as a new turn. */
        NoActiveTurn,

        Cancelled,
    }

    override fun toString() = "ChatError($kind${cause?.let { ", $it" }.orEmpty()}${code?.let { ", $it" }.orEmpty()})"
}

class ChatException(val error: ChatError) : Exception(error.kind.name) {
    constructor(kind: ChatError.Kind, cause: HermesException.Kind? = null, code: Long? = null, reason: String? = null) :
        this(ChatError(kind, cause, code, reason))
}

// ---- Agents and sessions ---------------------------------------------------------------------------------

class CanonicalChat(val id: String, val resolvedId: String?)

/** One profile from `profiles.list{include_sessions:true}`. [metadata] is the host's whole row, so optional fields survive. */
class AgentSummary(
    val id: String,
    val displayName: String,
    val canonicalChat: CanonicalChat?,
    val metadata: JsonObject,
) {
    override fun toString() = "AgentSummary($id)"
}

enum class ArchiveState {
    None,

    /** Someone archived it (any client). Not in the normal list; in Archived chats. */
    Deliberate,

    /** Hermes' idle sweep archived it. It stays in the list: that was not the person's choice. */
    Automatic,
}

/** One saved chat row from `GET /api/sessions`, or a Bot Chat the registry names but the list hides. */
class SessionSummary(
    val ref: ConversationRef,
    val profile: String,
    /** The row's own stored ID (its tip, as the host lists it). */
    val storedId: String,
    val title: String,
    val preview: String,
    val startedAtEpochSeconds: Double?,
    val lastActiveEpochSeconds: Double?,
    val messageCount: Int,
    val source: String?,
    val cwd: String?,
    val pinned: Boolean,
    val archive: ArchiveState,
    val lineageRootId: String?,
    val lineageIds: List<String>?,
    val isCanonicalBotChat: Boolean,
    /** True when only the registry names it (the list hides every Bot Chat): no title, preview or time is invented. */
    val isRegistryOnly: Boolean,
) {
    override fun toString() = "SessionSummary($ref)"
}

class SessionSearchResult(val session: SessionSummary, val snippet: String)

data class CatalogState(
    val agents: List<AgentSummary> = emptyList(),
    /** An agent whose chat list the host could not give (for example a profile with no session store yet). Its chats are absent; the others are listed. */
    val agentErrors: Map<String, ChatError> = emptyMap(),
    val sessions: List<SessionSummary> = emptyList(),
    val loading: Boolean = false,
    val error: ChatError? = null,
    val loadedAtMillis: Long? = null,
    /** More than the 10,000-chat ceiling exist; the rest are not listed. */
    val truncated: Boolean = false,
)

/** An unfinished create, retained so a lost reply can be retried under the same key or dropped by the person. */
data class PendingCreation(val profile: String, val intentId: String, val purpose: CreationPurpose, val phase: CreationPhase, val request: CreateRequest)

sealed interface CreateOutcome {
    /** The chat exists and is open; [ref] is its conversation. */
    data class Created(val ref: ConversationRef) : CreateOutcome

    /** The create was sent and no definite answer came. [intentId] retries the same logical create (same key). */
    data class Unconfirmed(val intentId: String, val error: ChatError) : CreateOutcome

    /** Nothing was created. */
    data class Failed(val error: ChatError) : CreateOutcome
}

// ---- Connection -------------------------------------------------------------------------------------------

data class ConnectionStatus(
    val gateway: GatewayConnection = GatewayConnection.Idle,
    val generation: Long = 0,
    /** The host's `per_session_exclusive_submit`, or null until known on this socket. False keeps chat submit off. */
    val exclusiveSubmit: Boolean? = null,
    val lastFailure: HermesException.Kind? = null,
)

// ---- Transcript ---------------------------------------------------------------------------------------------

enum class MessageRole { User, Assistant, System, Unknown }

enum class ItemOrigin {
    /** A physical row of the host's saved history. */
    Saved,

    /** Built from this connection's live events; richer than a saved row and kept until history catches up. */
    Live,

    /** Typed here and sent (or being sent), not yet bound to a saved row. */
    Local,
}

sealed interface TranscriptItem {
    val id: String
}

data class MessageItem(
    override val id: String,
    val role: MessageRole,
    val rawRole: String,
    val text: String,
    val origin: ItemOrigin,
    /** The physical history row ID, once known. Never derived from text. */
    val rowId: Long? = null,
    /** `display_kind` such as `model_switch`; hidden kinds are not in the list. */
    val displayKind: String? = null,
    /** Non-text content parts the host stored; they are kept, not rendered. */
    val hasUnsupportedContent: Boolean = false,
    val timestampEpochSeconds: Double? = null,
    val turnDurationMillis: Int? = null,
    /** False while this assistant segment is still streaming. */
    val complete: Boolean = true,
    /** A command's output shown once instead of a turn. */
    val isCommandResult: Boolean = false,
    /** How Hermes said this reply's turn failed (a failed final), when it did. */
    val failure: TurnFailure? = null,
) : TranscriptItem {
    override fun toString() = "MessageItem($id, $role, ${text.length} chars)"
}

enum class ActivityKind { Tool, Reasoning, Notice, Subagent }

enum class ActivityLifecycle {
    Running, Succeeded, Failed, Cancelled,

    /** Seen in history or settled by a turn end without an explicit result: neither success nor failure is claimed. */
    Recorded,
}

data class ActivityItem(
    override val id: String,
    val kind: ActivityKind,
    val title: String,
    val detail: String?,
    val lifecycle: ActivityLifecycle,
    val toolCallId: String? = null,
    val turnId: String? = null,
    val origin: ItemOrigin,
    /** A tool's original arguments and result, as strings (JSON text when the host sent JSON). */
    val arguments: String? = null,
    val result: String? = null,
) : TranscriptItem

// ---- Conversation ---------------------------------------------------------------------------------------------

enum class ConversationPhase {
    /** Resuming the stored session and loading its newest page. */
    Opening,

    /** Attached to a live runtime on the current socket with coverage proved. */
    Ready,

    /** Catching up after a reconnect: sending is closed until coverage is proved. */
    Recovering,

    /** The socket is gone or the runtime was reclaimed; the transcript stays, nothing is sent until reattached. */
    Suspended,
}

/** Why a new message cannot be admitted right now. Null in [ConversationState.sendBlock] means it can. */
enum class SendBlock {
    Opening,
    NotConnected,
    CatchingUp,
    RecoveryRequired,
    PendingAdmission,
    HostLacksExclusiveSubmit,
    TooManyUnresolved,
    NoLiveSession,
}

data class HistoryState(val hasOlder: Boolean = false, val loadingOlder: Boolean = false, val retainedRows: Int = 0)

/** What the live runtime reported about itself (`session.info`, activation). Absent fields are null. */
data class RuntimeInfo(
    val model: String? = null,
    val provider: String? = null,
    val reasoningEffort: String? = null,
    val serviceTier: String? = null,
    val cwd: String? = null,
    val lazy: Boolean? = null,
)

/** The unsettled and refused submissions of one conversation, for review. The text is the person's own. */
data class UnresolvedSubmission(
    val id: String,
    val method: String,
    val composerText: String,
    val attachments: List<String>,
    val createdAtMillis: Long,
    /** Non-null for a definite refusal (nothing was admitted); null when the outcome is unknown. */
    val rejectionCode: Int?,
)

data class ConversationState(
    val ref: ConversationRef,
    val title: String,
    val identity: ConversationIdentity,
    val phase: ConversationPhase,
    val items: List<TranscriptItem> = emptyList(),
    /** A turn is running (observed from `message.start`/`session.info`), so Send steers by default. */
    val running: Boolean = false,
    /** Real status from the host's own events (a tool name, a notice), never a guessed progress. */
    val status: String? = null,
    val runtime: RuntimeInfo = RuntimeInfo(),
    val draft: String = "",
    val draftAttachments: List<String> = emptyList(),
    val sendBlock: SendBlock? = SendBlock.Opening,
    val unresolved: List<UnresolvedSubmission> = emptyList(),
    val prompts: List<PromptState> = emptyList(),
    val history: HistoryState = HistoryState(),
    /** A stop was requested and acknowledged; the turn is over only when the host says `running:false`. */
    val stopRequested: Boolean = false,
    /** This host answers approvals the older way (events, not requests); such cards are not offered. */
    val legacyPromptHost: Boolean = false,
    val lastError: ChatError? = null,
)

// ---- Sending ---------------------------------------------------------------------------------------------------

enum class SendMode {
    /** Idle: a new turn. Running: steer. */
    Default,
    Steer,

    /** `prompt.submit{queued:true}` behind the running turn. */
    Queue,

    /** Stop the turn, then (only after the stop receipt) queue this message. */
    InterruptAndSend,
}

enum class Admission { Streaming, Queued, Steered, CommandOutput }

sealed interface SendResult {
    /** Hermes admitted it. A turn's answer arrives as events; this is not completion. */
    data class Admitted(val entryId: String, val admission: Admission) : SendResult

    /** Hermes definitely did not take it. The text is still the person's: it is in the composer or kept as an unsent entry. */
    data class Refused(val entryId: String?, val rejectionCode: Int?, val reachedSessionLimit: Boolean = false, val error: ChatError) : SendResult

    /** The send may or may not have reached Hermes. It is retained for review and never resent. */
    data class Uncertain(val entryId: String, val error: ChatError) : SendResult

    /** Nothing was written to the socket (a precondition, a persistence failure, an oversize message). */
    data class NotSent(val error: ChatError, val block: SendBlock? = null) : SendResult
}

sealed interface ReviewResult {
    data object Done : ReviewResult

    /** Restoring needs an empty composer; a newer draft is never overwritten. */
    data object ComposerNotEmpty : ReviewResult
    data object NotFound : ReviewResult
    data class Failed(val error: ChatError) : ReviewResult
}

sealed interface StopResult {
    /** `status:"interrupted"` came back; the turn ends when `session.info running:false` arrives. */
    data object Requested : StopResult
    data class Refused(val error: ChatError) : StopResult
    data class Uncertain(val error: ChatError) : StopResult
}

sealed interface DraftResult {
    data object Saved : DraftResult
    data class NotSaved(val error: ChatError) : DraftResult
}

enum class ReviewDecision {
    /** Delete the retained entry after the person reviewed it. Does not send anything. */
    Discard,

    /** Put the entry's original text into the composer (only if the composer is empty) and delete the entry. */
    RestoreToComposer,
}

// ---- Prompts ------------------------------------------------------------------------------------------------------

enum class ApprovalChoice(val wire: String) {
    Once("once"), Session("session"), Always("always"), Deny("deny");

    companion object {
        fun fromWire(value: String): ApprovalChoice? = entries.firstOrNull { it.wire == value }
    }
}

class ClarifyQuestion(val id: String, val question: String, val choices: List<String>, val multiSelect: Boolean, val lockedAnswer: String?)

enum class SecureKind { Secret, Sudo, VaultCode, VaultSaveLogin, VaultUnlock }

enum class PromptStatus { Pending, Answering }

sealed interface PromptContent {
    class Approval(val command: String?, val description: String?, val toolName: String?, val choices: List<ApprovalChoice>) : PromptContent

    class Clarification(val questions: List<ClarifyQuestion>, val isBatch: Boolean) : PromptContent

    /** A request for a secret, password or code. Its value is never held by the repository beyond the one response. */
    class SecureInput(
        val kind: SecureKind,
        val envVar: String?,
        val prompt: String?,
        val label: String?,
        val site: String?,
        val backendName: String?,
        val isAgentRequest: Boolean,
    ) : PromptContent
}

/**
 * One actionable question from the agent, bound to the exact socket, runtime, profile and conversation it
 * arrived for. [id] is the repository's own identity for it. [wireId] is the host's opaque JSON-RPC ID (echoed
 * untouched in the response) and is deliberately separate from [domainRequestId] (an approval's `request_id`).
 */
class PromptState(
    val id: String,
    val ref: ConversationRef,
    val wireId: String,
    val method: String,
    val domainRequestId: String?,
    val createdAtMillis: Long,
    val content: PromptContent,
    val status: PromptStatus = PromptStatus.Pending,
) {
    override fun toString() = "PromptState($method)"
}

sealed interface PromptAnswer {
    data class Approve(val choice: ApprovalChoice) : PromptAnswer

    /** Answers by question ID; a single question uses its own ID (see [ClarifyQuestion.id]). */
    data class Clarify(val answers: Map<String, String>) : PromptAnswer

    /** A secret, password, code or unlock value. The array is cleared by the repository after the one response. */
    class Secure(val value: CharArray) : PromptAnswer {
        override fun toString() = "Secure(value hidden)"
    }

    class SaveLogin(val identifier: String, val password: CharArray) : PromptAnswer {
        override fun toString() = "SaveLogin(hidden)"
    }
}

sealed interface PromptResult {
    /** The response was handed to the connection. A lost socket afterwards is not reported here and is never replayed. */
    data object Answered : PromptResult

    /** The prompt is no longer active (cancelled, expired, or its socket ended). Nothing was sent. */
    data object NoLongerActive : PromptResult

    /** The answer is not valid for this prompt (an unoffered choice, an oversize or empty value). Nothing was sent; it can be corrected. */
    data class Invalid(val reason: String) : PromptResult
}

// ---- History ----------------------------------------------------------------------------------------------------------

sealed interface HistoryLoad {
    data class Loaded(val addedRows: Int, val hasOlder: Boolean) : HistoryLoad
    data object NothingOlder : HistoryLoad
    data class Failed(val error: ChatError) : HistoryLoad
}

// ---- Configuration -----------------------------------------------------------------------------------------------------

/** Tunables with the contract's values; tests shorten the waits. */
class ChatConfig(
    /** Newest-page size, in turns (1–10). */
    val turnLimit: Int = 5,
    val clock: () -> Long = System::currentTimeMillis,
    val random: () -> String = { java.util.UUID.randomUUID().toString() },
) {
    init { require(turnLimit in 1..10) { "turnLimit is 1 to 10" } }
}

// ---- Runtime controls -----------------------------------------------------------------------------------------------

class ModelProvider(val id: String, val name: String, val isCurrent: Boolean, val isCustom: Boolean, val models: List<String>, val fastModels: Set<String>?)

/** The live session's own model and reasoning, read back from the runtime, and the host's catalog of choices. */
class ModelOptions(
    val model: String,
    val provider: String?,
    /** Empty means the host's Auto. */
    val reasoningEffort: String,
    /** The raw `service_tier`; [isFast] reads the known spellings and is null for a mode this client does not know. */
    val serviceTier: String?,
    val running: Boolean,
    val providers: List<ModelProvider>,
) {
    val isFast: Boolean? get() = when (serviceTier?.lowercase()) {
        "fast", "on", "priority" -> true
        null, "", "normal", "off" -> false
        else -> null
    }
}

sealed interface ModelChange {
    /** Read back from the live session: it runs on [model] now. */
    data class Confirmed(val model: String, val provider: String?) : ModelChange

    /** The host wants an explicit yes first; call again with `confirmed = true`. Nothing changed. */
    data class NeedsConfirmation(val message: String) : ModelChange

    /** The host queued it for the next turn. The current model is NOT confirmed changed; reopen the picker to check. */
    data class Deferred(val message: String) : ModelChange
}

sealed interface BotChatOutcome {
    /** The agent's canonical Bot Chat, resolved by the registry and opened. */
    data class Opened(val ref: ConversationRef) : BotChatOutcome

    /** The registry names no Bot Chat for this agent and creating one was not asked for. Nothing was created. */
    data object NotCreated : BotChatOutcome

    /** The first Bot Chat was started and its title or registry step is not confirmed. Retried by its own recovery, never by a new chat. */
    data class Unconfirmed(val intentId: String, val error: ChatError) : BotChatOutcome
    data class Failed(val error: ChatError) : BotChatOutcome
}
