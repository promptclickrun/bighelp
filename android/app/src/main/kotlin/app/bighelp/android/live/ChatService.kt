package app.bighelp.android.live

import app.bighelp.hermes.chat.BotChatOutcome
import app.bighelp.hermes.chat.CatalogState
import app.bighelp.hermes.chat.ConnectionStatus
import app.bighelp.hermes.chat.ConversationRef
import app.bighelp.hermes.chat.ConversationState
import app.bighelp.hermes.chat.CreateOutcome
import app.bighelp.hermes.chat.CreateRequest
import app.bighelp.hermes.chat.DraftResult
import app.bighelp.hermes.chat.HermesChatRepository
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
import kotlinx.coroutines.flow.StateFlow

/**
 * Exactly what the screens use of a computer's chat repository, so the live model's rules can be tested
 * without a socket. [RepositoryChatService] forwards every call; it adds no behavior.
 */
internal interface ChatService {
    val catalog: StateFlow<CatalogState>
    val conversations: StateFlow<Map<ConversationRef, ConversationState>>
    val pendingCreations: StateFlow<List<PendingCreation>>
    val connection: StateFlow<ConnectionStatus>

    suspend fun refreshCatalog(): CatalogState
    suspend fun archivedChats(): List<SessionSummary>
    suspend fun search(profile: String, query: String): List<SessionSearchResult>
    suspend fun createChat(profile: String, request: CreateRequest = CreateRequest(), retryIntent: String? = null): CreateOutcome
    suspend fun discardCreation(profile: String)
    suspend fun openBotChat(profile: String, createIfMissing: Boolean): BotChatOutcome
    suspend fun open(ref: ConversationRef): ConversationState
    suspend fun release(ref: ConversationRef)
    suspend fun updateDraft(ref: ConversationRef, text: String): DraftResult
    suspend fun send(ref: ConversationRef, text: String, mode: SendMode, selection: SlashSelection?): SendResult
    suspend fun stop(ref: ConversationRef): StopResult
    suspend fun resolveUnresolved(ref: ConversationRef, entryId: String, decision: ReviewDecision): ReviewResult
    suspend fun answerPrompt(promptId: String, answer: PromptAnswer): PromptResult
    suspend fun declinePrompt(promptId: String): PromptResult
    suspend fun loadOlder(ref: ConversationRef): HistoryLoad
    suspend fun reloadHistory(ref: ConversationRef)
    suspend fun rename(ref: ConversationRef, title: String)
    suspend fun archive(ref: ConversationRef)
    suspend fun restore(ref: ConversationRef)
    suspend fun delete(ref: ConversationRef)
    suspend fun fork(ref: ConversationRef, throughRowId: Long): ConversationRef
    suspend fun commands(ref: ConversationRef): SlashCommandIndex
    suspend fun commandsForNewChat(profile: String): SlashCommandIndex
    suspend fun modelOptions(ref: ConversationRef): ModelOptions
    suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean): ModelChange
    suspend fun setReasoning(ref: ConversationRef, level: String)
    suspend fun setFast(ref: ConversationRef, on: Boolean)
}

internal class RepositoryChatService(private val repository: HermesChatRepository) : ChatService {
    override val catalog get() = repository.catalog
    override val conversations get() = repository.conversations
    override val pendingCreations get() = repository.pendingCreations
    override val connection get() = repository.connection

    override suspend fun refreshCatalog() = repository.refreshCatalog()
    override suspend fun archivedChats() = repository.archivedChats()
    override suspend fun search(profile: String, query: String) = repository.search(profile, query)
    override suspend fun createChat(profile: String, request: CreateRequest, retryIntent: String?) = repository.createChat(profile, request, retryIntent)
    override suspend fun discardCreation(profile: String) = repository.discardCreation(profile)
    override suspend fun openBotChat(profile: String, createIfMissing: Boolean) = repository.openBotChat(profile, createIfMissing)
    override suspend fun open(ref: ConversationRef) = repository.open(ref)
    override suspend fun release(ref: ConversationRef) = repository.release(ref)
    override suspend fun updateDraft(ref: ConversationRef, text: String) = repository.updateDraft(ref, text)
    override suspend fun send(ref: ConversationRef, text: String, mode: SendMode, selection: SlashSelection?) =
        repository.send(ref, text, mode, selection = selection)
    override suspend fun stop(ref: ConversationRef) = repository.stop(ref)
    override suspend fun resolveUnresolved(ref: ConversationRef, entryId: String, decision: ReviewDecision) =
        repository.resolveUnresolved(ref, entryId, decision)
    override suspend fun answerPrompt(promptId: String, answer: PromptAnswer) = repository.answerPrompt(promptId, answer)
    override suspend fun declinePrompt(promptId: String) = repository.declinePrompt(promptId)
    override suspend fun loadOlder(ref: ConversationRef) = repository.loadOlder(ref)
    override suspend fun reloadHistory(ref: ConversationRef) = repository.reloadHistory(ref)
    override suspend fun rename(ref: ConversationRef, title: String) = repository.rename(ref, title)
    override suspend fun archive(ref: ConversationRef) = repository.archive(ref)
    override suspend fun restore(ref: ConversationRef) = repository.restore(ref)
    override suspend fun delete(ref: ConversationRef) = repository.delete(ref)
    override suspend fun fork(ref: ConversationRef, throughRowId: Long) = repository.fork(ref, throughRowId)
    override suspend fun commands(ref: ConversationRef) = repository.commands(ref)
    override suspend fun commandsForNewChat(profile: String) = repository.commandsForNewChat(profile)
    override suspend fun modelOptions(ref: ConversationRef) = repository.modelOptions(ref)
    override suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean) =
        repository.setModel(ref, model, provider, confirmed)
    override suspend fun setReasoning(ref: ConversationRef, level: String) = repository.setReasoning(ref, level)
    override suspend fun setFast(ref: ConversationRef, on: Boolean) = repository.setFast(ref, on)
}
