package app.bighelp.hermes.chat

import app.bighelp.hermes.HermesException
import app.bighelp.hermes.StrictJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Strict accessors for host answers and stored records. A value of the wrong type is absent, never coerced:
// `"1"` is not a number, `1.0` is not an integer, `1` is not a Boolean.

internal val JsonElement?.asString: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

internal val JsonElement?.asLong: Long?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toLongOrNull()

internal val JsonElement?.asInt: Int? get() = asLong?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

internal val JsonElement?.asDouble: Double?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toDoubleOrNull()?.takeIf { it.isFinite() }

internal val JsonElement?.asBool: Boolean?
    get() = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.let {
        when (it) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

internal val JsonElement?.asObject: JsonObject? get() = this as? JsonObject
internal val JsonElement?.asArray: JsonArray? get() = this as? JsonArray
internal val JsonElement?.isAbsent: Boolean get() = this == null || this is JsonNull

internal fun invalidResponse(): HermesException = HermesException(HermesException.Kind.InvalidResponse)

/** Parses a stored record. Any grammar failure is a corrupt record, never a silent default. */
internal fun parseRecord(bytes: ByteArray): JsonObject {
    val text = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        throw ChatStoreException(ChatStoreException.Kind.Corrupt)
    }
    return try {
        StrictJson.parse(text) as? JsonObject ?: throw ChatStoreException(ChatStoreException.Kind.Corrupt)
    } catch (_: StrictJson.Malformed) {
        throw ChatStoreException(ChatStoreException.Kind.Corrupt)
    }
}

internal fun corrupt(): Nothing = throw ChatStoreException(ChatStoreException.Kind.Corrupt)
