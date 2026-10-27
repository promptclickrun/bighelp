package app.bighelp.hermes.chat

import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** One decoded `GET /api/sessions` page. [hasMore] is null for the older envelope, which sends [total] instead. */
internal class SessionPage(val rows: List<JsonObject>, val limit: Int, val offset: Int, val hasMore: Boolean?, val total: Int?)

/** Decodes `profiles.list` and the saved-chat list, with the checks of the current app. Anything off is `InvalidResponse`. */
internal object CatalogDecoder {
    const val PAGE_LIMIT = 100
    const val MAXIMUM_PROFILES = 512
    const val MAXIMUM_SESSIONS = 10_000
    val DEFAULT_EXCLUDED_SOURCES = listOf("tool", "kanban", "bot_room")

    fun profiles(result: JsonElement): List<AgentSummary> {
        val rows = result.asObject?.get("profiles").asArray ?: throw invalidResponse()
        if (rows.size > MAXIMUM_PROFILES) throw invalidResponse()
        val seen = HashSet<String>()
        return rows.map { value ->
            val row = value.asObject ?: throw invalidResponse()
            val id = row["name"].asString?.takeIf { Coordinates.isValid(it, Coordinates.MAXIMUM_PROFILE_BYTES) } ?: throw invalidResponse()
            if (!seen.add(id)) throw invalidResponse()
            val label = optionalText(row["display_name"], 800)?.takeIf { it.isNotEmpty() }
            AgentSummary(id, label ?: id, registry(row["canonical_session"]), row)
        }
    }

    private fun registry(value: JsonElement?): CanonicalChat? {
        if (value == null || value is JsonNull) return null
        val row = value.asObject ?: throw invalidResponse()
        val id = row["id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
        val resolved = optionalText(row["resolved_id"], 512)
        if (resolved != null && !Coordinates.isValid(resolved)) throw invalidResponse()
        return CanonicalChat(id, resolved)
    }

    /** The current app's list request: explicit profile, 100 per page, deliberate archives included, creation order, internal sources excluded. */
    fun listQuery(
        profile: String,
        offset: Int,
        archived: String = "include",
        order: String = "created",
        excludedSources: List<String> = DEFAULT_EXCLUDED_SOURCES,
    ): List<Pair<String, String>> = buildList {
        add("profile" to profile); add("limit" to PAGE_LIMIT.toString()); add("offset" to offset.toString())
        add("archived" to archived); add("order" to order)
        if (excludedSources.isNotEmpty()) add("exclude_sources" to excludedSources.joinToString(","))
    }

    /**
     * Accepts the standard list envelope (`object:"list"`, `data`, Boolean `has_more`) and the older typed one
     * (`sessions`, `total`). The page must echo the requested offset and the fixed limit.
     */
    fun sessionPage(envelope: JsonElement, profile: String, requestedOffset: Int): SessionPage {
        val body = envelope.asObject ?: throw invalidResponse()
        val rows: List<JsonElement>
        val hasMore: Boolean?
        if (body["object"].asString == "list") {
            rows = body["data"].asArray ?: throw invalidResponse()
            hasMore = body["has_more"].asBool ?: throw invalidResponse()
        } else {
            if (body["object"] != null || body["data"] != null || body["has_more"] != null) throw invalidResponse()
            rows = body["sessions"].asArray ?: throw invalidResponse()
            hasMore = null
            if ((body["total"].asInt ?: throw invalidResponse()) < 0) throw invalidResponse()
        }
        val limit = body["limit"].asInt
        val offset = body["offset"].asInt
        if (limit != PAGE_LIMIT || offset != requestedOffset || rows.size > MAXIMUM_SESSIONS) throw invalidResponse()
        val total = body["total"]?.takeIf { it !is JsonNull }?.let { (it.asInt ?: throw invalidResponse()).also { n -> if (n < 0) throw invalidResponse() } }
        val objects = rows.map { value ->
            val row = value.asObject ?: throw invalidResponse()
            val id = row["id"].asString
            if (id.isNullOrEmpty() || id.contains('\u0000')) throw invalidResponse()
            row["profile"]?.let { echoed -> if (echoed.asString != profile) throw invalidResponse() }
            row
        }
        return SessionPage(objects, limit, offset, hasMore, total)
    }

    /** Whether a next page exists: the host's `has_more`, else `total`, else a full page (older hosts add pinned rows past the limit). */
    fun hasMore(page: SessionPage, offset: Int, rows: Int): Boolean {
        page.hasMore?.let { return it }
        page.total?.let { return offset + page.limit < it }
        return rows >= page.limit
    }

    /** `archived` truthy and not `auto_archived`: someone archived it. Hermes' idle sweep marks its own. */
    fun archiveState(row: JsonObject): ArchiveState {
        fun flag(value: JsonElement?): Boolean = when {
            value.asBool != null -> value.asBool == true
            value.asDouble != null -> value.asDouble != 0.0
            else -> false
        }
        if (!flag(row["archived"])) return ArchiveState.None
        return if (flag(row["auto_archived"])) ArchiveState.Automatic else ArchiveState.Deliberate
    }

    /** One list row. [canonical] is the profile's registry Bot Chat, which the row may be a member of. */
    fun summary(row: JsonObject, profile: String, canonical: CanonicalChat?): SessionSummary {
        val id = row["id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
        if (row["profile"].asString != profile) throw invalidResponse()
        val root = optionalText(row["_lineage_root_id"], 512)?.also { if (!Coordinates.isValid(it)) throw invalidResponse() }
        val lineage = row["_lineage_ids"]?.takeIf { it !is JsonNull }?.let { raw ->
            val values = raw.asArray ?: throw invalidResponse()
            if (values.size > MAXIMUM_SESSIONS) throw invalidResponse()
            val ids = values.map { it.asString?.takeIf(Coordinates::isValid) ?: throw invalidResponse() }
            if (ids.toSet().size != ids.size || id !in ids || (root != null && root !in ids)) throw invalidResponse()
            ids
        }
        val matchesCanonical = canonical != null &&
            (canonical.id == id || canonical.resolvedId == id || root == canonical.id || lineage?.contains(canonical.id) == true)
        val anchor = if (matchesCanonical) canonical!!.id else root ?: id
        val started = date(row["started_at"]) ?: throw invalidResponse()
        val updated = date(row["last_active"] ?: row["last_activity_at"]) ?: started
        val count = row["message_count"]?.takeIf { it !is JsonNull }?.let { (it.asInt ?: throw invalidResponse()).also { n -> if (n < 0) throw invalidResponse() } } ?: 0
        val title = optionalText(row["title"], 4_096).orEmpty()
        return SessionSummary(
            ref = ConversationRef(profile, anchor), profile = profile, storedId = id,
            title = title.ifEmpty { "Untitled" },
            preview = preview(optionalText(row["preview"], 64 * 1024).orEmpty()),
            startedAtEpochSeconds = started, lastActiveEpochSeconds = updated, messageCount = count,
            source = optionalText(row["source"], 128), cwd = optionalText(row["cwd"], 4_096),
            pinned = flag(row["pinned"]) ?: false, archive = archiveState(row),
            lineageRootId = root, lineageIds = lineage, isCanonicalBotChat = matchesCanonical, isRegistryOnly = false,
        )
    }

    /** The agent's Bot Chat as only the registry names it. No title text of its own, time or preview is made up. */
    fun registryOnly(profile: String, canonical: CanonicalChat) = SessionSummary(
        ref = ConversationRef(profile, canonical.id), profile = profile, storedId = canonical.resolvedId ?: canonical.id,
        title = "Bot Chat", preview = "", startedAtEpochSeconds = null, lastActiveEpochSeconds = null, messageCount = 0,
        source = null, cwd = null, pinned = false, archive = ArchiveState.None, lineageRootId = null, lineageIds = null,
        isCanonicalBotChat = true, isRegistryOnly = true,
    )

    /** One line for the list: attachments read as "Photo" or "Attachment" instead of host paths. */
    fun preview(raw: String): String {
        val shown = UserMessageDisplay.text(raw)
        var photos = false
        var files = false
        val words = shown.split("\n").filter { line ->
            when {
                line.startsWith("@image:") -> { photos = true; false }
                line.startsWith("@file:") -> { files = true; false }
                else -> true
            }
        }
        val body = words.joinToString("\n").trim()
        return body.ifEmpty { if (photos) "Photo" else if (files) "Attachment" else "" }
    }

    private fun flag(value: JsonElement?): Boolean? = when {
        value == null || value is JsonNull -> null
        value.asBool != null -> value.asBool
        value.asLong == 0L -> false
        value.asLong == 1L -> true
        else -> throw invalidResponse()
    }

    private fun date(value: JsonElement?): Double? {
        if (value == null || value is JsonNull) return null
        val seconds = value.asDouble ?: throw invalidResponse()
        if (seconds < 0 || seconds > 253_402_300_799.0) throw invalidResponse()
        return seconds
    }

    /** Null/absent is null; a present value must be text within the bound with no control characters but \n \r \t. */
    fun optionalText(value: JsonElement?, maximumBytes: Int): String? {
        if (value == null || value is JsonNull) return null
        val text = value.asString ?: throw invalidResponse()
        if (utf8Length(text) > maximumBytes) throw invalidResponse()
        if (text.any { Character.getType(it) == Character.CONTROL.toInt() && it != '\n' && it != '\r' && it != '\t' }) throw invalidResponse()
        return text
    }
}
