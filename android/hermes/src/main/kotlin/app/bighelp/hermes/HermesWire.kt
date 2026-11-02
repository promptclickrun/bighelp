package app.bighelp.hermes

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A frame that must not be applied. Carries only a category, never frame text. */
class WireException(val kind: Kind) : Exception(kind.category) {
    enum class Kind(val category: String) {
        InvalidResponse("invalidResponse"),
        MessageTooLarge("messageTooLarge"),
    }

    /** The shared vectors' name for [kind]. */
    val category: String get() = kind.category
}

/**
 * One decoded gateway entry. IDs are the exact decoded strings: never trimmed, normalized or replaced,
 * so canonically equivalent but byte-distinct IDs stay distinct.
 */
sealed interface WireMessage {
    /** `event:<type>`, `request:<method>`, `result:<id>` or `failure:<id>`, as in the shared vectors. */
    val classification: String

    /** `parameters` is the complete original `params`, including future envelope metadata. */
    data class Event(
        val type: String,
        val sessionID: String?,
        val payload: JsonObject,
        val sequence: Long?,
        val parameters: JsonObject = JsonObject(emptyMap()),
    ) : WireMessage {
        override val classification get() = "event:$type"
    }

    /** A live server request, answered with the same [id]. Absent or null `params` become `{}`. */
    data class Request(val id: String, val method: String, val params: JsonObject) : WireMessage {
        override val classification get() = "request:$method"
    }

    data class Result(val id: String, val value: JsonElement) : WireMessage {
        override val classification get() = "result:$id"
    }

    /** `reason` is `error.data.reason`; `message` is Hermes' words flattened for display, never a decision input. */
    data class Failure(val id: String, val code: Long, val reason: String?, val message: String?) : WireMessage {
        override val classification get() = "failure:$id"
    }
}

/** Exact payload of a `request.cancel` event. */
data class RequestCancellation(val id: String, val method: String, val reason: String)

/**
 * The gateway's framing seam. [decode] validates a whole WebSocket message before returning anything, so a
 * caller either gets every entry in wire order or a [WireException] and nothing: a good first line followed
 * by a bad one never publishes the first.
 */
object HermesWire {
    const val MAXIMUM_MESSAGE_BYTES = 4 * 1_024 * 1_024
    const val MAXIMUM_BATCH_COUNT = 4_096
    const val MAXIMUM_METHOD_BYTES = 256
    const val MAXIMUM_REQUEST_ID_BYTES = 1_024
    const val MAXIMUM_CANCELLATION_REASON_BYTES = 4_096
    const val MAXIMUM_NESTING = StrictJson.MAXIMUM_DEPTH
    const val MAXIMUM_REFUSAL_CHARACTERS = 280

    private const val NEWLINE = 0x0a.toByte()
    private val CANCELLATION_KEYS = setOf("id", "method", "reason")

    /** Lines are checked in order, like the iOS decoder, so the first violation decides the category. */
    fun decode(bytes: ByteArray): List<WireMessage> {
        if (bytes.size > MAXIMUM_MESSAGE_BYTES) throw tooLarge()
        val messages = ArrayList<WireMessage>()
        var start = 0
        while (start < bytes.size) {
            var end = start
            while (end < bytes.size && bytes[end] != NEWLINE) end++
            if (!isBlank(bytes, start, end)) {
                if (messages.size >= MAXIMUM_BATCH_COUNT) throw tooLarge()
                validateNesting(bytes, start, end)
                messages += decodeLine(bytes, start, end)
            }
            start = end + 1
        }
        if (messages.isEmpty()) throw invalid()
        return messages
    }

    fun isValidMethod(method: String): Boolean =
        method.length in 1..MAXIMUM_METHOD_BYTES && method.all { it.code in 33..126 }

    fun isValidRequestID(id: String): Boolean = utf8Length(id) <= MAXIMUM_REQUEST_ID_BYTES

    /**
     * The documented cancellation is exact: only `id`, `method` and `reason`. Matching both ID and method
     * stops a malformed cancel from retiring another prompt.
     * @throws WireException if [event] is not a well-formed `request.cancel`.
     */
    fun cancellation(event: WireMessage.Event): RequestCancellation {
        val payload = event.payload
        val id = payload["id"].string
        val method = payload["method"].string
        val reason = payload["reason"].string
        if (event.type != "request.cancel" || payload.keys != CANCELLATION_KEYS ||
            id == null || !isValidRequestID(id) ||
            method == null || !isValidMethod(method) ||
            reason == null || utf8Length(reason) > MAXIMUM_CANCELLATION_REASON_BYTES
        ) throw invalid()
        return RequestCancellation(id, method, reason)
    }

    private fun decodeLine(bytes: ByteArray, start: Int, end: Int): WireMessage {
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, start, end - start))
                .toString()
        } catch (_: CharacterCodingException) {
            throw invalid()
        }
        val root = try {
            StrictJson.parse(text)
        } catch (_: StrictJson.Malformed) {
            throw invalid()
        }
        val envelope = root as? JsonObject ?: throw invalid()
        if (envelope["jsonrpc"].string != "2.0") throw invalid()

        val method = envelope["method"]
        val hasResponse = "result" in envelope || "error" in envelope
        if (method != null) {
            val name = method.string?.takeIf(::isValidMethod) ?: throw invalid()
            if (hasResponse) throw invalid()
            return if (name == "event") event(envelope) else request(envelope, name)
        }
        return response(envelope)
    }

    private fun event(envelope: JsonObject): WireMessage {
        if ("id" in envelope) throw invalid()
        val params = envelope["params"] as? JsonObject ?: throw invalid()
        val type = params["type"].string?.takeIf { it.isNotEmpty() && utf8Length(it) <= MAXIMUM_METHOD_BYTES }
            ?: throw invalid()
        val payload = params["payload"]
        if (payload != null && payload !is JsonObject) throw invalid()
        val session = params["session_id"]
        if (session != null && session !is JsonNull && session.string == null) throw invalid()
        val seq = params["seq"]
        if (seq != null && seq.integer == null) throw invalid()
        val event = WireMessage.Event(
            type = type,
            sessionID = session.string,
            payload = payload as? JsonObject ?: JsonObject(emptyMap()),
            sequence = seq.integer,
            parameters = params,
        )
        if (type == "request.cancel") cancellation(event)
        return event
    }

    private fun request(envelope: JsonObject, method: String): WireMessage {
        // Backend notifications use method "event"; any other method needs a string ID to be a request.
        val id = envelope["id"].string?.takeIf(::isValidRequestID) ?: throw invalid()
        val params = when (val raw = envelope["params"]) {
            null, JsonNull -> JsonObject(emptyMap())
            is JsonObject -> raw
            else -> throw invalid()
        }
        return WireMessage.Request(id, method, params)
    }

    private fun response(envelope: JsonObject): WireMessage {
        // This client uses string IDs only; a numeric, null or absent ID is never reinterpreted.
        val id = envelope["id"].string?.takeIf(::isValidRequestID) ?: throw invalid()
        if ("params" in envelope) throw invalid()
        val error = envelope["error"] as? JsonObject
        val code = error?.get("code").integer
        val result = envelope["result"]
        return when {
            error != null && code != null -> {
                if (result != null) throw invalid()
                val data = error["data"] as? JsonObject
                WireMessage.Failure(id, code, data?.get("reason").string, refusalText(error["message"].string))
            }
            result != null && "error" !in envelope -> WireMessage.Result(id, result)
            else -> throw invalid()
        }
    }

    /** Counts `{`/`[` depth outside strings before any parsing, so hostile nesting never reaches the parser. */
    private fun validateNesting(bytes: ByteArray, start: Int, end: Int) {
        var depth = 0
        var quoted = false
        var escaped = false
        for (index in start until end) {
            val byte = bytes[index].toInt()
            if (quoted) {
                if (escaped) escaped = false
                else if (byte == 0x5c) escaped = true
                else if (byte == 0x22) quoted = false
            } else if (byte == 0x22) quoted = true
            else if (byte == 0x7b || byte == 0x5b) {
                depth++
                if (depth > MAXIMUM_NESTING) throw tooLarge()
            } else if (byte == 0x7d || byte == 0x5d) depth--
        }
    }

    private fun isBlank(bytes: ByteArray, start: Int, end: Int): Boolean {
        for (index in start until end) {
            val byte = bytes[index].toInt()
            if (byte != 0x20 && byte != 0x0d && byte != 0x09) return false
        }
        return true
    }

    /** Hermes' refusal words as one short line of plain text: breaks, control and format characters become spaces. */
    private fun refusalText(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val words = ArrayList<String>()
        val word = StringBuilder()
        var index = 0
        while (index < raw.length) {
            val point = raw.codePointAt(index)
            index += Character.charCount(point)
            val separator = Character.isWhitespace(point) || Character.isSpaceChar(point) ||
                Character.getType(point).let { it == Character.CONTROL.toInt() || it == Character.FORMAT.toInt() }
            if (separator) {
                if (word.isNotEmpty()) { words += word.toString(); word.setLength(0) }
            } else word.appendCodePoint(point)
        }
        if (word.isNotEmpty()) words += word.toString()
        val line = words.joinToString(" ")
        if (line.isEmpty()) return null
        if (line.codePointCount(0, line.length) <= MAXIMUM_REFUSAL_CHARACTERS) return line
        return line.substring(0, line.offsetByCodePoints(0, MAXIMUM_REFUSAL_CHARACTERS - 1)) + "…"
    }

    private fun invalid() = WireException(WireException.Kind.InvalidResponse)
    private fun tooLarge() = WireException(WireException.Kind.MessageTooLarge)

    private val JsonElement?.string: String?
        get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Only a JSON integer literal that fits 64 bits; `1.0`, `1e2`, strings and null are not integers. */
    private val JsonElement?.integer: Long?
        get() = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toLongOrNull()
}

/** UTF-8 byte length of a string that holds no unpaired surrogate (the parser never produces one). */
internal fun utf8Length(text: String): Int {
    var bytes = 0
    var index = 0
    while (index < text.length) {
        val unit = text[index]
        bytes += when {
            unit.code < 0x80 -> 1
            unit.code < 0x800 -> 2
            unit.isHighSurrogate() -> { index++; 4 }
            else -> 3
        }
        index++
    }
    return bytes
}
