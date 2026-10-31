package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.RequestCancelledException
import app.bighelp.hermes.DispatchOutcome
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The coordinates a create or resume answer proved, ready to become a [Binding]. [generation] is the socket the
 * request was fenced to: the runtime ID belongs to that socket and to no later one (null: not from a request).
 */
internal data class Attached(
    val runtimeId: String, val storedId: String, val running: Boolean?, val info: JsonObject, val model: String?, val cwd: String?,
    val generation: Long? = null,
)

/**
 * The create intents of this computer, one per profile, written before `session.create` leaves and updated as
 * coordinates arrive. A finished or definitely-refused intent is deleted; an intent whose outcome is unknown stays
 * so the same logical create can be retried under the same key, also after a restart.
 */
internal class CreationBook(private val ctx: ChatContext) {
    private val records: MutableMap<String, CreationRecord> = java.util.Collections.synchronizedMap(LinkedHashMap())
    private val inFlight: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    suspend fun load() {
        val keys = ctx.store.keys(ctx.host, RecordKind.Creation)
        val loaded = keys.mapNotNull { key ->
            val bytes = ctx.store.read(key) ?: return@mapNotNull null
            runCatching { CreationRecord.decode(ctx.host, key.profile!!, bytes) }.getOrNull()
        }
        loaded.forEach { records[it.profile] = it }
    }

    fun pending(): List<PendingCreation> =
        records.values.toList().filter { !it.isFinished }.map { PendingCreation(it.profile, it.intentId, it.purpose, it.phase, it.request) }

    fun record(profile: String): CreationRecord? = records[profile]

    /** Claims the profile for one create at a time. */
    fun begin(profile: String): Boolean = inFlight.add(profile)
    fun end(profile: String) { inFlight.remove(profile) }

    /** Persists first, then remembers: a failed write leaves the book as it was and nothing may be dispatched. */
    suspend fun save(record: CreationRecord) {
        ctx.store.commit(listOf(StoreOp.Put(RecordKey.creation(ctx.host, record.profile), record.encode())))
        records[record.profile] = record
    }

    suspend fun remove(profile: String) {
        try {
            ctx.store.commit(listOf(StoreOp.Delete(RecordKey.creation(ctx.host, profile))))
        } catch (e: CancellationException) {
            // The record stays where it is, in memory and on disk alike; a caller that needs it gone finishes this uncancellably.
            throw e
        } catch (_: Exception) {
            // A failed delete leaves a stale intent that the next create reconciles; the in-memory book still lets go.
        }
        records.remove(profile)
    }
}

/** Create, resume and the Bot Chat registry: every call that makes a conversation reachable. */
internal class SessionBinder(private val ctx: ChatContext, val creations: CreationBook) {
    /** Resolved by `profiles.list`; kept so a refresh cannot lose the registry's Bot Chat. */
    val canonical: MutableMap<String, CanonicalChat> = java.util.concurrent.ConcurrentHashMap()
    private val titleTaken: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    // ---- resume

    /**
     * `session.resume` of a stored ID (never the runtime ID), with the app's source. A rejected optional field is retried once without it.
     * The call is fenced to [generation] (default: the socket as it is now), so a runtime is never made on a socket the caller did not plan for.
     */
    suspend fun resume(profile: String, storedId: String, generation: Long? = null): Attached {
        val fence = generation ?: ctx.gateway.state.value.generation
        val base = buildJsonObject {
            put("session_id", storedId); put("profile", profile); put("source", SOURCE)
            put("defer_history", true); put("omit_messages", true)
        }
        val withLifetime = JsonObject(base + ("close_on_disconnect" to kotlinx.serialization.json.JsonPrimitive(false)))
        val result = try {
            ctx.gateway.request("session.resume", withLifetime, generation = fence)
        } catch (e: HermesException) {
            // An older host refuses a field it does not know before doing anything; the plain resume is the same request.
            if (e.kind == HermesException.Kind.RpcRejected && e.code == 4000L) ctx.gateway.request("session.resume", base, generation = fence) else throw e
        }
        return decodeAttached(result, profile, requireStoredAlias = false).copy(generation = fence)
    }

    /** `session.activate` of an already proved runtime: attaches and touches it, never builds or creates one. */
    suspend fun activate(profile: String, runtimeId: String, generation: Long): JsonObject {
        val result = ctx.gateway.request("session.activate", buildJsonObject {
            put("session_id", runtimeId); put("profile", profile); put("omit_messages", true)
        }, generation = generation)
        return result.asObject ?: throw invalidResponse()
    }

    // ---- ordinary create

    /**
     * One `session.create`. The intent is persisted first; a retry of the same logical create passes its [retryIntent]
     * and sends the same key. An outcome that cannot be told keeps the intent; a definite refusal drops it.
     */
    suspend fun createOrdinary(profile: String, request: CreateRequest, retryIntent: String?): CreateStep {
        if (!creations.begin(profile)) return CreateStep.Failed(ChatError(ChatError.Kind.CreationInProgress))
        try {
            reconcileCanonicalBeforeOrdinary(profile)
            val previous = creations.record(profile)
            val reused = previous?.takeIf { it.purpose == CreationPurpose.Ordinary && !it.isFinished && it.intentId == retryIntent }
            val record = reused ?: CreationRecord(
                ctx.host, ctx.config.random().lowercase(), profile, CreationPurpose.Ordinary, CreationPhase.CreateRequested, request,
                socketGeneration = ctx.gateway.state.value.generation, createdAtMillis = ctx.config.clock(),
            )
            try {
                creations.save(record)
            } catch (e: ChatStoreException) {
                return CreateStep.Failed(ChatError(ChatError.Kind.PersistenceFailed))
            }
            return dispatchCreate(record)
        } finally {
            creations.end(profile)
        }
    }

    /** Sends the create under [record]'s key and proves what came back. */
    private suspend fun dispatchCreate(record: CreationRecord): CreateStep {
        // The socket this create is planned on: the answer's runtime ID belongs to it and to no later socket.
        val generation = ctx.gateway.state.value.generation
        var sendExplicitCwd = record.request.cwd != null
        var answer: JsonElement? = null
        while (answer == null) {
            try {
                answer = ctx.gateway.request("session.create", createParams(record, sendExplicitCwd), generation = generation)
            } catch (e: HermesException) {
                // Only an explicit rejection of cwd_explicit authorizes a retry without it: a timeout or lost reply does not.
                if (sendExplicitCwd && e.kind == HermesException.Kind.RpcRejected && e.code == 4000L) { sendExplicitCwd = false; continue }
                return afterFailedCreate(record, e.outcomeUnknown, chatError(e))
            } catch (e: RequestCancelledException) {
                // The caller is gone, but how far the frame got still decides the intent: kept for a retry when it may have
                // reached the host, dropped (on disk too) when it did not. That finishes first; then the cancellation goes on.
                try {
                    withContext(NonCancellable) { afterFailedCreate(record, e.dispatch == DispatchOutcome.MayHaveBeenSent, ChatError(ChatError.Kind.Cancelled)) }
                } catch (_: CancellationException) {
                    // The settlement above ran to completion; the caller's own cancellation is rethrown below.
                }
                throw e
            }
        }
        val attached = try {
            decodeAttached(answer, record.profile, requireStoredAlias = true, requireEmpty = true).copy(generation = generation)
        } catch (e: HermesException) {
            // The host answered something unusable: whether it created a chat is unknown. Keep the intent.
            return CreateStep.Unconfirmed(record.intentId, ChatError(ChatError.Kind.InvalidResponse))
        }
        record.request.model?.let { chosen ->
            if (attached.model != chosen) {
                creations.remove(record.profile)
                return CreateStep.Failed(ChatError(ChatError.Kind.ModelNotConfirmed))
            }
        }
        record.request.cwd?.let { requested ->
            if (attached.cwd?.let { sameFolder(it, requested) } != true) {
                creations.remove(record.profile)
                return CreateStep.Failed(ChatError(ChatError.Kind.WorkspaceNotConfirmed))
            }
        }
        val created = record.copy(phase = CreationPhase.Created, storedSessionId = attached.storedId, runtimeSessionId = attached.runtimeId)
        try {
            creations.save(created)
        } catch (e: ChatStoreException) {
            // The chat exists but its coordinates cannot be kept: no further mutation. The intent stays at its old phase, so a retry returns it.
            return CreateStep.Failed(ChatError(ChatError.Kind.PersistenceFailed))
        }
        return CreateStep.Created(created, attached)
    }

    private suspend fun afterFailedCreate(record: CreationRecord, unknown: Boolean, error: ChatError): CreateStep {
        if (unknown) return CreateStep.Unconfirmed(record.intentId, ChatError(ChatError.Kind.CreationUnconfirmed, error.cause, error.code, error.reason))
        // Definitely not created: nothing to retry under this key.
        creations.remove(record.profile)
        return CreateStep.Failed(error)
    }

    private fun createParams(record: CreationRecord, explicitCwd: Boolean): JsonObject = buildJsonObject {
        put("profile", record.profile); put("source", SOURCE)
        // One key per logical create: a retry after a lost reply gets the same session while the host still has it.
        put("idempotency_key", record.intentId.lowercase())
        val r = record.request
        r.title?.let { put("title", it) }
        r.model?.let { put("model", it); r.provider?.let { p -> put("provider", p) } }
        r.reasoningEffort?.let { put("reasoning_effort", it) }
        r.fast?.let { put("fast", it) }
        if (record.purpose == CreationPurpose.FirstCanonical) {
            put("title", "Bot Chat"); put("hidden", true); put("follow_profile_config", true)
        }
        r.cwd?.let { put("cwd", it); if (explicitCwd) put("cwd_explicit", true) }
    }

    // ---- registry and the first Bot Chat

    /** A canonical chat is resolved by the registry, never by whichever chat was last active. */
    suspend fun registry(profile: String): CanonicalChat? {
        val rows = CatalogDecoder.profiles(ctx.gateway.request("profiles.list", buildJsonObject { put("include_sessions", true) }))
        rows.forEach { row -> row.canonicalChat?.let { canonical[row.id] = it } }
        return rows.firstOrNull { it.id == profile }?.canonicalChat
    }

    /**
     * An unfinished first Bot Chat that reached its title or registry steps is settled by the registry before an
     * ordinary create: the registry has the chat, or the title never landed. Either way a new chat is safe, so
     * one lost reply never locks an agent out of every independent chat.
     */
    private suspend fun reconcileCanonicalBeforeOrdinary(profile: String) {
        val pending = creations.record(profile) ?: return
        if (pending.purpose != CreationPurpose.FirstCanonical || pending.isFinished) return
        if (pending.phase != CreationPhase.TitleRequested && pending.phase != CreationPhase.AwaitingRegistry) return
        val found = runCatching { registry(profile) }.getOrNull()
        runCatching {
            creations.save(
                if (found != null) pending.copy(phase = CreationPhase.CanonicalResolved, canonicalRegistryId = found.id)
                else pending.copy(phase = CreationPhase.Complete),
            )
        }
    }

    /**
     * Creates the agent's first canonical Bot Chat after an explicit decision: hidden, titled `Bot Chat`, read back
     * from the registry. A conflict winner is adopted from the registry. Returns the registry chat to open.
     */
    suspend fun createFirstBotChat(profile: String): BotChatStep {
        if (profile in titleTaken) return BotChatStep.Failed(ChatError(ChatError.Kind.Rejected, HermesException.Kind.RpcRejected, 4022))
        if (!creations.begin(profile)) return BotChatStep.Failed(ChatError(ChatError.Kind.CreationInProgress))
        try {
            registry(profile)?.let { found ->
                creations.record(profile)?.takeIf { it.purpose == CreationPurpose.FirstCanonical && !it.isFinished }?.let { runCatching { creations.save(it.copy(phase = CreationPhase.CanonicalResolved, canonicalRegistryId = found.id)) } }
                return BotChatStep.Registered(found)
            }
            var record = creations.record(profile)?.takeIf { it.purpose == CreationPurpose.FirstCanonical && !it.isFinished }
            var attached: Attached? = null
            when {
                // The reply was lost before any coordinate: create again under the same key. The host returns the same
                // session while it still has it, else makes a fresh one. Never a permanent refusal.
                record != null && record.storedSessionId == null -> when (val step = dispatchCreate(record)) {
                    is CreateStep.Created -> { record = step.record; attached = step.attached }
                    is CreateStep.Unconfirmed -> return BotChatStep.Unconfirmed(step.intentId, step.error)
                    is CreateStep.Failed -> return BotChatStep.Failed(step.error)
                }
                // The host made its session: resume it and finish from there.
                record != null -> attached = try { resume(profile, record.storedSessionId!!) } catch (e: HermesException) { return BotChatStep.Failed(chatError(e)) }
                else -> {
                    val fresh = CreationRecord(
                        ctx.host, ctx.config.random().lowercase(), profile, CreationPurpose.FirstCanonical, CreationPhase.CreateRequested,
                        CreateRequest(), socketGeneration = ctx.gateway.state.value.generation, createdAtMillis = ctx.config.clock(),
                    )
                    try { creations.save(fresh) } catch (e: ChatStoreException) { return BotChatStep.Failed(ChatError(ChatError.Kind.PersistenceFailed)) }
                    when (val step = dispatchCreate(fresh)) {
                        is CreateStep.Created -> { record = step.record; attached = step.attached }
                        is CreateStep.Unconfirmed -> return BotChatStep.Unconfirmed(step.intentId, step.error)
                        is CreateStep.Failed -> return BotChatStep.Failed(step.error)
                    }
                }
            }
            val titling = record!!.copy(phase = CreationPhase.TitleRequested, storedSessionId = attached!!.storedId, runtimeSessionId = attached.runtimeId)
            try { creations.save(titling) } catch (e: ChatStoreException) { return BotChatStep.Failed(ChatError(ChatError.Kind.PersistenceFailed)) }
            try {
                val reply = ctx.gateway.request("session.title", buildJsonObject { put("session_id", attached.runtimeId); put("title", "Bot Chat") }, generation = attached.generation).asObject
                if (reply?.get("pending").asBool != false || reply?.get("title").asString != "Bot Chat") {
                    return BotChatStep.Unconfirmed(record.intentId, ChatError(ChatError.Kind.CreationUnconfirmed))
                }
            } catch (e: HermesException) {
                if (e.kind == HermesException.Kind.RpcRejected && e.code == 4022L) return titleConflict(profile, attached, titling)
                return BotChatStep.Unconfirmed(record.intentId, ChatError(ChatError.Kind.CreationUnconfirmed, e.kind, e.code, e.reason))
            }
            try { creations.save(titling.copy(phase = CreationPhase.AwaitingRegistry)) } catch (e: ChatStoreException) { return BotChatStep.Failed(ChatError(ChatError.Kind.PersistenceFailed)) }
            val registered = registry(profile) ?: return BotChatStep.Unconfirmed(record.intentId, ChatError(ChatError.Kind.CreationUnconfirmed))
            creations.remove(profile)
            return BotChatStep.Registered(registered)
        } catch (e: HermesException) {
            return BotChatStep.Failed(chatError(e))
        } finally {
            creations.end(profile)
        }
    }

    /** 4022: another chat holds the title. The registry's winner is adopted; our empty chat is dropped. */
    private suspend fun titleConflict(profile: String, mine: Attached, record: CreationRecord): BotChatStep {
        val winner = registry(profile)
        runCatching { ctx.gateway.request("session.delete", buildJsonObject { put("session_id", mine.storedId); put("profile", profile) }) }
        if (winner != null) {
            creations.remove(profile)
            return BotChatStep.Registered(winner)
        }
        // A chat the list does not show holds the title, so this agent has no Bot Chat here. Settle the attempt.
        titleTaken += profile
        creations.remove(profile)
        return BotChatStep.Failed(ChatError(ChatError.Kind.Rejected, HermesException.Kind.RpcRejected, 4022))
    }

    // ---- decoding

    /** The identity needed to bind: a runtime ID, one agreeing stored alias, a profile echo, a Boolean `running`. */
    fun decodeAttached(result: JsonElement, profile: String, requireStoredAlias: Boolean, requireEmpty: Boolean = false): Attached {
        val body = result.asObject ?: throw invalidResponse()
        val runtime = body["session_id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
        val info = body["info"].asObject ?: throw invalidResponse()
        info["profile_name"]?.let { if (it.asString != profile) throw invalidResponse() }
        val aliases = listOf("session_key", "stored_session_id", "resumed").mapNotNull { key ->
            body[key]?.let { it.asString ?: throw invalidResponse() }
        }
        val stored = aliases.firstOrNull()?.takeIf { it.isNotEmpty() && utf8(it) <= 512 && Coordinates.isValid(it) } ?: throw invalidResponse()
        if (aliases.any { it != stored }) throw invalidResponse()
        info["stored_session_id"]?.let { if (it.asString != stored) throw invalidResponse() }
        if (requireStoredAlias && body["stored_session_id"].asString != stored) throw invalidResponse()
        val running = body["running"]?.let { it.asBool ?: throw invalidResponse() }
        if (requireEmpty && (body["message_count"].asInt != 0 || body["messages"].asArray?.isEmpty() != true)) throw invalidResponse()
        val model = info["model"].asString?.takeIf { info["lazy"].asBool != true || it.isNotEmpty() }
        return Attached(runtime, stored, running, info, model, info["cwd"].asString)
    }

    private fun utf8(text: String) = app.bighelp.hermes.utf8Length(text)

    companion object {
        const val SOURCE = "bighelp"

        /** Windows hosts answer `D:\x` for `D:/x` and ignore case; POSIX folders match byte for byte. */
        fun sameFolder(a: String, b: String): Boolean {
            if (a == b) return true
            fun windows(folder: String): String? =
                if (folder.startsWith("\\\\") || Regex("^[A-Za-z]:[\\\\/].*").matches(folder)) folder.replace('/', '\\').lowercase() else null
            val left = windows(a) ?: return false
            return left == windows(b)
        }

        fun chatError(e: HermesException): ChatError {
            val kind = when {
                e.code == -32601L -> ChatError.Kind.Unsupported
                e.kind == HermesException.Kind.NotConnected || e.kind == HermesException.Kind.Disconnected -> ChatError.Kind.NotConnected
                e.outcomeUnknown -> ChatError.Kind.OutcomeUnknown
                e.kind == HermesException.Kind.RpcRejected || e.kind == HermesException.Kind.ActiveSessionLimit -> ChatError.Kind.Rejected
                e.kind == HermesException.Kind.InvalidResponse -> ChatError.Kind.InvalidResponse
                e.kind == HermesException.Kind.MessageTooLarge -> ChatError.Kind.TooLarge
                e.kind == HermesException.Kind.InvalidCredentials || e.kind == HermesException.Kind.AuthenticationRequired ||
                    e.kind == HermesException.Kind.AuthModeChanged || e.kind == HermesException.Kind.IdentityChanged -> ChatError.Kind.SignInRequired
                else -> ChatError.Kind.HostUnavailable
            }
            return ChatError(kind, e.kind, e.code, e.reason)
        }
    }
}

internal sealed interface CreateStep {
    class Created(val record: CreationRecord, val attached: Attached) : CreateStep
    class Unconfirmed(val intentId: String, val error: ChatError) : CreateStep
    class Failed(val error: ChatError) : CreateStep
}

internal sealed interface BotChatStep {
    class Registered(val chat: CanonicalChat) : BotChatStep
    class Unconfirmed(val intentId: String, val error: ChatError) : BotChatStep
    class Failed(val error: ChatError) : BotChatStep
}
