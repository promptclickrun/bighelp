package app.bighelp.hermes.chat

import app.bighelp.hermes.IncomingServerRequest
import app.bighelp.hermes.ServerResponse
import app.bighelp.hermes.utf8Length
import java.security.MessageDigest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The agent's questions: approvals, clarifications and the attended secure inputs. A request is actionable only
 * when it names a runtime this repository holds on the very socket it arrived on; anything malformed or unbound
 * is answered with an explicit error and never becomes a card. The handler suspends until a person answers or the
 * host cancels (the gateway cancels it on a matching `request.cancel` by ID and method, or when the socket ends).
 *
 * A secure value lives only in the caller's array and in the one response built from it: it is never put in a
 * transcript, draft, journal, cache, state object or log, and is cleared once used or retired.
 */
internal class PromptCenter(private val ctx: ChatContext, private val engine: ConversationEngine) {
    private class Entry(
        val id: String,
        val ref: ConversationRef,
        val wireId: String,
        val method: String,
        val domainRequestId: String?,
        val createdAt: Long,
        val content: PromptContent,
        val deferred: CompletableDeferred<ServerResponse>,
        var status: PromptStatus = PromptStatus.Pending,
    ) {
        fun state() = PromptState(id, ref, wireId, method, domainRequestId, createdAt, content, status)
    }

    private val entries = LinkedHashMap<String, Entry>()
    private val mutableStates = MutableStateFlow<List<PromptState>>(emptyList())
    val states: StateFlow<List<PromptState>> = mutableStates.asStateFlow()

    fun statesFor(ref: ConversationRef): List<PromptState> = entries.values.filter { it.ref == ref }.map { it.state() }

    private fun publish() {
        mutableStates.value = entries.values.sortedWith(compareBy({ it.createdAt }, { it.id })).map { it.state() }
        engine.conversations.values.forEach { engine.publish(it) }
    }

    /** The methods this client can really fulfil. Everything else is refused by the gateway with `-32601`. */
    val methods = listOf("approval", "clarify", "secret", "sudo", "vault.code", "vault.save_login", "vault.unlock_prompt")

    suspend fun handle(request: IncomingServerRequest): ServerResponse {
        val decoded = try {
            Decoder.decode(request.method, request.params)
        } catch (_: PromptInvalid) {
            return invalid
        }
        val entry = ctx.onState {
            val rt = engine.byRuntime(decoded.runtimeId, request.generation) ?: return@onState null
            if (request.generation != ctx.gateway.state.value.generation || entries.size >= MAXIMUM_OPEN) return@onState null
            val id = promptId(request.generation, request.method, request.id)
            if (entries.containsKey(id)) return@onState null
            Entry(id, rt.ref, request.id, request.method, decoded.domainRequestId, ctx.config.clock(), decoded.content, CompletableDeferred())
                .also { entries[id] = it; publish() }
        } ?: return invalid
        try {
            return entry.deferred.await()
        } finally {
            withContext(NonCancellable + ctx.serial) { if (entries.remove(entry.id) != null) publish() }
        }
    }

    /** The conversation's socket ended or its runtime was reclaimed: its prompts are no longer actionable. */
    fun retireFor(ref: ConversationRef) {
        val retired = entries.values.filter { it.ref == ref }
        if (retired.isEmpty()) return
        for (entry in retired) { entries.remove(entry.id); entry.deferred.complete(retiredResponse) }
        publish()
    }

    suspend fun answer(promptId: String, answer: PromptAnswer): PromptResult {
        val outcome = ctx.onState<Triple<Entry?, ServerResponse?, PromptResult>> {
            val entry = entries[promptId]
            if (entry == null || entry.status != PromptStatus.Pending) return@onState Triple(null, null, PromptResult.NoLongerActive)
            val response = try { Responder.respond(entry.content, answer) } catch (e: PromptInvalid) { return@onState Triple(null, null, PromptResult.Invalid(e.reason)) }
            entry.status = PromptStatus.Answering
            entries.remove(entry.id)
            publish()
            Triple(entry, response, PromptResult.Answered)
        }
        val (entry, response, result) = outcome
        if (entry != null && response != null) entry.deferred.complete(response)
        // Whatever the outcome, a secure value held by the caller is retired: it is never offered a second time.
        if (result !is PromptResult.Invalid) clear(answer)
        return result
    }

    suspend fun decline(promptId: String): PromptResult {
        val entry = ctx.onState { entries[promptId]?.takeIf { it.status == PromptStatus.Pending }?.also { entries.remove(it.id); publish() } }
            ?: return PromptResult.NoLongerActive
        entry.deferred.complete(Responder.decline(entry.content))
        return PromptResult.Answered
    }

    private fun clear(answer: PromptAnswer) {
        when (answer) {
            is PromptAnswer.Secure -> answer.value.fill('\u0000')
            is PromptAnswer.SaveLogin -> answer.password.fill('\u0000')
            else -> Unit
        }
    }

    private fun promptId(generation: Long, method: String, wireId: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest("$generation\u0000$method\u0000$wireId".toByteArray(Charsets.UTF_8))
        return "prompt-" + digest.take(12).joinToString("") { "%02x".format(it) }
    }

    // ---- decoding

    internal class PromptInvalid(val reason: String) : Exception(reason)
    private class Decoded(val runtimeId: String, val domainRequestId: String?, val content: PromptContent)

    private object Decoder {
        fun decode(method: String, p: JsonObject): Decoded {
            val runtime = p["session_id"].asString?.takeIf { it.isNotEmpty() && utf8Length(it) <= 4_096 } ?: throw PromptInvalid("session")
            return when (method) {
                "approval" -> approval(runtime, p)
                "clarify" -> clarify(runtime, p)
                else -> secure(method, runtime, p)
            }
        }

        private fun approval(runtime: String, p: JsonObject): Decoded {
            val requestId = p["request_id"].asString?.takeIf { it.isNotEmpty() && utf8Length(it) <= 4_096 } ?: throw PromptInvalid("request")
            val offered = p["choices"].asArray?.takeIf { it.isNotEmpty() && it.size <= 16 } ?: throw PromptInvalid("choices")
            // An unknown or repeated choice from a newer host is skipped, not fatal.
            val choices = LinkedHashSet<ApprovalChoice>()
            offered.forEach { v -> v.asString?.let(ApprovalChoice::fromWire)?.let(choices::add) }
            if (choices.isEmpty()) throw PromptInvalid("choices")
            fun optional(key: String, max: Int): String? = p[key]?.let { v -> v.asString?.takeIf { utf8Length(it) <= max && '\u0000' !in it } ?: throw PromptInvalid(key) }
            val command = optional("command", 65_536)
            val description = optional("description", 65_536)
            val tool = optional("tool_name", 4_096)
            optional("gateway_session_id", 4_096)
            for (key in listOf("allow_permanent", "allow_session", "smart_denied")) p[key]?.let { if (it.asBool == null) throw PromptInvalid(key) }
            return Decoded(runtime, requestId, PromptContent.Approval(command, description, tool, choices.toList()))
        }

        private fun clarify(runtime: String, p: JsonObject): Decoded {
            fun present(key: String) = p[key].let { it != null && it !is JsonNull }
            val single = present("question")
            if (single == present("questions")) throw PromptInvalid("shape")
            if (single) {
                if (present("answers")) throw PromptInvalid("answers")
                val question = p["question"].asString?.takeIf(::validQuestion) ?: throw PromptInvalid("question")
                val choices = choices(p["choices"])
                val multi = multi(p["multi_select"])
                if (multi && choices.isEmpty()) throw PromptInvalid("multi")
                return Decoded(runtime, null, PromptContent.Clarification(listOf(ClarifyQuestion(SINGLE, question, choices, multi, null)), isBatch = false))
            }
            val rows = p["questions"].asArray?.takeIf { it.isNotEmpty() && it.size <= 10 } ?: throw PromptInvalid("questions")
            val locked = locked(p["answers"])
            val ids = HashSet<String>()
            val questions = rows.map { row ->
                val o = row.asObject ?: throw PromptInvalid("question")
                val qid = o["qid"].asString?.takeIf { it.isNotEmpty() && utf8Length(it) <= 4_096 } ?: throw PromptInvalid("qid")
                if (!ids.add(qid)) throw PromptInvalid("qid")
                val question = o["question"].asString?.takeIf(::validQuestion) ?: throw PromptInvalid("question")
                val choices = choices(o["choices"])
                val multi = multi(o["multi_select"])
                if (multi && choices.isEmpty()) throw PromptInvalid("multi")
                ClarifyQuestion(qid, question, choices, multi, locked[qid])
            }
            if (!ids.containsAll(locked.keys)) throw PromptInvalid("answers")
            return Decoded(runtime, null, PromptContent.Clarification(questions, isBatch = true))
        }

        private fun choices(value: JsonElement?): List<String> {
            if (value == null || value is JsonNull) return emptyList()
            val rows = value.asArray?.takeIf { it.size <= 12 } ?: throw PromptInvalid("choices")
            val seen = HashSet<String>()
            return rows.map { c ->
                val s = c.asString?.takeIf { it.isNotEmpty() && utf8Length(it) <= 10_000 && '\u0000' !in it } ?: throw PromptInvalid("choice")
                if (!seen.add(s)) throw PromptInvalid("choice")
                s
            }
        }

        private fun multi(value: JsonElement?): Boolean = if (value == null || value is JsonNull) false else value.asBool ?: throw PromptInvalid("multi")

        private fun locked(value: JsonElement?): Map<String, String> {
            if (value == null) return emptyMap()
            val o = value.asObject?.takeIf { it.size <= 5 } ?: throw PromptInvalid("answers")
            return o.entries.associate { (key, v) ->
                if (key.isEmpty() || utf8Length(key) > 4_096) throw PromptInvalid("answers")
                key to (v.asString?.takeIf(::validAnswer) ?: throw PromptInvalid("answers"))
            }
        }

        private fun secure(method: String, runtime: String, p: JsonObject): Decoded {
            if (!identifier(runtime, 4_096)) throw PromptInvalid("session")
            val keys = p.keys
            val content = when (method) {
                "secret" -> {
                    if (!setOf("session_id", "env_var", "prompt", "metadata").containsAll(keys)) throw PromptInvalid("keys")
                    val env = p["env_var"].asString?.takeIf { identifier(it, 4_096) } ?: throw PromptInvalid("env")
                    val prompt = p["prompt"].asString?.takeIf { utf8Length(it) <= 65_536 && '\u0000' !in it } ?: throw PromptInvalid("prompt")
                    val meta = p["metadata"]?.let { if (it is JsonNull) null else it.asObject ?: throw PromptInvalid("metadata") }
                    val label = meta?.get("label").asString?.trim()?.takeIf { it.isNotEmpty() && utf8Length(it) <= 120 }
                    PromptContent.SecureInput(SecureKind.Secret, env, prompt, label, null, null, meta?.get("source").asString == "agent")
                }
                "sudo" -> {
                    if (keys != setOf("session_id")) throw PromptInvalid("keys")
                    PromptContent.SecureInput(SecureKind.Sudo, null, null, null, null, null, false)
                }
                "vault.code" -> {
                    if (!setOf("session_id", "site", "hint").containsAll(keys)) throw PromptInvalid("keys")
                    val site = label(p["site"], 255) ?: throw PromptInvalid("site")
                    val hint = label(p["hint"], 500) ?: throw PromptInvalid("hint")
                    PromptContent.SecureInput(SecureKind.VaultCode, null, hint.ifEmpty { null }, null, site.ifEmpty { null }, null, false)
                }
                "vault.save_login" -> {
                    if (keys != setOf("session_id", "origin", "site")) throw PromptInvalid("keys")
                    val origin = p["origin"].asString?.takeIf(::validOrigin) ?: throw PromptInvalid("origin")
                    label(p["site"], 255) ?: throw PromptInvalid("site")
                    // The origin, not the agent's label: people recognise addresses.
                    PromptContent.SecureInput(SecureKind.VaultSaveLogin, null, null, null, origin, null, false)
                }
                "vault.unlock_prompt" -> {
                    if (keys != setOf("session_id", "backend", "display_name")) throw PromptInvalid("keys")
                    val backend = p["backend"].asString?.takeIf { identifier(it, 64) } ?: throw PromptInvalid("backend")
                    val name = label(p["display_name"], 120) ?: throw PromptInvalid("display_name")
                    PromptContent.SecureInput(SecureKind.VaultUnlock, null, null, null, null, name.ifEmpty { backend }, false)
                }
                else -> throw PromptInvalid("method")
            }
            return Decoded(runtime, null, content)
        }

        private fun identifier(value: String, max: Int) = value.isNotEmpty() && utf8Length(value) <= max && value.none { it.code < 0x20 || it.code == 0x7f }

        /** A missing or null label is empty; a present one is bounded single-line text. */
        private fun label(value: JsonElement?, max: Int): String? {
            if (value == null || value is JsonNull) return ""
            val text = value.asString?.trim() ?: return null
            return text.takeIf { utf8Length(it) <= max && it.none { c -> c.code < 0x20 || c.code == 0x7f } }
        }

        private fun validOrigin(value: String): Boolean {
            if (utf8Length(value) > 2_048 || value.any { it.code < 0x21 || it.code == 0x7f }) return false
            val uri = runCatching { java.net.URI(value) }.getOrNull() ?: return false
            return uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrEmpty() && uri.userInfo == null
        }
    }

    // ---- responding

    private object Responder {
        fun respond(content: PromptContent, answer: PromptAnswer): ServerResponse = when (content) {
            is PromptContent.Approval -> {
                val choice = (answer as? PromptAnswer.Approve)?.choice ?: throw PromptInvalid("answer")
                if (choice !in content.choices) throw PromptInvalid("choice")
                ServerResponse.Result(buildJsonObject { put("choice", choice.wire); put("all", false) })
            }
            is PromptContent.Clarification -> {
                val answers = (answer as? PromptAnswer.Clarify)?.answers ?: throw PromptInvalid("answer")
                val resolved = LinkedHashMap<String, String>()
                for (q in content.questions) {
                    val locked = q.lockedAnswer
                    val given = locked ?: answers[q.id] ?: throw PromptInvalid("missing")
                    resolved[q.id] = if (locked != null) locked else validatedAnswer(given, q)
                }
                if (answers.keys.any { key -> content.questions.none { it.id == key } }) throw PromptInvalid("unknown")
                ServerResponse.Result(
                    if (content.isBatch) buildJsonObject { put("answers", JsonObject(resolved.mapValues { JsonPrimitive(it.value) })) }
                    else buildJsonObject { put("answer", resolved.getValue(SINGLE)) },
                )
            }
            is PromptContent.SecureInput -> when (content.kind) {
                SecureKind.VaultSaveLogin -> {
                    val login = answer as? PromptAnswer.SaveLogin ?: throw PromptInvalid("answer")
                    val identifier = login.identifier.trim()
                    val password = String(login.password)
                    if (identifier.isEmpty() || utf8Length(identifier) > 512 || password.isEmpty() || utf8Length(password) > 4_096 || '\u0000' in password) throw PromptInvalid("login")
                    ServerResponse.Result(buildJsonObject { put("value", buildJsonObject { put("identifier", identifier); put("password", password) }.toString()) })
                }
                else -> {
                    val secure = answer as? PromptAnswer.Secure ?: throw PromptInvalid("answer")
                    var value = String(secure.value)
                    if (content.kind == SecureKind.VaultCode) {
                        value = value.filter { !it.isWhitespace() && it != '-' }
                        if (value.isEmpty() || value.length > 64 || !value.all { it.code < 128 && it.isLetterOrDigit() }) throw PromptInvalid("code")
                    } else if (value.isEmpty() || utf8Length(value) > 65_536 || '\u0000' in value) throw PromptInvalid("value")
                    ServerResponse.Result(buildJsonObject { put("value", value) })
                }
            }
        }

        /** Cancel: deny, nothing, or an empty value. Never a blank chat message. */
        fun decline(content: PromptContent): ServerResponse = ServerResponse.Result(
            when (content) {
                is PromptContent.Approval -> buildJsonObject { put("choice", "deny"); put("all", false) }
                is PromptContent.Clarification -> JsonObject(emptyMap())
                is PromptContent.SecureInput -> buildJsonObject { put("value", "") }
            },
        )

        /** A multi-select answer is a string holding JSON array text; typed "Other" text is accepted as the whole answer. */
        fun validatedAnswer(answer: String, q: ClarifyQuestion): String {
            if (!validAnswer(answer)) throw PromptInvalid("answer")
            if (!q.multiSelect) return answer
            val selected = runCatching { app.bighelp.hermes.StrictJson.parse(answer) }.getOrNull()?.asArray ?: return answer
            val values = selected.map { it.asString?.takeIf(::validAnswer) ?: throw PromptInvalid("answer") }
            if (values.isEmpty() || values.size > q.choices.size + 1 || values.toSet().size != values.size) throw PromptInvalid("answer")
            val customs = values.count { it !in q.choices }
            if (customs > 1) throw PromptInvalid("answer")
            return kotlinx.serialization.json.JsonArray(values.map { JsonPrimitive(it) }).toString()
        }
    }

    companion object {
        const val SINGLE = "\$single"
        const val MAXIMUM_OPEN = 64
        private val invalid = ServerResponse.Failure(-32602, "Invalid prompt parameters")
        private val retiredResponse = ServerResponse.Failure(-32000, "Prompt is no longer active")
        private fun validQuestion(value: String) = value.isNotEmpty() && utf8Length(value) <= 65_536 && '\u0000' !in value
        private fun validAnswer(value: String) = value.isNotEmpty() && utf8Length(value) <= 10_000 && '\u0000' !in value
    }
}
