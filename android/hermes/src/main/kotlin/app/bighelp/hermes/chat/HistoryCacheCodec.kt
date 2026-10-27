package app.bighelp.hermes.chat

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The newest retained rows of one chat, stored only to show something at once. Losing it changes nothing durable.
 * Like every other record, the body repeats its exact scope and a decode checks it against the key's scope, so a
 * mis-addressed or stale file can never show one conversation's text as another's.
 */
internal object HistoryCacheCodec {
    private const val SCHEMA = 2

    fun encode(window: HistoryWindow, scope: ConversationScope): ByteArray = JsonObject(
        buildJsonObject {
            put("v", SCHEMA); put("stored", window.storedId); put("next", window.nextOffset)
            put("rows", JsonArray(window.rows.map { it.raw }))
        } + mapOf(
            "computer" to JsonPrimitive(scope.host.computerId), "endpoint" to JsonPrimitive(scope.host.endpoint),
            "principal" to JsonPrimitive(scope.host.principal), "profile" to JsonPrimitive(scope.profile),
            "anchor" to JsonPrimitive(scope.anchor),
        ),
    ).toString().toByteArray(Charsets.UTF_8)

    fun decode(bytes: ByteArray, scope: ConversationScope): HistoryWindow {
        val body = parseRecord(bytes)
        if (body["v"].asInt != SCHEMA) corrupt()
        if (body["computer"].asString != scope.host.computerId || body["endpoint"].asString != scope.host.endpoint ||
            body["principal"].asString != scope.host.principal || body["profile"].asString != scope.profile || body["anchor"].asString != scope.anchor
        ) corrupt()
        val stored = body["stored"].asString ?: corrupt()
        val rows = (body["rows"].asArray ?: corrupt()).map { HistoryRow.parse(it, stored) }
        if (rows.map { it.id }.toSet().size != rows.size) corrupt()
        return HistoryWindow(stored, rows, body["next"].asInt)
    }
}
