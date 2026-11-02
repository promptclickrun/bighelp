package app.bighelp.hermes.chat

/**
 * Turns physical history rows into transcript items. Rows keep the host's order (never sorted by time or
 * text); a tool request and its result stay recorded evidence and are joined only when the call ID is
 * unique on both sides. History alone never says a tool succeeded or failed.
 */
internal object HistoryProjection {
    class Projected(val items: List<TranscriptItem>, val unsupportedContentRowIds: List<Long>)

    fun itemId(rowId: Long) = "row:$rowId"

    fun project(rows: List<HistoryRow>): Projected {
        val items = ArrayList<TranscriptItem>(rows.size)
        val unsupported = ArrayList<Long>()

        // A call ID joins to a result only when exactly one visible request and one visible result carry it.
        val requestCounts = HashMap<String, Int>()
        val resultRows = HashMap<String, MutableList<HistoryRow>>()
        for (row in rows) {
            if (!row.isVisible) continue
            row.toolCalls.forEach { call -> call.id?.let { requestCounts.merge(it, 1, Int::plus) } }
            if (row.role == "tool" && row.toolCallId != null) resultRows.getOrPut(row.toolCallId) { ArrayList() } += row
        }
        val joined = HashSet<Long>()
        var currentTurn: String? = null

        for (row in rows) {
            if (row.role == "user" && row.isVisible && row.displayKind != "model_switch") currentTurn = "turn:${row.id}"
            if (!row.isVisible) continue
            if (row.hasUnsupportedContent) unsupported += row.id
            val modelSwitch = row.displayKind == "model_switch"
            val reasoning = row.reasoning
            if (!reasoning.isNullOrEmpty()) {
                items += ActivityItem(
                    "reasoning-row:${row.id}", ActivityKind.Reasoning, "Recorded reasoning", reasoning, ActivityLifecycle.Recorded,
                    turnId = currentTurn, origin = ItemOrigin.Saved,
                )
            }
            val role = when {
                modelSwitch -> MessageRole.System
                row.role == "user" -> MessageRole.User
                row.role == "assistant" -> MessageRole.Assistant
                else -> null
            }
            if (role != null) {
                val text = if (row.role == "user" && !modelSwitch) UserMessageDisplay.text(row.text) else row.text
                if (text.isNotEmpty() || row.hasUnsupportedContent) {
                    items += MessageItem(
                        itemId(row.id), role, row.role, text, ItemOrigin.Saved, rowId = row.id, displayKind = row.displayKind,
                        hasUnsupportedContent = row.hasUnsupportedContent, timestampEpochSeconds = row.timestamp,
                        turnDurationMillis = row.turnDurationMillis,
                    )
                }
            } else if (row.role != "tool") {
                // An unknown role stays visible as evidence; it is never shown as a human or assistant reply.
                if (row.text.isNotEmpty() || row.hasUnsupportedContent) {
                    items += MessageItem(
                        itemId(row.id), MessageRole.Unknown, row.role, row.text, ItemOrigin.Saved, rowId = row.id,
                        displayKind = row.displayKind, hasUnsupportedContent = row.hasUnsupportedContent,
                        timestampEpochSeconds = row.timestamp,
                    )
                }
            }
            row.toolCalls.forEachIndexed { index, call ->
                val unique = call.id != null && requestCounts[call.id] == 1
                val candidates = call.id?.let { resultRows[it] }.orEmpty()
                val result = if (unique && candidates.size == 1) candidates.single() else null
                if (result != null) joined += result.id
                items += ActivityItem(
                    "tool-row:${row.id}:$index", ActivityKind.Tool, call.name ?: result?.toolName ?: "Recorded tool", null,
                    ActivityLifecycle.Recorded, toolCallId = call.id.takeIf { unique }, turnId = currentTurn, origin = ItemOrigin.Saved,
                    arguments = call.arguments, result = result?.let { HistoryRow.literalText(it.content) },
                )
            }
            if (row.role == "tool" && row.id !in joined) {
                // Resolved below: a result row is dropped from the list only if its call has already claimed it.
                val claimed = row.toolCallId?.let { id -> requestCounts[id] == 1 && resultRows[id]?.size == 1 } == true
                if (!claimed) {
                    items += ActivityItem(
                        "tool-result-row:${row.id}", ActivityKind.Tool, row.toolName ?: "Recorded tool result", null,
                        ActivityLifecycle.Recorded, toolCallId = row.toolCallId, turnId = currentTurn, origin = ItemOrigin.Saved,
                        result = HistoryRow.literalText(row.content),
                    )
                }
            }
        }
        return Projected(items, unsupported)
    }
}

/** What a person sent, without the notes and hints Hermes adds to the model's copy of a user turn. */
internal object UserMessageDisplay {
    const val DEFAULT_IMAGE_CAPTION = "What do you see in this image?"

    private val MEMORY_BLOCK = Regex("<\\s*memory-context\\s*>.*?<\\s*/\\s*memory-context\\s*>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    private val MEMORY_OPEN = Regex("<\\s*memory-context\\s*>", RegexOption.IGNORE_CASE)
    private val MEMORY_NOTE = Regex("\\[System note:\\s*The following is recalled memory context,[^\\]]*\\]", RegexOption.IGNORE_CASE)
    private val MEMORY_CLOSE = Regex("<\\s*/\\s*memory-context\\s*>", RegexOption.IGNORE_CASE)
    private val IMAGE_AT = Regex("\\[Image attached at: (.+)\\]")
    private val IMAGE_HINT = Regex("\\[Image attached: .+\\]")
    private val BLANK_RUNS = Regex("\\n{3,}")

    fun text(raw: String): String {
        if (!raw.contains("memory-context") && !raw.contains("[Image attached") && !raw.contains("[System note:")) return raw
        var text = MEMORY_BLOCK.replace(raw, "")
        // A truncated row can lose its closing fence; nothing after the opening fence is the person's.
        MEMORY_OPEN.find(text)?.let { text = text.substring(0, it.range.first) }
        text = MEMORY_CLOSE.replace(MEMORY_NOTE.replace(text, ""), "")

        val images = ArrayList<String>()
        var sawImage = false
        val lines = ArrayList<String>()
        for (line in text.split("\n")) {
            val trimmed = line.trim { it == ' ' || it == '\t' }
            val at = IMAGE_AT.matchEntire(trimmed)
            if (at != null) {
                sawImage = true
                reference(at.groupValues[1])?.let { images += "@image:$it" }
            } else if (IMAGE_HINT.matches(trimmed)) {
                sawImage = true
            } else {
                lines += line
            }
        }
        if (sawImage) lines.removeAll { it.trim() == "[screenshot]" || it.trim() == "[image]" }
        var body = BLANK_RUNS.replace(lines.joinToString("\n"), "\n\n").trim()
        if (sawImage && body == DEFAULT_IMAGE_CAPTION) body = ""
        return (listOf(body).filter { it.isNotEmpty() } + images).joinToString("\n")
    }

    private fun reference(path: String): String? {
        if (path.none { it.isWhitespace() || it in "[]\"'`" }) return path
        val quote = listOf("\"", "'", "`").firstOrNull { it !in path } ?: return null
        if (path.any { it == '\n' || it == '\r' }) return null
        return quote + path + quote
    }
}
