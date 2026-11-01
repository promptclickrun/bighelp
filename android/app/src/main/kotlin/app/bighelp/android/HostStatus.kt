package app.bighelp.android

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * What a Hermes host's public `GET /api/status` says about signing in, decoded exactly as
 * `docs/hermes/CONNECTION.md` §3 describes. Anything else is `null`: the caller treats it as "no Hermes
 * answered" and never shows the body.
 */
internal data class HostStatus(val authRequired: Boolean, val authFlows: List<String>) {
    /** Browser sign-in is offered only by a host that asks for sign-in and lists the exact flow name. */
    val browserSignIn: Boolean get() = authRequired && NATIVE_PKCE in authFlows

    companion object {
        const val MAXIMUM_BYTES = 16_384
        private const val NATIVE_PKCE = "native_pkce"
        private const val MAXIMUM_FLOWS = 32
        private const val MAXIMUM_FLOW_BYTES = 128

        fun parse(bytes: ByteArray): HostStatus? {
            if (bytes.size > MAXIMUM_BYTES) return null
            val text = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
            } catch (_: CharacterCodingException) {
                return null
            }
            val parsed = try {
                Json.parseToJsonElement(text)
            } catch (_: SerializationException) {
                return null
            }
            val root = parsed as? JsonObject ?: return null
            // A parser that keeps the last duplicate would let two readers see different answers.
            if (hasDuplicateTopLevelKey(text)) return null

            val authRequired = root["auth_required"].strictBoolean() ?: return null
            val flows = when (val element = root["auth_flows"]) {
                null, JsonNull -> emptyList()
                is JsonArray -> decodeFlows(element) ?: return null
                else -> return null
            }
            return HostStatus(authRequired, flows)
        }

        private fun JsonElement?.strictBoolean(): Boolean? {
            val primitive = this as? JsonPrimitive ?: return null
            // `"true"` (a string) is not a Boolean, even though its text reads like one.
            if (primitive.isString) return null
            return when (primitive.content) {
                "true" -> true
                "false" -> false
                else -> null
            }
        }

        private fun decodeFlows(array: JsonArray): List<String>? {
            if (array.size > MAXIMUM_FLOWS) return null
            val flows = ArrayList<String>(array.size)
            for (element in array) {
                val primitive = element as? JsonPrimitive ?: return null
                val name = primitive.takeIf { it.isString }?.content ?: return null
                if (name.isEmpty() || !isWellFormed(name) || name.toByteArray(Charsets.UTF_8).size > MAXIMUM_FLOW_BYTES) {
                    return null
                }
                flows += name
            }
            return flows.takeIf { it.toSet().size == it.size }
        }

        /** No unpaired surrogates, which a `\ud800` escape can smuggle into an otherwise valid string. */
        private fun isWellFormed(text: String): Boolean {
            var i = 0
            while (i < text.length) {
                val c = text[i]
                if (c.isHighSurrogate()) {
                    if (i + 1 >= text.length || !text[i + 1].isLowSurrogate()) return false
                    i++
                } else if (c.isLowSurrogate()) {
                    return false
                }
                i++
            }
            return true
        }

        /** Scans well-formed JSON (already parsed) for an object key repeated directly under the root. */
        private fun hasDuplicateTopLevelKey(text: String): Boolean {
            val seen = HashSet<String>()
            var depth = 0
            var i = 0
            while (i < text.length) {
                when (text[i]) {
                    '{', '[' -> depth++
                    '}', ']' -> depth--
                    '"' -> {
                        var end = i + 1
                        while (text[end] != '"') end += if (text[end] == '\\') 2 else 1
                        var next = end + 1
                        while (text[next].isWhitespace()) next++
                        if (depth == 1 && text[next] == ':') {
                            val key = (Json.parseToJsonElement(text.substring(i, end + 1)) as JsonPrimitive).content
                            if (!seen.add(key)) return true
                        }
                        i = end
                    }
                }
                i++
            }
            return false
        }
    }
}
