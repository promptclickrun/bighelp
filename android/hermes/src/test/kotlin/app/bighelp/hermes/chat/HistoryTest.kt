package app.bighelp.hermes.chat

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import app.bighelp.hermes.HermesException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

internal fun json(text: String): JsonElement = Json.parseToJsonElement(text)
internal fun jsonObject(text: String): JsonObject = json(text) as JsonObject

/** A history row as the host sends it. */
internal fun historyRow(id: Long, role: String, content: String?, session: String = "saved-a", extra: String = ""): JsonObject =
    jsonObject(
        """{"id":$id,"session_id":"$session","role":"$role","content":${content?.let { Json.encodeToString(kotlinx.serialization.serializer<String>(), it) } ?: "null"}$extra}""",
    )

internal fun historyEnvelope(rows: List<JsonObject>, offset: Int, limit: Int, order: String, session: String = "saved-a", profile: String? = "research", key: String = "messages"): JsonObject =
    buildJsonObject {
        put("session_id", session)
        if (profile != null) put("profile", profile)
        put(key, JsonArray(rows))
        put("pagination", buildJsonObject { put("offset", offset); put("limit", limit); put("order", order); put("returned", rows.size) })
    }

class HistoryTest {
    private fun parsed(vararg rows: JsonObject, offset: Int = 0, limit: Int = 40, order: String = "latest") =
        HistoryPage.parse(historyEnvelope(rows.toList(), offset, limit, order), "research", offset, limit, order)

    private fun invalid(block: () -> Unit) {
        val e = runCatching(block).exceptionOrNull()
        assertTrue("Expected InvalidResponse but got $e", e is HermesException && e.kind == HermesException.Kind.InvalidResponse)
    }

    @Test fun rowsNeedAStrictPositiveIdTheExactSessionAndARole() {
        listOf(0L, -1L, 9_007_199_254_740_992L).forEach { bad -> invalid { HistoryRow.parse(historyRow(bad, "user", "x"), "saved-a") } }
        invalid { HistoryRow.parse(jsonObject("""{"id":"7","session_id":"saved-a","role":"user","content":"x"}"""), "saved-a") }
        invalid { HistoryRow.parse(jsonObject("""{"id":7.0,"session_id":"saved-a","role":"user","content":"x"}"""), "saved-a") }
        invalid { HistoryRow.parse(historyRow(7, "user", "x", session = "other"), "saved-a") }
        invalid { HistoryRow.parse(jsonObject("""{"id":7,"session_id":"saved-a","content":"x"}"""), "saved-a") }
        assertEquals(9_007_199_254_740_991L, HistoryRow.parse(historyRow(9_007_199_254_740_991L, "user", "x"), "saved-a").id)
    }

    @Test fun contentIsKeptRawStringArrayPartsJoinAndOtherPartsAreFlaggedNotInvented() {
        assertEquals("verbatim  text", HistoryRow.parse(historyRow(1, "user", "verbatim  text"), "saved-a").text)
        assertEquals("", HistoryRow.parse(historyRow(2, "assistant", null), "saved-a").text)
        val parts = HistoryRow.parse(jsonObject(
            """{"id":3,"session_id":"saved-a","role":"user","content":[{"type":"text","text":"a"},{"type":"input_image","image_url":"x"},{"type":"output_text","text":"b"}]}"""), "saved-a")
        assertEquals("a\nb", parts.text)
        assertTrue(parts.hasUnsupportedContent)
        val number = HistoryRow.parse(jsonObject("""{"id":4,"session_id":"saved-a","role":"user","content":42}"""), "saved-a")
        assertEquals("", number.text)
        assertTrue(number.hasUnsupportedContent)
        // display_content overrides what is rendered but the physical content is retained.
        val shown = HistoryRow.parse(historyRow(5, "user", "raw wire text", extra = ""","display_content":"what the person typed""""), "saved-a")
        assertEquals("what the person typed", shown.text)
        assertEquals("raw wire text", (shown.content as kotlinx.serialization.json.JsonPrimitive).content)
    }

    @Test fun hiddenAndInternalKindsAreNotVisibleAndReasoningAliasesAreRead() {
        assertFalse(HistoryRow.parse(historyRow(1, "user", "x", extra = ""","display_kind":"hidden""""), "saved-a").isVisible)
        assertFalse(HistoryRow.parse(historyRow(2, "user", "x", extra = ""","display_kind":"internal_notification""""), "saved-a").isVisible)
        assertTrue(HistoryRow.parse(historyRow(3, "user", "x", extra = ""","display_kind":"model_switch""""), "saved-a").isVisible)
        assertEquals("because", HistoryRow.parse(historyRow(4, "assistant", "y", extra = ""","reasoning":"because""""), "saved-a").reasoning)
        assertEquals("first", HistoryRow.parse(historyRow(5, "assistant", "y", extra = ""","reasoning_content":"first","reasoning":"second""""), "saved-a").reasoning)
        invalid { HistoryRow.parse(historyRow(6, "assistant", "y", extra = ""","reasoning":7"""), "saved-a") }
    }

    @Test fun timestampsAreFiniteEpochSecondsAndABadDurationNeverHidesTheRow() {
        assertEquals(1_792_000_000.5, HistoryRow.parse(historyRow(1, "user", "x", extra = ""","timestamp":1792000000.5"""), "saved-a").timestamp!!, 0.0)
        invalid { HistoryRow.parse(historyRow(2, "user", "x", extra = ""","timestamp":-1"""), "saved-a") }
        invalid { HistoryRow.parse(historyRow(3, "user", "x", extra = ""","timestamp":253402300800"""), "saved-a") }
        assertNull(HistoryRow.parse(historyRow(4, "assistant", "x", extra = ""","turn_duration_ms":-5"""), "saved-a").turnDurationMillis)
        assertEquals(1200, HistoryRow.parse(historyRow(5, "assistant", "x", extra = ""","turn_duration_ms":1200"""), "saved-a").turnDurationMillis)
    }

    @Test fun aPageMustEchoOffsetLimitOrderAndReturnedExactly() {
        val rows = listOf(historyRow(1, "user", "a"), historyRow(2, "assistant", "b"))
        assertEquals(2, HistoryPage.parse(historyEnvelope(rows, 0, 40, "latest"), "research", 0, 40, "latest").rows.size)
        invalid { HistoryPage.parse(historyEnvelope(rows, 5, 40, "latest"), "research", 0, 40, "latest") }
        invalid { HistoryPage.parse(historyEnvelope(rows, 0, 41, "latest"), "research", 0, 40, "latest") }
        invalid { HistoryPage.parse(historyEnvelope(rows, 0, 40, "oldest"), "research", 0, 40, "latest") }
        invalid { HistoryPage.parse(historyEnvelope(rows, 0, 40, "latest", profile = "other"), "research", 0, 40, "latest") }
        val liar = historyEnvelope(rows, 0, 40, "latest").let { JsonObject(it + ("pagination" to buildJsonObject { put("offset", 0); put("limit", 40); put("order", "latest"); put("returned", 3) })) }
        invalid { HistoryPage.parse(liar, "research", 0, 40, "latest") }
        // `data` is an accepted alias; a missing profile echo is allowed.
        assertEquals(2, HistoryPage.parse(historyEnvelope(rows, 0, 40, "latest", profile = null, key = "data"), "research", 0, 40, "latest").rows.size)
        // More rows than the limit are refused even when they are consistent with themselves.
        val big = (1L..3L).map { historyRow(it, "user", "x") }
        invalid { HistoryPage.parse(historyEnvelope(big, 0, 2, "latest"), "research", 0, 2, "latest") }
    }

    @Test fun duplicatePhysicalRowIdsMeanTheHistoryMovedAndAreRefused() {
        val dup = listOf(historyRow(1, "user", "a"), historyRow(1, "assistant", "b"))
        val e = assertThrows(ChatException::class.java) { HistoryPage.parse(historyEnvelope(dup, 0, 40, "latest"), "research", 0, 40, "latest") }
        assertEquals(ChatError.Kind.HistoryChanged, e.error.kind)
    }

    private fun page(ids: LongRange, offset: Int = 0, limit: Int = 4, text: (Long) -> String = { "row $it" }) =
        parsed(*ids.map { historyRow(it, if (it % 2 == 1L) "user" else "assistant", text(it)) }.toTypedArray(), offset = offset, limit = limit)

    @Test fun aFullFirstPageOffersAnOlderPageAndAShortOneDoesNot() {
        assertEquals(4, HistoryWindow.fresh(page(7L..10L)).nextOffset)
        assertNull(HistoryWindow.fresh(page(9L..10L)).nextOffset)
    }

    @Test fun anOlderPageOverlapsTheOldestHeldRowByteForByteAndPrepends() {
        val window = HistoryWindow.fresh(page(7L..10L))
        // offset - 1 with limit + 1: the page ends with the held oldest row.
        val older = parsed(*(3L..7L).map { historyRow(it, "user", "row $it") }.toTypedArray(), offset = 3, limit = 5)
        val merged = HistoryWindow.prepended(window, older)
        assertEquals((3L..10L).toList(), merged.rows.map { it.id })
        assertEquals("A full older page offers another", 8, merged.nextOffset)
    }

    @Test fun aShiftedOrRewrittenBoundaryIsRefusedNotMerged() {
        val window = HistoryWindow.fresh(page(7L..10L))
        val rewritten = parsed(*(3L..7L).map { historyRow(it, "user", if (it == 7L) "EDITED" else "row $it") }.toTypedArray(), offset = 3, limit = 5)
        assertEquals(ChatError.Kind.HistoryChanged, assertThrows(ChatException::class.java) { HistoryWindow.prepended(window, rewritten) }.error.kind)
        val shifted = parsed(*(2L..6L).map { historyRow(it, "user", "row $it") }.toTypedArray(), offset = 3, limit = 5)
        assertEquals(ChatError.Kind.HistoryChanged, assertThrows(ChatException::class.java) { HistoryWindow.prepended(window, shifted) }.error.kind)
        val repeating = parsed(*(listOf(8L) + (4L..7L)).map { historyRow(it, "user", "row $it") }.toTypedArray(), offset = 3, limit = 5)
        assertEquals(ChatError.Kind.HistoryChanged, assertThrows(ChatException::class.java) { HistoryWindow.prepended(window, repeating) }.error.kind)
    }

    @Test fun aNewestPageRefreshKeepsEarlierHeldPagesWhenItLinesUpAndStartsOverWhenItDoesNot() {
        val held = HistoryWindow.prepended(HistoryWindow.fresh(page(7L..10L)),
            parsed(*(3L..7L).map { historyRow(it, "user", "row $it") }.toTypedArray(), offset = 3, limit = 5))
        // Two new rows arrived: the newest page now starts inside what is held and its prefix matches the held tail.
        val refreshed = HistoryWindow.refreshed(held, page(9L..12L))
        assertEquals((3L..12L).toList(), refreshed.rows.map { it.id })
        // A page that does not start inside the held rows replaces the window.
        val unrelated = HistoryWindow.refreshed(held, page(20L..23L))
        assertEquals((20L..23L).toList(), unrelated.rows.map { it.id })
        // A page whose boundary row changed is not aligned either.
        val edited = HistoryWindow.refreshed(held, page(9L..12L) { if (it == 9L) "EDITED" else "row $it" })
        assertEquals((9L..12L).toList(), edited.rows.map { it.id })
    }

    @Test fun retainedHistoryIsCappedByRowsAndByBytes() {
        val fat = "x".repeat(1_000_000)
        val rows = (1L..34L).map { historyRow(it, "assistant", fat) }.toTypedArray()
        val e = assertThrows(ChatException::class.java) { HistoryWindow.fresh(parsed(*rows, limit = 400)) }
        assertEquals("34 MB of rows exceeds the 32 MiB retained read", ChatError.Kind.TooLarge, e.error.kind)
    }

    @Test fun onlyFourWindowsAndSixtyFourMebibytesStayCached() {
        val cache = HistoryWindowCache()
        val refs = (1..5).map { ConversationRef("research", "a$it") }
        refs.forEach { cache.put(it, HistoryWindow.fresh(page(1L..2L))) }
        assertEquals(4, cache.size)
        assertNull("The oldest window was evicted, with its paging offset", cache[refs[0]])
        assertTrue(cache[refs[4]] != null)
        val fat = HistoryWindow.fresh(parsed(*(1L..30L).map { historyRow(it, "assistant", "y".repeat(1_000_000)) }.toTypedArray(), limit = 400))
        val roomy = HistoryWindowCache()
        roomy.put(refs[0], fat); roomy.put(refs[1], fat); roomy.put(refs[2], fat)
        assertTrue("Three 30 MB windows cannot all fit 64 MiB", roomy.size < 3)
    }

    @Test fun theProjectionKeepsHostOrderJoinsOnlyUniqueToolCallsAndNeverInventsOutcomes() {
        val rows = listOf(
            historyRow(1, "user", "list the files"),
            historyRow(2, "assistant", "", extra = ""","reasoning":"I will look","tool_calls":[{"id":"call-1","function":{"name":"ls","arguments":"{\"path\":\".\"}"}}]"""),
            historyRow(3, "tool", "a.txt", extra = ""","tool_call_id":"call-1","tool_name":"ls""""),
            historyRow(4, "assistant", "There is one file."),
        ).map { HistoryRow.parse(it, "saved-a") }
        val items = HistoryProjection.project(rows).items
        assertEquals(listOf("row:1", "reasoning-row:2", "tool-row:2:0", "row:4"), items.map { it.id })
        val tool = items[2] as ActivityItem
        assertEquals("ls", tool.title)
        assertEquals("a.txt", tool.result)
        assertEquals("""{"path":"."}""", tool.arguments)
        assertEquals("History alone never says a tool succeeded", ActivityLifecycle.Recorded, tool.lifecycle)
        assertEquals("call-1", tool.toolCallId)
        assertEquals("turn:1", tool.turnId)
    }

    @Test fun aDuplicateToolCallIdIsNotJoinedAndStaysSeparateEvidence() {
        val rows = listOf(
            historyRow(1, "assistant", "", extra = ""","tool_calls":[{"id":"dup","function":{"name":"a"}},{"id":"dup","function":{"name":"b"}}]"""),
            historyRow(2, "tool", "r1", extra = ""","tool_call_id":"dup""""),
        ).map { HistoryRow.parse(it, "saved-a") }
        val items = HistoryProjection.project(rows).items.filterIsInstance<ActivityItem>()
        assertEquals(listOf("tool-row:1:0", "tool-row:1:1", "tool-result-row:2"), items.map { it.id })
        assertTrue(items.take(2).all { it.result == null && it.toolCallId == null })
    }

    @Test fun modelSwitchRowsAreSystemMetadataUnknownRolesAreEvidenceAndHiddenRowsAreAbsent() {
        val rows = listOf(
            historyRow(1, "user", "[switched to model x]", extra = ""","display_kind":"model_switch""""),
            historyRow(2, "user", "secret note", extra = ""","display_kind":"hidden""""),
            historyRow(3, "narrator", "unusual"),
            historyRow(4, "user", "hello", extra = ""","content":[{"type":"input_image"}]"""),
        ).map { HistoryRow.parse(it, "saved-a") }
        val project = HistoryProjection.project(rows)
        val items = project.items.filterIsInstance<MessageItem>()
        assertEquals(listOf("row:1", "row:3"), items.take(2).map { it.id })
        assertEquals(MessageRole.System, items[0].role)
        assertEquals(MessageRole.Unknown, items[1].role)
        assertEquals("narrator", items[1].rawRole)
        assertFalse(items.any { it.text == "secret note" })
        assertEquals(listOf(4L), project.unsupportedContentRowIds)
    }

    @Test fun theMemoryContextHostAddsToAUserTurnIsNotShownAsThePersonsWords() {
        val raw = "Fix the bug\n<memory-context>\nremembered: they like tea\n</memory-context>"
        assertEquals("Fix the bug", UserMessageDisplay.text(raw))
        assertEquals("Fix it", UserMessageDisplay.text("Fix it\n<memory-context>cut off"))
        assertEquals("@image:/tmp/a.png", UserMessageDisplay.text("[Image attached at: /tmp/a.png]\n[screenshot]\nWhat do you see in this image?"))
        assertEquals("plain", UserMessageDisplay.text("plain"))
        val projected = HistoryProjection.project(listOf(HistoryRow.parse(historyRow(1, "user", raw), "saved-a")))
        assertEquals("Fix the bug", (projected.items.single() as MessageItem).text)
    }
}
