package app.bighelp.hermes.chat

import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// The durable records. Every body repeats its exact scope, and every decode checks it against the key's scope,
// so a mis-addressed or colliding file can never present one conversation's text as another's. All of them
// are compact UTF-8 JSON bounded by RecordKind.maximumBytes; encoding refuses a larger record before any
// write is attempted.

private const val SCHEMA = 1

private fun JsonObject.putScope(scope: ConversationScope): JsonObject = JsonObject(
    this + mapOf(
        "computer" to JsonPrimitive(scope.host.computerId), "endpoint" to JsonPrimitive(scope.host.endpoint),
        "principal" to JsonPrimitive(scope.host.principal), "profile" to JsonPrimitive(scope.profile),
        "anchor" to JsonPrimitive(scope.anchor),
    ),
)

private fun JsonObject.hostMatches(host: HostScope) =
    this["computer"].asString == host.computerId && this["endpoint"].asString == host.endpoint && this["principal"].asString == host.principal

private fun JsonObject.scopeMatches(scope: ConversationScope) =
    hostMatches(scope.host) && this["profile"].asString == scope.profile && this["anchor"].asString == scope.anchor

private fun encodeBounded(kind: RecordKind, body: JsonObject): ByteArray {
    val bytes = body.toString().toByteArray(Charsets.UTF_8)
    if (bytes.size > kind.maximumBytes) throw ChatStoreException(ChatStoreException.Kind.TooLarge)
    return bytes
}

private fun references(array: JsonArray?): List<String> {
    if (array == null) return emptyList()
    if (array.size > ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCES) corrupt()
    return array.map { it.asString?.takeIf { s -> s.isNotEmpty() && utf8Length(s) <= ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCE_BYTES } ?: corrupt() }
}

private fun encodeReferences(values: List<String>): JsonArray {
    require(values.size <= ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCES) { "Too many attachment references" }
    require(values.all { it.isNotEmpty() && utf8Length(it) <= ChatStoreLimits.MAXIMUM_ATTACHMENT_REFERENCE_BYTES }) { "Invalid attachment reference" }
    return buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }
}

/** The composer text of one conversation. Empty text with no references is stored as the absence of a record. */
class DraftRecord(val scope: ConversationScope, val text: String, val attachments: List<String> = emptyList(), val updatedAtMillis: Long) {
    init {
        require(utf8Length(text) <= ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES) { "A draft is at most 1 MiB" }
    }

    val isEmpty: Boolean get() = text.isEmpty() && attachments.isEmpty()

    fun encode(): ByteArray = encodeBounded(RecordKind.Draft, buildJsonObject {
        put("v", SCHEMA); put("text", text); put("attachments", encodeReferences(attachments)); put("updatedAt", updatedAtMillis)
    }.putScope(scope))

    override fun toString() = "DraftRecord(${text.length} chars)"

    companion object {
        fun decode(scope: ConversationScope, bytes: ByteArray): DraftRecord {
            val body = parseRecord(bytes)
            if (body["v"].asInt != SCHEMA || !body.scopeMatches(scope)) corrupt()
            val text = body["text"].asString ?: corrupt()
            if (utf8Length(text) > ChatStoreLimits.MAXIMUM_MESSAGE_TEXT_BYTES) corrupt()
            return DraftRecord(scope, text, references(body["attachments"].asArray), body["updatedAt"].asLong ?: corrupt())
        }
    }
}

/**
 * One submission that is not settled: the exact bytes Hermes may have been given ([method], [text]), what the
 * person typed ([composerText], which survives wire expansion), the local UUID and creation time. It is
 * written before the method is dispatched. [rejectionCode] non-null marks a definite refusal (nothing was
 * admitted); otherwise the outcome is unknown and the entry is never resent. The local UUID is not a Hermes
 * nonce and is never sent.
 */
class JournalEntry(
    val id: String,
    val scope: ConversationScope,
    val method: String,
    val text: String,
    val composerText: String,
    val attachments: List<String>,
    val createdAtMillis: Long,
    val rejectionCode: Int? = null,
) {
    init {
        require(Coordinates.isUuid(id)) { "A journal entry ID is a UUID" }
        require(method in METHODS) { "Unknown journaled method" }
    }

    val isRefused: Boolean get() = rejectionCode != null

    fun withMethod(method: String, text: String) = JournalEntry(id, scope, method, text, composerText, attachments, createdAtMillis, rejectionCode)
    /** [code] 0 means refused without a host code (nothing was dispatched, or the host named none). */
    fun refused(code: Int?) = JournalEntry(id, scope, method, text, composerText, attachments, createdAtMillis, code ?: 0)

    fun encode(): ByteArray = encodeBounded(RecordKind.Journal, buildJsonObject {
        put("v", SCHEMA); put("id", id); put("method", method); put("text", text); put("composerText", composerText)
        put("attachments", encodeReferences(attachments)); put("createdAt", createdAtMillis)
        put("rejectionCode", rejectionCode)
    }.putScope(scope))

    override fun toString() = "JournalEntry($id, $method)"

    companion object {
        val METHODS = setOf("prompt.submit", "session.steer", "session.interrupt", "slash.exec", "command.dispatch")

        fun decode(scope: ConversationScope, entryId: String, bytes: ByteArray): JournalEntry {
            val body = parseRecord(bytes)
            if (body["v"].asInt != SCHEMA || !body.scopeMatches(scope) || body["id"].asString != entryId) corrupt()
            val method = body["method"].asString?.takeIf { it in METHODS } ?: corrupt()
            val text = body["text"].asString ?: corrupt()
            val composer = body["composerText"].asString ?: corrupt()
            return JournalEntry(
                entryId, scope, method, text, composer, references(body["attachments"].asArray),
                body["createdAt"].asLong ?: corrupt(), body["rejectionCode"].asInt,
            )
        }
    }
}

enum class CreationPurpose { Ordinary, FirstCanonical }

enum class CreationPhase { CreateRequested, Created, TitleRequested, AwaitingRegistry, Complete, CanonicalResolved }

/** Everything a create sends besides the profile and the fixed `source`, kept so a retry is the same logical create. */
data class CreateRequest(
    val cwd: String? = null,
    val title: String? = null,
    val model: String? = null,
    val provider: String? = null,
    val reasoningEffort: String? = null,
    val fast: Boolean? = null,
) {
    init {
        cwd?.let { require(Coordinates.isValid(it, 4_096)) { "Invalid folder" } }
        title?.let { require(it.isNotEmpty() && utf8Length(it) <= 240) { "Invalid title" } }
        model?.let { require(Coordinates.isValid(it, 256)) { "Invalid model" } }
        provider?.let { require(Coordinates.isValid(it, 128)) { "Invalid provider" } }
        reasoningEffort?.let { require(Coordinates.isValid(it, 32)) { "Invalid reasoning" } }
        require(provider == null || model != null) { "A provider accompanies a model" }
    }
}

/**
 * A create intent, written before `session.create` is dispatched and updated as coordinates arrive. [intentId]
 * is the lowercase UUID sent as `idempotency_key`, so every retry of this same logical create carries the same
 * key (the host keeps it for a short time; it is not indefinite deduplication).
 */
data class CreationRecord(
    val host: HostScope,
    val intentId: String,
    val profile: String,
    val purpose: CreationPurpose,
    val phase: CreationPhase,
    val request: CreateRequest,
    val storedSessionId: String? = null,
    val runtimeSessionId: String? = null,
    val canonicalRegistryId: String? = null,
    val socketGeneration: Long = 0,
    val createdAtMillis: Long,
) {
    init {
        require(Coordinates.isUuid(intentId) && intentId == intentId.lowercase()) { "The intent ID is a lowercase UUID" }
        require(Coordinates.isValid(profile, Coordinates.MAXIMUM_PROFILE_BYTES)) { "Invalid profile" }
    }

    /** The coordinate rules of each phase (a canonical-resolved record may hold neither or both). */
    val isCoherent: Boolean
        get() = when (phase) {
            CreationPhase.CanonicalResolved -> purpose == CreationPurpose.FirstCanonical && canonicalRegistryId != null &&
                (storedSessionId == null) == (runtimeSessionId == null)
            CreationPhase.CreateRequested -> storedSessionId == null && runtimeSessionId == null
            else -> storedSessionId != null && runtimeSessionId != null
        }

    val isFinished: Boolean get() = phase == CreationPhase.Complete || phase == CreationPhase.CanonicalResolved

    fun encode(): ByteArray = encodeBounded(RecordKind.Creation, buildJsonObject {
        put("v", SCHEMA); put("intent", intentId); put("purpose", purpose.name); put("phase", phase.name)
        put("cwd", request.cwd); put("title", request.title); put("model", request.model); put("provider", request.provider)
        put("reasoning", request.reasoningEffort); put("fast", request.fast)
        put("stored", storedSessionId); put("runtime", runtimeSessionId); put("registry", canonicalRegistryId)
        put("generation", socketGeneration); put("createdAt", createdAtMillis)
    }.let { JsonObject(it + mapOf("computer" to JsonPrimitive(host.computerId), "endpoint" to JsonPrimitive(host.endpoint),
        "principal" to JsonPrimitive(host.principal), "profile" to JsonPrimitive(profile))) })

    companion object {
        fun decode(host: HostScope, profile: String, bytes: ByteArray): CreationRecord {
            val body = parseRecord(bytes)
            if (body["v"].asInt != SCHEMA || !body.hostMatches(host) || body["profile"].asString != profile) corrupt()
            val record = try {
                CreationRecord(
                    host, body["intent"].asString ?: corrupt(), profile,
                    CreationPurpose.entries.firstOrNull { it.name == body["purpose"].asString } ?: corrupt(),
                    CreationPhase.entries.firstOrNull { it.name == body["phase"].asString } ?: corrupt(),
                    CreateRequest(body["cwd"].asString, body["title"].asString, body["model"].asString, body["provider"].asString,
                        body["reasoning"].asString, body["fast"].asBool),
                    body["stored"].asString, body["runtime"].asString, body["registry"].asString,
                    body["generation"].asLong ?: corrupt(), body["createdAt"].asLong ?: corrupt(),
                )
            } catch (_: IllegalArgumentException) {
                corrupt()
            }
            if (!record.isCoherent) corrupt()
            return record
        }
    }
}

/** A conversation's stored tip and routing aliases. Written when the tip first differs from the anchor or changes. */
class IdentityRecord(val scope: ConversationScope, val identity: ConversationIdentity) {
    fun encode(): ByteArray = encodeBounded(RecordKind.Identity, buildJsonObject {
        put("v", SCHEMA); put("tip", identity.storedTip)
        put("former", buildJsonArray { identity.formerStoredIds.forEach { add(JsonPrimitive(it)) } })
        put("root", identity.lineageRootId); put("registry", identity.canonicalRegistryId)
        put("lineage", identity.lineageIds?.let { ids -> buildJsonArray { ids.forEach { add(JsonPrimitive(it)) } } } ?: JsonNull)
    }.putScope(scope))

    companion object {
        fun decode(scope: ConversationScope, bytes: ByteArray): ConversationIdentity {
            val body = parseRecord(bytes)
            if (body["v"].asInt != SCHEMA || !body.scopeMatches(scope)) corrupt()
            fun ids(array: JsonArray?, limit: Int): List<String>? = array?.map { it.asString?.takeIf(Coordinates::isValid) ?: corrupt() }?.also { if (it.size > limit) corrupt() }
            return try {
                ConversationIdentity(
                    scope.ref, body["tip"].asString ?: corrupt(), ids(body["former"].asArray, ChatStoreLimits.MAXIMUM_FORMER_STORED_IDS).orEmpty(),
                    body["root"].asString, ids(body["lineage"].asArray, 10_000), body["registry"].asString,
                )
            } catch (_: IllegalArgumentException) {
                corrupt()
            }
        }
    }
}
