package app.bighelp.hermes

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * RFC 8259 parser for one gateway line. Trailing commas, comments, leading zeros, non-finite numbers,
 * duplicate object keys and unpaired surrogate escapes are all rejected: the wire layer treats any of
 * them as an invalid frame instead of guessing which value a host meant.
 *
 * Integers that fit a signed 64-bit value stay [Long]; every other number must be a finite [Double], so
 * `1.0` is deliberately not an integer cursor.
 */
internal class StrictJson private constructor(private val text: String) {
    private var position = 0

    class Malformed : Exception() {
        // A parse failure carries no frame text and no stack: it only means "reject the frame".
        override fun fillInStackTrace(): Throwable = this
    }

    companion object {
        const val MAXIMUM_DEPTH = 64

        /** @throws Malformed for any grammar violation or nesting beyond [MAXIMUM_DEPTH]. */
        fun parse(text: String): JsonElement {
            val parser = StrictJson(text)
            parser.skipWhitespace()
            val value = parser.value(depth = 0)
            parser.skipWhitespace()
            if (parser.position != text.length) throw Malformed()
            return value
        }
    }

    private fun value(depth: Int): JsonElement {
        if (position >= text.length) throw Malformed()
        return when (val c = text[position]) {
            '{' -> obj(depth + 1)
            '[' -> array(depth + 1)
            '"' -> JsonPrimitive(string())
            't' -> literal("true", JsonPrimitive(true))
            'f' -> literal("false", JsonPrimitive(false))
            'n' -> literal("null", JsonNull)
            else -> if (c == '-' || c in '0'..'9') number() else throw Malformed()
        }
    }

    private fun obj(depth: Int): JsonElement {
        if (depth > MAXIMUM_DEPTH) throw Malformed()
        position++ // {
        val members = LinkedHashMap<String, JsonElement>()
        skipWhitespace()
        if (peek() == '}') { position++; return JsonObject(members) }
        while (true) {
            skipWhitespace()
            if (peek() != '"') throw Malformed()
            val key = string()
            skipWhitespace()
            if (peek() != ':') throw Malformed()
            position++
            skipWhitespace()
            val member = value(depth)
            // First-wins (Foundation) and last-wins (most others) disagree; a duplicate is never legitimate.
            if (members.put(key, member) != null) throw Malformed()
            skipWhitespace()
            when (peek()) {
                ',' -> position++
                '}' -> { position++; return JsonObject(members) }
                else -> throw Malformed()
            }
        }
    }

    private fun array(depth: Int): JsonElement {
        if (depth > MAXIMUM_DEPTH) throw Malformed()
        position++ // [
        val elements = ArrayList<JsonElement>()
        skipWhitespace()
        if (peek() == ']') { position++; return JsonArray(elements) }
        while (true) {
            skipWhitespace()
            elements += value(depth)
            skipWhitespace()
            when (peek()) {
                ',' -> position++
                ']' -> { position++; return JsonArray(elements) }
                else -> throw Malformed()
            }
        }
    }

    private fun string(): String {
        position++ // opening quote
        val out = StringBuilder()
        while (true) {
            if (position >= text.length) throw Malformed()
            val c = text[position++]
            when {
                c == '"' -> return out.toString()
                c < ' ' -> throw Malformed() // raw control characters must be escaped
                c == '\\' -> {
                    if (position >= text.length) throw Malformed()
                    when (text[position++]) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000c')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> out.append(unicodeEscape())
                        else -> throw Malformed()
                    }
                }
                // An unpaired surrogate cannot be echoed back as the same UTF-8 bytes. Valid pairs are
                // consumed together, so any surrogate seen on its own is a lone one.
                c.isHighSurrogate() -> {
                    if (position >= text.length || !text[position].isLowSurrogate()) throw Malformed()
                    out.append(c).append(text[position++])
                }
                c.isLowSurrogate() -> throw Malformed()
                else -> out.append(c)
            }
        }
    }

    private fun unicodeEscape(): String {
        val first = hex4()
        val unit = first.toChar()
        return when {
            unit.isHighSurrogate() -> {
                if (position + 1 >= text.length || text[position] != '\\' || text[position + 1] != 'u') throw Malformed()
                position += 2
                val low = hex4().toChar()
                if (!low.isLowSurrogate()) throw Malformed()
                String(charArrayOf(unit, low))
            }
            unit.isLowSurrogate() -> throw Malformed()
            else -> unit.toString()
        }
    }

    private fun hex4(): Int {
        if (position + 4 > text.length) throw Malformed()
        var result = 0
        repeat(4) {
            val digit = Character.digit(text[position++], 16)
            // Character.digit also accepts fullwidth and other non-ASCII digits.
            if (digit < 0 || text[position - 1].code > 0x7f) throw Malformed()
            result = result * 16 + digit
        }
        return result
    }

    private fun number(): JsonElement {
        val start = position
        if (peek() == '-') position++
        when (peek()) {
            '0' -> position++
            in '1'..'9' -> digits()
            else -> throw Malformed()
        }
        var integral = true
        if (peek() == '.') {
            integral = false
            position++
            if (peek() !in '0'..'9') throw Malformed()
            digits()
        }
        if (peek() == 'e' || peek() == 'E') {
            integral = false
            position++
            if (peek() == '+' || peek() == '-') position++
            if (peek() !in '0'..'9') throw Malformed()
            digits()
        }
        val raw = text.substring(start, position)
        if (integral) raw.toLongOrNull()?.let { return JsonPrimitive(it) }
        val double = raw.toDouble()
        if (!double.isFinite()) throw Malformed()
        return JsonPrimitive(double)
    }

    private fun digits() {
        while (peek() in '0'..'9') position++
    }

    private fun literal(word: String, value: JsonElement): JsonElement {
        if (!text.startsWith(word, position)) throw Malformed()
        position += word.length
        return value
    }

    private fun peek(): Char = if (position < text.length) text[position] else '\u0000'

    private fun skipWhitespace() {
        while (position < text.length) {
            when (text[position]) {
                ' ', '\t', '\n', '\r' -> position++
                else -> return
            }
        }
    }
}
