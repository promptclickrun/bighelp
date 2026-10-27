package app.bighelp.hermes.chat

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The newest retained rows of one chat, stored only to show something at once. Losing it changes nothing durable. */
internal object HistoryCacheCodec {
    fun encode(window: HistoryWindow): ByteArray = buildJsonObject {
        put("v", 1); put("stored", window.storedId); put("next", window.nextOffset)
        put("rows", JsonArray(window.rows.map { it.raw }))
    }.toString().toByteArray(Charsets.UTF_8)

    fun decode(bytes: ByteArray): HistoryWindow {
        val body = parseRecord(bytes)
        if (body["v"].asInt != 1) corrupt()
        val stored = body["stored"].asString ?: corrupt()
        val rows = (body["rows"].asArray ?: corrupt()).map { HistoryRow.parse(it, stored) }
        if (rows.map { it.id }.toSet().size != rows.size) corrupt()
        return HistoryWindow(stored, rows, body["next"].asInt)
    }
}
