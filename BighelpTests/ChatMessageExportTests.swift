import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct ChatMessageExportTests {
    // MARK: Messages (Unicode styling)

    @Test func boldBecomesSansSerifBoldLettersAndDigits() {
        #expect(ChatMessageExport.styled("**Az 09**") == "𝗔𝘇 𝟬𝟵")
    }

    @Test func italicBecomesSansSerifItalicAndDigitsStayPlain() {
        #expect(ChatMessageExport.styled("*Az 09*") == "𝘈𝘻 09")
    }

    @Test func boldItalicBecomesSansSerifBoldItalic() {
        #expect(ChatMessageExport.styled("***Az 1***") == "𝘼𝙯 𝟭")
    }

    @Test func inlineCodeAndCodeBlocksBecomeMonospace() {
        #expect(ChatMessageExport.styled("Run `ls -a 2`") == "Run 𝚕𝚜 -𝚊 𝟸")
        #expect(ChatMessageExport.styled("```\nlet x = 1\n```") == "𝚕𝚎𝚝 𝚡 = 𝟷")
    }

    @Test func headingsAreBoldOnTheirOwnLine() {
        #expect(ChatMessageExport.styled("# Plan\nToday") == "𝗣𝗹𝗮𝗻\n\nToday")
        #expect(ChatMessageExport.plain("## Plan\nToday") == "Plan\n\nToday")
    }

    @Test func strikethroughFollowsEachCharacterWithACombiningStroke() {
        #expect(ChatMessageExport.styled("~~no~~ yes") == "n\u{0336}o\u{0336} yes")
    }

    @Test func onlyASCIILettersAndDigitsAreStyled() {
        #expect(ChatMessageExport.styled("**Café 日本 🙂!**") == "𝗖𝗮𝗳é 日本 🙂!")
    }

    @Test func linkTextIsStyledButItsAddressIsNot() {
        #expect(ChatMessageExport.styled("**[Docs](https://example.com/a)**") == "𝗗𝗼𝗰𝘀 (https://example.com/a)")
    }

    // MARK: Plain text

    @Test func plainTextHasNoMarkupAtAll() {
        let source = "# Title\n\n**bold** *it* `code` ~~gone~~ [site](https://example.com)\n\n> quoted\n\n- item"
        let plain = ChatMessageExport.plain(source)
        #expect(plain == "Title\n\nbold it code gone site (https://example.com)\n\nquoted\n\n• item")
        for mark in ["**", "*", "`", "~~", "#", "[", "](", ">"] {
            #expect(!plain.contains(mark), "\(mark) left in \(plain)")
        }
    }

    @Test func nestedListsIndentUnderTheirParent() {
        let source = "- one\n  - inner\n- two"
        #expect(ChatMessageExport.plain(source) == "• one\n    • inner\n• two")
    }

    @Test func numberedListsKeepTheirNumbers() {
        #expect(ChatMessageExport.plain("1. first\n2. second\n3. third") == "1. first\n2. second\n3. third")
    }

    @Test func linksShowTheirAddressUnlessTheTextIsTheAddress() {
        #expect(ChatMessageExport.plain("[Docs](https://example.com)") == "Docs (https://example.com)")
        #expect(ChatMessageExport.plain("<https://example.com>") == "https://example.com")
    }

    @Test func tablesBecomeRowsWithSeparatedCells() {
        let source = "| Name | Size |\n|---|---|\n| Kit | 3 |\n| Box | 12 |"
        #expect(ChatMessageExport.plain(source) == "Name  ·  Size\nKit  ·  3\nBox  ·  12")
    }

    @Test func nonLatinTextAndEmojiPassThrough() {
        let source = "Привет, 世界 مرحبا 👋🏽 café"
        #expect(ChatMessageExport.plain(source) == source)
        #expect(ChatMessageExport.styled(source) == source)
    }

    @Test func markdownIsTheSourceUnchanged() {
        let source = "**Room for the conversation.**\n\n- one\n- two"
        #expect(ChatMessageExport.markdown(source) == source)
    }

    // MARK: PDF

    @Test func pdfIsAPDFDocument() throws {
        let data = ChatMessageExport.pdf("**Hello** there", title: "Message from Avery Park")
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "%PDF")
        let document = try #require(CGPDFDocument(try #require(CGDataProvider(data: data as CFData))))
        #expect(document.numberOfPages == 1)
    }

    @Test func aLongMessageRunsOverSeveralPages() throws {
        let source = (1...300).map { "Paragraph \($0) has a few words to fill the page." }.joined(separator: "\n\n")
        let data = ChatMessageExport.pdf(source, title: "Message")
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "%PDF")
        let document = try #require(CGPDFDocument(try #require(CGDataProvider(data: data as CFData))))
        #expect(document.numberOfPages > 1)
    }

    // MARK: Menu and sheet

    @Test func theMessageMenuOffersShareAfterCopy() {
        let driver = ChatMessageMenuDriver()
        driver.actions = ChatMessageMenuActions(
            copyActionLabel: "Copy to clipboard", onCopy: {}, onSelect: {}, onFork: nil, onReply: nil,
            reactions: nil, onShare: {})
        let titles = (driver.menu(floatsReactions: true)?.children ?? []).compactMap { ($0 as? UIAction)?.title }
        let copy = titles.firstIndex(of: "Copy to clipboard")
        #expect(copy != nil)
        #expect(titles.firstIndex(of: "Share…") == copy.map { $0 + 1 })
    }

    @Test func sharedPDFsAreNamedForTheAgent() {
        #expect(ChatMessageShareSheet(markdown: "Hi", agentName: "Avery Park").documentTitle == "Message from Avery Park")
        #expect(ChatMessageShareSheet(markdown: "Hi", agentName: nil).documentTitle == "Message")
    }
}
