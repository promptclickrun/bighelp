package app.bighelp.android

/** One block of an agent's reply. Only what chat output really uses; anything else reads as a paragraph. */
sealed interface MdBlock {
    data class Paragraph(val text: String) : MdBlock
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Bullets(val ordered: Boolean, val items: List<String>) : MdBlock
    data class Code(val language: String, val text: String) : MdBlock
}

/** A run of text with the marks that apply to it. */
data class MdSpan(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false)

/**
 * A small, forgiving Markdown reader for chat replies: fenced code, headings, lists, and inline bold, italic,
 * code and links. It never throws and never drops text: a marker that does not match stays as typed, an unclosed
 * code fence takes the rest of the message (so a reply that is still streaming does not flicker), and the
 * address of a link is shown whenever its label is something else.
 */
object Markdown {
    private val listItem = Regex("""^\s{0,3}(?:([-*+])|(\d{1,9})[.)])\s+(.*)$""")
    private val heading = Regex("""^(#{1,6})\s+(.*)$""")

    fun blocks(text: String): List<MdBlock> {
        val result = ArrayList<MdBlock>()
        val paragraph = ArrayList<String>()
        fun flush() {
            if (paragraph.isNotEmpty()) { result += MdBlock.Paragraph(paragraph.joinToString("\n")); paragraph.clear() }
        }
        val lines = text.lines()
        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            val trimmed = line.trim()
            when {
                trimmed.startsWith("```") -> {
                    flush()
                    val language = trimmed.removePrefix("```").trim()
                    val body = ArrayList<String>()
                    index++
                    while (index < lines.size && !lines[index].trim().startsWith("```")) { body += lines[index]; index++ }
                    result += MdBlock.Code(language, body.joinToString("\n"))
                }
                trimmed.isEmpty() -> flush()
                heading.matches(line) -> {
                    flush()
                    val match = heading.matchEntire(line)!!
                    result += MdBlock.Heading(match.groupValues[1].length, match.groupValues[2].trim())
                }
                listItem.matches(line) -> {
                    flush()
                    val first = listItem.matchEntire(line)!!
                    val ordered = first.groupValues[2].isNotEmpty()
                    val items = ArrayList<String>()
                    var current = index
                    while (current < lines.size) {
                        val match = listItem.matchEntire(lines[current]) ?: break
                        if ((match.groupValues[2].isNotEmpty()) != ordered) break
                        items += match.groupValues[3].trim()
                        current++
                    }
                    result += MdBlock.Bullets(ordered, items)
                    index = current - 1
                }
                else -> paragraph += line.trimEnd()
            }
            index++
        }
        flush()
        return result
    }

    fun spans(text: String): List<MdSpan> {
        val spans = ArrayList<MdSpan>()
        val plain = StringBuilder()
        fun flushPlain() { if (plain.isNotEmpty()) { spans += MdSpan(plain.toString()); plain.clear() } }
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                c == '`' -> {
                    val end = text.indexOf('`', i + 1)
                    if (end > i + 1) { flushPlain(); spans += MdSpan(text.substring(i + 1, end), code = true); i = end + 1 } else { plain.append(c); i++ }
                }
                c == '*' && text.startsWith("**", i) -> {
                    val end = text.indexOf("**", i + 2)
                    if (end > i + 2) { flushPlain(); spans += MdSpan(text.substring(i + 2, end), bold = true); i = end + 2 } else { plain.append("**"); i += 2 }
                }
                c == '*' && i + 1 < text.length && !text[i + 1].isWhitespace() -> {
                    val end = text.indexOf('*', i + 1)
                    if (end > i + 1 && !text[end - 1].isWhitespace()) { flushPlain(); spans += MdSpan(text.substring(i + 1, end), italic = true); i = end + 1 } else { plain.append(c); i++ }
                }
                c == '[' -> {
                    val close = text.indexOf("](", i + 1)
                    val end = if (close > i) text.indexOf(')', close + 2) else -1
                    if (close > i && end > close + 2 && '\n' !in text.substring(i, end)) {
                        val label = text.substring(i + 1, close)
                        val address = text.substring(close + 2, end)
                        plain.append(if (label == address) label else "$label ($address)")
                        i = end + 1
                    } else { plain.append(c); i++ }
                }
                else -> { plain.append(c); i++ }
            }
        }
        flushPlain()
        return mergeAdjacent(spans)
    }

    private fun mergeAdjacent(spans: List<MdSpan>): List<MdSpan> {
        val merged = ArrayList<MdSpan>()
        for (span in spans) {
            val last = merged.lastOrNull()
            if (last != null && last.bold == span.bold && last.italic == span.italic && last.code == span.code) {
                merged[merged.lastIndex] = last.copy(text = last.text + span.text)
            } else merged += span
        }
        return merged
    }
}
