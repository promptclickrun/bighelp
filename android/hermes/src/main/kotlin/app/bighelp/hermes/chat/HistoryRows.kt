package app.bighelp.hermes.chat

import app.bighelp.hermes.utf8Length
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * One physical row of the host's saved history (`GET /api/sessions/{id}/messages`). It keeps the host's raw
 * object ([raw]) so a boundary check compares exactly what the host sent, and the decoded display facts. A
 * row's [id] is a positive integer assigned by the host; it is not a turn ID, a position or a text hash.
 */
internal class HistoryRow private constructor(
    val id: Long,
    val sessionId: String,
    val role: String,
    val content: JsonElement,
    val text: String,
    val hasUnsupportedContent: Boolean,
    val toolCalls: List<ToolCall>,
    val toolCallId: String?,
    val toolName: String?,
    val reasoning: String?,
    val timestamp: Double?,
    val turnDurationMillis: Int?,
    val platformMessageId: String?,
    val displayKind: String?,
    val raw: JsonObject,
) {
    class ToolCall(val id: String?, val name: String?, val arguments: String?)

    /** `hidden` and `internal_notification` rows are kept in the window but not shown. */
    val isVisible: Boolean get() = displayKind != "hidden" && displayKind != "internal_notification"

    private var canonical: String? = null

    /** Sorted-key JSON of the host's object: the byte-for-byte identity used by every boundary check. */
    fun canonicalJson(): String = canonical ?: Canonical.write(raw).also { canonical = it }

    /** The size this row counts toward the retained-read ceiling. */
    fun encodedBytes(): Int = utf8Length(canonicalJson())

    companion object {
        const val MAXIMUM_ROW_ID = 9_007_199_254_740_991L
        const val MAXIMUM_TEXT_BYTES = 1_048_576

        /** @throws app.bighelp.hermes.HermesException InvalidResponse for any row that breaks the documented shape. */
        fun parse(value: JsonElement, expectedSessionId: String): HistoryRow {
            val row = value.asObject ?: throw invalidResponse()
            val id = row["id"].asLong?.takeIf { it in 1..MAXIMUM_ROW_ID } ?: throw invalidResponse()
            val sessionId = row["session_id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
            if (sessionId != expectedSessionId) throw invalidResponse()
            val role = row["role"].asString?.takeIf { Coordinates.isValid(it, 64) } ?: throw invalidResponse()
            val content = row["content"] ?: JsonNull
            val displayed = displayText(row["display_content"]?.takeIf { it !is JsonNull } ?: content)
            val reasoningValue = listOf(row["reasoning_content"], row["reasoning"]).firstOrNull { it != null && it !is JsonNull }
            val reasoning = reasoningValue?.let { (it.asString ?: throw invalidResponse()).also(::bounded) }
            val toolCalls = when (val calls = row["tool_calls"]) {
                null, JsonNull -> emptyList()
                is JsonPrimitive -> if (calls.isString && calls.content.isEmpty()) emptyList() else throw invalidResponse()
                is JsonArray -> {
                    if (calls.size > 128) throw invalidResponse()
                    calls.map { entry ->
                        val call = entry.asObject ?: throw invalidResponse()
                        val function = call["function"].asObject
                        ToolCall(optionalCoordinate(call["id"]), optionalCoordinate(function?.get("name"), 128), function?.get("arguments")?.let(::literalText))
                    }
                }
                else -> throw invalidResponse()
            }
            return HistoryRow(
                id, sessionId, role, content, displayed.first, displayed.second, toolCalls,
                optionalCoordinate(row["tool_call_id"]), optionalCoordinate(row["tool_name"], 128), reasoning,
                timestamp(row["timestamp"]), duration(row["turn_duration_ms"]), optionalCoordinate(row["platform_message_id"]),
                optionalCoordinate(row["display_kind"], 128), row,
            )
        }

        /** String verbatim; an array of `text`/`input_text`/`output_text` parts joined by newlines; any other part marks unsupported content. */
        private fun displayText(value: JsonElement): Pair<String, Boolean> = when (value) {
            JsonNull -> "" to false
            is JsonPrimitive -> if (value.isString) bounded(value.content) to false else "" to true
            is JsonArray -> {
                if (value.size > 512) throw invalidResponse()
                val pieces = ArrayList<String>()
                var unsupported = false
                for (part in value) {
                    val obj = part.asObject
                    val type = obj?.get("type").asString
                    val text = obj?.get("text").asString
                    if (obj == null || type !in TEXT_TYPES || text == null) unsupported = true else pieces += bounded(text)
                }
                bounded(pieces.joinToString("\n")) to unsupported
            }
            else -> "" to true
        }

        fun literalText(value: JsonElement): String {
            if (value is JsonPrimitive && value.isString) return bounded(value.content)
            return bounded(Canonical.write(value))
        }

        private fun bounded(text: String): String {
            if (utf8Length(text) > MAXIMUM_TEXT_BYTES) throw ChatException(ChatError.Kind.TooLarge)
            return text
        }

        private fun optionalCoordinate(value: JsonElement?, maximum: Int = 512): String? {
            if (value == null || value is JsonNull || (value is JsonPrimitive && value.isString && value.content.isEmpty())) return null
            return value.asString?.takeIf { Coordinates.isValid(it, maximum) } ?: throw invalidResponse()
        }

        private fun timestamp(value: JsonElement?): Double? {
            if (value == null || value is JsonNull) return null
            val seconds = value.asDouble ?: throw invalidResponse()
            if (seconds < 0 || seconds > 253_402_300_799.0) throw invalidResponse()
            return seconds
        }

        /** A malformed duration is ignored; it never hides the row. */
        private fun duration(value: JsonElement?): Int? = value.asLong?.takeIf { it in 0..86_400_000 }?.toInt()

        private val TEXT_TYPES = setOf("text", "input_text", "output_text")
    }
}

/** Sorted-key JSON, the same for the same host object whatever order its members arrived in. */
internal object Canonical {
    fun write(value: JsonElement): String = StringBuilder().also { append(it, value) }.toString()

    private fun append(out: StringBuilder, value: JsonElement) {
        when (value) {
            is JsonObject -> {
                out.append('{')
                value.keys.sorted().forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    out.append(JsonPrimitive(key).toString()).append(':')
                    append(out, value.getValue(key))
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                value.forEachIndexed { index, element -> if (index > 0) out.append(','); append(out, element) }
                out.append(']')
            }
            else -> out.append(value.toString())
        }
    }
}

/** One decoded REST page, validated against the request that produced it. */
internal class HistoryPage(val storedId: String, val rows: List<HistoryRow>, val returned: Int, val limit: Int) {
    companion object {
        /**
         * The envelope must echo exactly the requested `offset`, `limit` and `order`; `returned` must equal the row
         * count and rows cannot exceed the limit. A supplied `profile` must match. Duplicate row IDs mean the
         * history moved under the read.
         */
        fun parse(envelope: JsonElement, profile: String, offset: Int, limit: Int, order: String): HistoryPage {
            val body = envelope.asObject ?: throw invalidResponse()
            val storedId = body["session_id"].asString?.takeIf { Coordinates.isValid(it) } ?: throw invalidResponse()
            body["profile"]?.let { if (it.asString != profile) throw invalidResponse() }
            val values = (body["messages"] ?: body["data"]).asArray ?: throw invalidResponse()
            val pagination = body["pagination"].asObject ?: throw invalidResponse()
            if (values.size > limit || pagination["offset"].asLong != offset.toLong() || pagination["limit"].asLong != limit.toLong() ||
                pagination["order"].asString != order || pagination["returned"].asLong != values.size.toLong()
            ) throw invalidResponse()
            val rows = values.map { HistoryRow.parse(it, storedId) }
            if (rows.map { it.id }.toSet().size != rows.size) throw ChatException(ChatError.Kind.HistoryChanged)
            return HistoryPage(storedId, rows, rows.size, limit)
        }
    }
}

/**
 * The newest rows of one saved chat that this repository holds, oldest first, and where the next older page
 * starts (`nextOffset` counts rows from the newest; null once the start of the chat is reached). Every merge
 * checks the overlap row byte for byte; a window that does not line up is refused, never combined.
 */
internal class HistoryWindow(val storedId: String, val rows: List<HistoryRow>, val nextOffset: Int?) {
    val bytes: Long by lazy { rows.sumOf { it.encodedBytes().toLong() } }

    companion object {
        const val MAXIMUM_ROWS = 50_000
        const val MAXIMUM_BYTES = 32L * 1_048_576
        const val MAXIMUM_WINDOWS = 4
        const val MAXIMUM_TOTAL_BYTES = 64L * 1_048_576

        /** The first page for a chat with no window: all of it, with a next page when it came back full. */
        fun fresh(page: HistoryPage): HistoryWindow =
            capped(HistoryWindow(page.storedId, page.rows, if (page.returned == page.limit) page.rows.size else null))

        /**
         * A newest-page refresh. When the page starts inside the held rows and its prefix lines up with the held
         * tail (same IDs in order, an unchanged first row), the earlier held rows stay and the tail is replaced.
         * Anything else starts a fresh window from this page alone.
         */
        fun refreshed(held: HistoryWindow?, page: HistoryPage): HistoryWindow {
            val kept = held?.takeIf { it.storedId == page.storedId }?.let { keptRows(it, page) } ?: return fresh(page)
            val combined = kept + page.rows
            val next = if (held.nextOffset == null || page.returned < page.limit) null else combined.size
            return capped(HistoryWindow(page.storedId, combined, next))
        }

        /**
         * An older page requested at [window].nextOffset - 1 with one overlap row. The overlap must be the held
         * oldest row exactly, and the rest must not repeat any held row.
         */
        fun prepended(window: HistoryWindow, page: HistoryPage): HistoryWindow {
            val oldest = window.rows.firstOrNull() ?: throw ChatException(ChatError.Kind.HistoryChanged)
            val anchor = page.rows.lastOrNull()
            if (page.storedId != window.storedId || anchor == null || anchor.id != oldest.id ||
                anchor.canonicalJson() != oldest.canonicalJson()
            ) throw ChatException(ChatError.Kind.HistoryChanged)
            val older = page.rows.dropLast(1)
            val held = window.rows.mapTo(HashSet()) { it.id }
            if (older.any { it.id in held }) throw ChatException(ChatError.Kind.HistoryChanged)
            val combined = older + window.rows
            return capped(HistoryWindow(window.storedId, combined, if (page.returned == page.limit) combined.size else null))
        }

        private fun keptRows(held: HistoryWindow, page: HistoryPage): List<HistoryRow>? {
            val first = page.rows.firstOrNull() ?: return null
            val start = held.rows.indexOfFirst { it.id == first.id }
            if (start < 0) return null
            val tail = held.rows.subList(start, held.rows.size)
            if (tail.size > page.rows.size) return null
            if (tail.indices.any { tail[it].id != page.rows[it].id }) return null
            if (tail[0].canonicalJson() != first.canonicalJson()) return null
            val kept = held.rows.subList(0, start)
            val pageIds = page.rows.mapTo(HashSet()) { it.id }
            return kept.takeIf { rows -> rows.none { it.id in pageIds } }?.toList()
        }

        private fun capped(window: HistoryWindow): HistoryWindow {
            if (window.rows.size > MAXIMUM_ROWS || window.bytes > MAXIMUM_BYTES) throw ChatException(ChatError.Kind.TooLarge)
            return window
        }
    }
}

/**
 * The windows this repository keeps, least recently used evicted so that at most four windows and 64 MiB are held.
 * An evicted conversation reads its newest page fresh; its old paging offset is gone with it.
 */
internal class HistoryWindowCache {
    private val windows = LinkedHashMap<ConversationRef, HistoryWindow>()

    operator fun get(ref: ConversationRef): HistoryWindow? = windows[ref]

    fun put(ref: ConversationRef, window: HistoryWindow) {
        windows.remove(ref)
        while (windows.isNotEmpty() && (windows.size >= HistoryWindow.MAXIMUM_WINDOWS ||
                windows.values.sumOf { it.bytes } + window.bytes > HistoryWindow.MAXIMUM_TOTAL_BYTES)
        ) windows.remove(windows.keys.first())
        windows[ref] = window
    }

    fun remove(ref: ConversationRef) { windows.remove(ref) }
    fun clear() = windows.clear()
    val size: Int get() = windows.size
}
