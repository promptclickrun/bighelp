package app.bighelp.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTest {
    @Test fun plainTextIsOneParagraphWithItsLineBreaksKept() {
        assertEquals(listOf(MdBlock.Paragraph("one\ntwo")), Markdown.blocks("one\ntwo"))
        assertEquals(listOf(MdBlock.Paragraph("a"), MdBlock.Paragraph("b")), Markdown.blocks("a\n\nb"))
        assertTrue(Markdown.blocks("").isEmpty())
        assertTrue(Markdown.blocks("  \n\n ").isEmpty())
    }

    @Test fun aFencedBlockKeepsEveryCharacterExactlyAndNeverReadsMarkdownInside() {
        val blocks = Markdown.blocks("Before\n```kotlin\nval a = **not bold**\n\n  indented\n```\nAfter")
        assertEquals(
            listOf(MdBlock.Paragraph("Before"), MdBlock.Code("kotlin", "val a = **not bold**\n\n  indented"), MdBlock.Paragraph("After")),
            blocks,
        )
    }

    @Test fun anUnclosedFenceTakesTheRestOfTheMessageAsCodeSoStreamingTextDoesNotFlicker() {
        assertEquals(listOf(MdBlock.Code("", "partial\nlines")), Markdown.blocks("```\npartial\nlines"))
    }

    @Test fun headingsAndListsAreRecognizedOnlyAtTheStartOfALine() {
        val blocks = Markdown.blocks("## Title\n- one\n- two\n\n1. first\n2) second\nnot # a heading")
        assertEquals(MdBlock.Heading(2, "Title"), blocks[0])
        assertEquals(MdBlock.Bullets(ordered = false, items = listOf("one", "two")), blocks[1])
        assertEquals(MdBlock.Bullets(ordered = true, items = listOf("first", "second")), blocks[2])
        assertEquals(MdBlock.Paragraph("not # a heading"), blocks[3])
        assertEquals(MdBlock.Paragraph("#hashtag"), Markdown.blocks("#hashtag").single())
    }

    @Test fun inlineMarksBecomeSpansAndAnUnmatchedMarkerStaysLiteral() {
        assertEquals(
            listOf(MdSpan("a "), MdSpan("bold", bold = true), MdSpan(" and "), MdSpan("it", italic = true), MdSpan(" and "), MdSpan("code", code = true)),
            Markdown.spans("a **bold** and *it* and `code`"),
        )
        assertEquals(listOf(MdSpan("2 * 3 = 6 and **open")), Markdown.spans("2 * 3 = 6 and **open"))
        assertEquals(listOf(MdSpan("snake_case_name")), Markdown.spans("snake_case_name"))
    }

    @Test fun aLinkShowsItsLabelAndKeepsTheAddressVisibleOnlyWhenTheLabelIsTheAddress() {
        assertEquals(listOf(MdSpan("the docs (https://example.test/x)")), Markdown.spans("[the docs](https://example.test/x)"))
        assertEquals(listOf(MdSpan("https://example.test/x")), Markdown.spans("[https://example.test/x](https://example.test/x)"))
    }

    @Test fun codeSpansTakeEverythingLiterallyIncludingMarkers() {
        assertEquals(listOf(MdSpan("**x**", code = true)), Markdown.spans("`**x**`"))
    }
}
