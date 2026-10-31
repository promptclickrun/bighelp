package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.RequestCancelledException
import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Model, reasoning, speed and approval-skipping for one live session. Every change is session-scoped (it names the
 * runtime, `--session` or `scope:"session"`), so it can never rewrite the agent's profile defaults, and every
 * result is read back from the runtime before it is reported as changed.
 */
internal class RuntimeControls(private val ctx: ChatContext, private val engine: ConversationEngine) {
    private class Proof(val model: String, val provider: String, val reasoning: String, val tier: String?, val running: Boolean)

    private suspend fun live(ref: ConversationRef): Pair<ConversationRuntime, Binding> = ctx.onState {
        val rt = engine.conversations[ref] ?: throw ChatException(ChatError.Kind.NotOpen)
        val binding = rt.binding
        if (binding == null || rt.requiresReattach || binding.generation != ctx.gateway.state.value.generation) throw ChatException(ChatError.Kind.NoLiveSession)
        rt to binding
    }

    private fun stale(rt: ConversationRuntime, binding: Binding) {
        if (engine.conversations[rt.ref] !== rt || rt.binding != binding || ctx.gateway.state.value.generation != binding.generation) throw ChatException(ChatError.Kind.NotConnected)
    }

    private suspend fun <T> mapErrors(block: suspend () -> T): T = try {
        block()
    } catch (e: HermesException) {
        throw ChatException(if (e.outcomeUnknown) ChatError(ChatError.Kind.OutcomeUnknown, e.kind, e.code, e.reason) else SessionBinder.chatError(e))
    } catch (e: RequestCancelledException) {
        throw ChatException(ChatError.Kind.OutcomeUnknown)
    }

    /** The live runtime's own model, provider and reasoning, read through activation (which never builds or creates a runtime). */
    private suspend fun proof(rt: ConversationRuntime, binding: Binding): Proof {
        val response = ctx.gateway.request("session.activate", buildJsonObject {
            put("session_id", binding.runtimeId); put("profile", binding.profile); put("omit_messages", true)
        }, generation = binding.generation).asObject ?: throw invalidResponse()
        val info = response["info"].asObject
        val stored = response["session_key"].asString
        if (response["session_id"].asString != binding.runtimeId || stored == null || !rt.identity.knows(stored) ||
            response["messages_omitted"].asBool != true || response["messages"].asArray?.isEmpty() != true ||
            response["running"].asBool == null || info == null || info["profile_name"].asString != binding.profile ||
            info["stored_session_id"].asString != stored
        ) throw ChatException(ChatError.Kind.Unsupported)
        val model = info["model"].asString?.takeIf { Coordinates.isValid(it, 256) } ?: throw ChatException(ChatError.Kind.Unsupported)
        // A chat whose agent is not built yet (lazy) reports its model but may omit provider and reasoning.
        val built = info["lazy"] == null || info["lazy"].asBool == false
        val provider = info["provider"].asString ?: if (built) throw ChatException(ChatError.Kind.Unsupported) else ""
        val reasoning = info["reasoning_effort"].asString ?: if (built) throw ChatException(ChatError.Kind.Unsupported) else ""
        if (reasoning.isNotEmpty() && reasoning !in REASONING) throw invalidResponse()
        return Proof(model, provider, reasoning, info["service_tier"].asString, response["running"].asBool == true)
    }

    // ---- reading

    suspend fun options(ref: ConversationRef): ModelOptions = mapErrors {
        val (rt, binding) = live(ref)
        val current = proof(rt, binding)
        val catalog = ctx.gateway.request("model.options", buildJsonObject { put("profile", binding.profile); put("session_id", binding.runtimeId) }, generation = binding.generation)
        ctx.onState { stale(rt, binding) }
        ModelOptions(current.model, current.provider.ifEmpty { null }, current.reasoning, current.tier, current.running, decodeProviders(catalog))
    }

    private fun decodeProviders(response: JsonElement): List<ModelProvider> {
        val rows = response.asObject?.get("providers").asArray ?: throw invalidResponse()
        val seen = HashSet<String>()
        return rows.mapNotNull { value ->
            val row = value.asObject ?: return@mapNotNull null
            val id = row["slug"].asString?.takeIf { Coordinates.isValid(it, 128) && seen.add(it) } ?: return@mapNotNull null
            val modelSeen = HashSet<String>()
            val models = (row["models"].asArray ?: JsonArray(emptyList())).mapNotNull { it.asString?.takeIf { m -> Coordinates.isValid(m, 256) && modelSeen.add(m) } }
            val unavailable = (row["unavailable_models"].asArray ?: JsonArray(emptyList())).mapNotNull { it.asString }.toSet()
            val capabilities = row["capabilities"].asObject
            ModelProvider(
                id, row["name"].asString?.takeIf { it.isNotEmpty() && utf8Length(it) <= 800 } ?: id, row["is_current"].asBool ?: false,
                row["is_user_defined"].asBool ?: false, models.filter { it !in unavailable },
                capabilities?.let { c -> models.filter { c[it].asObject?.get("fast").asBool == true }.toSet() },
            )
        }
    }

    // ---- changing

    suspend fun setModel(ref: ConversationRef, model: String, provider: String, confirmed: Boolean): ModelChange = mapErrors {
        if (!Coordinates.isValid(model, 256) || !Coordinates.isValid(provider, 128)) throw ChatException(ChatError.Kind.InvalidInput)
        val (rt, binding) = live(ref)
        val before = proof(rt, binding)
        ctx.onState { stale(rt, binding) }
        if (before.model == model && before.provider == provider) return@mapErrors ModelChange.Confirmed(model, provider)
        val response = ctx.gateway.request("config.set", buildJsonObject {
            put("profile", binding.profile); put("session_id", binding.runtimeId)
            put("key", "model"); put("value", "$model --provider $provider --session")
            if (confirmed) put("confirm_expensive_model", true)
        }, generation = binding.generation).asObject ?: throw invalidResponse()
        ctx.onState { stale(rt, binding) }
        val needsConfirmation = response["confirm_required"].asBool
        if (response["key"].asString != "model" || response["scope"].asString != "session" || needsConfirmation == null || response?.get("value").asString == null) throw invalidResponse()
        if (needsConfirmation) {
            val message = response["confirm_message"].asString?.takeIf { !confirmed && it.isNotBlank() && utf8Length(it) <= 2_000 } ?: throw invalidResponse()
            return@mapErrors ModelChange.NeedsConfirmation(message)
        }
        response["deferred"]?.let { deferred ->
            if (deferred.asBool == null) throw invalidResponse()
            if (deferred.asBool == true) {
                return@mapErrors ModelChange.Deferred("Hermes queued this model for the next turn. The current model has not been confirmed changed; reopen the picker to check.")
            }
        }
        // A model switch must not change how hard the session thinks: put the previous level back and read it back.
        if (before.reasoning.isNotEmpty()) writeReasoning(binding, before.reasoning, rt)
        val after = proof(rt, binding)
        ctx.onState { stale(rt, binding) }
        if (after.model != model || (after.provider != provider && !catalogMarksCurrent(binding, provider, model))) throw ChatException(ChatError.Kind.ModelNotConfirmed)
        ctx.onState { rt.runtimeInfo = rt.runtimeInfo.merged(RuntimeInfo(model = after.model, provider = after.provider.ifEmpty { null }, reasoningEffort = after.reasoning, serviceTier = after.tier)); engine.publish(rt) }
        ModelChange.Confirmed(after.model, after.provider.ifEmpty { null })
    }

    /** A catalog can list a provider under an alias slug while the runtime reports its canonical ID; a fresh read must mark the chosen slug current. */
    private suspend fun catalogMarksCurrent(binding: Binding, provider: String, model: String): Boolean {
        val response = ctx.gateway.request("model.options", buildJsonObject { put("profile", binding.profile); put("session_id", binding.runtimeId) }, generation = binding.generation)
        if (response.asObject?.get("model").asString != model) return false
        val current = decodeProviders(response).filter { it.isCurrent }
        return current.size == 1 && current[0].id == provider
    }

    suspend fun setReasoning(ref: ConversationRef, level: String): Unit = mapErrors {
        if (level !in REASONING) throw ChatException(ChatError.Kind.InvalidInput)
        val (rt, binding) = live(ref)
        // Reattach the exact runtime right before config.set: a missing session would target the profile defaults.
        proof(rt, binding)
        ctx.onState { stale(rt, binding) }
        writeReasoning(binding, level, rt)
        ctx.onState { rt.runtimeInfo = rt.runtimeInfo.merged(RuntimeInfo(reasoningEffort = level)); engine.publish(rt) }
    }

    private suspend fun writeReasoning(binding: Binding, level: String, rt: ConversationRuntime) {
        val set = ctx.gateway.request("config.set", buildJsonObject {
            put("profile", binding.profile); put("session_id", binding.runtimeId); put("key", "reasoning"); put("value", level); put("scope", "session")
        }, generation = binding.generation).asObject
        ctx.onState { stale(rt, binding) }
        if (set?.get("key").asString != "reasoning" || set?.get("value").asString != level) throw ChatException(ChatError.Kind.OutcomeUnknown)
        val read = ctx.gateway.request("config.get", buildJsonObject { put("profile", binding.profile); put("session_id", binding.runtimeId); put("key", "reasoning") }, generation = binding.generation).asObject
        ctx.onState { stale(rt, binding) }
        if (read?.get("value").asString != level) throw ChatException(ChatError.Kind.OutcomeUnknown)
    }

    /** Fast mode: only on an idle runtime, and only when the host's catalog says the current model supports it. */
    suspend fun setFast(ref: ConversationRef, on: Boolean): Unit = mapErrors {
        val (rt, binding) = live(ref)
        val before = proof(rt, binding)
        if (before.running) throw ChatException(ChatError.Kind.Conflict)
        val catalog = decodeProviders(ctx.gateway.request("model.options", buildJsonObject { put("profile", binding.profile); put("session_id", binding.runtimeId) }, generation = binding.generation))
        val supported = catalog.firstOrNull { it.id == before.provider }?.fastModels?.contains(before.model) == true
        if (!supported) throw ChatException(ChatError.Kind.Unsupported)
        ctx.onState { stale(rt, binding) }
        val value = if (on) "fast" else "normal"
        val set = ctx.gateway.request("config.set", buildJsonObject {
            put("profile", binding.profile); put("session_id", binding.runtimeId); put("key", "fast"); put("value", value); put("scope", "session")
        }, generation = binding.generation).asObject
        if (set?.get("key").asString != "fast" || tierIsFast(set?.get("value").asString) != on) throw ChatException(ChatError.Kind.OutcomeUnknown)
        val read = ctx.gateway.request("config.get", buildJsonObject { put("profile", binding.profile); put("session_id", binding.runtimeId); put("key", "fast") }, generation = binding.generation).asObject
        ctx.onState { stale(rt, binding) }
        if (tierIsFast(read?.get("value").asString) != on) throw ChatException(ChatError.Kind.OutcomeUnknown)
        ctx.onState { rt.runtimeInfo = rt.runtimeInfo.merged(RuntimeInfo(serviceTier = value)); engine.publish(rt) }
    }

    private fun tierIsFast(raw: String?): Boolean? = when (raw?.lowercase()) {
        "fast", "on", "priority" -> true
        null, "", "normal", "off" -> false
        else -> null
    }

    /** Session-scoped YOLO. The host answers `"1"`/`"0"`, which is the confirmation; there is no separate read. */
    suspend fun setYolo(ref: ConversationRef, on: Boolean): Unit = mapErrors {
        val (rt, binding) = live(ref)
        val response = ctx.gateway.request("config.set", buildJsonObject {
            put("profile", binding.profile); put("session_id", binding.runtimeId); put("key", "yolo"); put("value", if (on) "on" else "off"); put("scope", "session")
        }, generation = binding.generation).asObject
        ctx.onState { stale(rt, binding) }
        if (response?.get("key").asString != "yolo" || response?.get("value").asString != (if (on) "1" else "0")) throw ChatException(ChatError.Kind.OutcomeUnknown)
    }

    // ---- commands

    suspend fun commands(ref: ConversationRef): List<SlashCommand> = mapErrors {
        val (_, binding) = live(ref)
        SlashCommandCatalog.decode(ctx.gateway.request("commands.catalog", buildJsonObject { put("session_id", binding.runtimeId); put("profile", binding.profile) }, generation = binding.generation))
    }

    /** The commands a new chat would have, before it exists (Code mode's `/` list). Bound to the profile, and to a folder for project-local skills. */
    suspend fun commandsForNewChat(profile: String, cwd: String?): List<SlashCommand> = mapErrors {
        if (!Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) throw ChatException(ChatError.Kind.InvalidInput)
        SlashCommandCatalog.decode(ctx.gateway.request("commands.catalog", buildJsonObject {
            put("profile", profile); if (!cwd.isNullOrEmpty() && utf8Length(cwd) <= 4_096) put("cwd", cwd)
        }))
    }

    companion object {
        val REASONING = setOf("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")
    }
}
