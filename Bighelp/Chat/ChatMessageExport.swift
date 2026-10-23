import Foundation
import SwiftUI
import UIKit

/// A message in the format that fits where it's going: its Markdown as is,
/// plain text with no markup, text styled with Unicode letters for apps that
/// show no Markdown (Messages), or a PDF.
///
/// Parsed with Foundation's Markdown (`.full`), which gives each run its block
/// (heading, list item, quote, code, table cell) and its inline style. The chat's
/// own `MarkdownDocument` is built for drawing and doesn't keep inline styles.
enum ChatMessageExport {
    static func markdown(_ source: String) -> String { source }

    static func plain(_ source: String) -> String {
        text(blocks(source), styled: false)
    }

    static func styled(_ source: String) -> String {
        text(blocks(source), styled: true)
    }

    // MARK: - Blocks

    struct Span: Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL?
    }

    enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case code
        case listItem(marker: String, depth: Int)
        /// A later paragraph of a list item: indented, without a marker.
        case listContinuation(depth: Int)
        case tableRow(isHeader: Bool)
    }

    struct Block: Equatable, Sendable {
        var kind: Kind
        var isQuote: Bool
        /// Blocks of one list or one table follow each other on the next line.
        var group: Int?
        /// One cell for everything but table rows.
        var cells: [[Span]]
    }

    static func blocks(_ source: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            guard !source.isEmpty else { return [] }
            return [Block(kind: .paragraph, isQuote: false, group: nil, cells: [[Span(text: source)]])]
        }
        var blocks: [Block] = []
        var blockKey: Int?
        var cellKey: Int?
        var seenItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let inline = run.inlinePresentationIntent ?? []
            // Line breaks inside a paragraph stay where the author put them.
            let text = inline.contains(.softBreak) || inline.contains(.lineBreak)
                ? "\n" : String(parsed[run.range].characters)
            let span = Span(
                text: text,
                bold: inline.contains(.stronglyEmphasized),
                italic: inline.contains(.emphasized),
                code: inline.contains(.code),
                strike: inline.contains(.strikethrough),
                link: run.link
            )
            let row = components.first { isTableRow($0.kind) }
            let cell = components.first { if case .tableCell = $0.kind { true } else { false } }
            let key = row?.identity ?? components.first?.identity ?? -1
            if key == blockKey, !blocks.isEmpty {
                let last = blocks.count - 1
                if let cell, cell.identity != cellKey {
                    blocks[last].cells.append([span])
                    cellKey = cell.identity
                } else {
                    blocks[last].cells[blocks[last].cells.count - 1].append(span)
                }
                continue
            }
            blockKey = key
            cellKey = cell?.identity
            blocks.append(Block(
                kind: kind(components, seenItems: &seenItems),
                isQuote: components.contains { if case .blockQuote = $0.kind { true } else { false } },
                group: components.last { isList($0.kind) || isTable($0.kind) }?.identity,
                cells: [[span]]
            ))
        }
        return blocks
    }

    /// Foundation lists a run's blocks innermost first.
    private static func kind(_ components: [PresentationIntent.IntentType], seenItems: inout Set<Int>) -> Kind {
        for component in components {
            switch component.kind {
            case .tableHeaderRow: return .tableRow(isHeader: true)
            case .tableRow: return .tableRow(isHeader: false)
            case .header(let level): return .heading(level: level)
            case .codeBlock: return .code
            default: continue
            }
        }
        guard let index = components.firstIndex(where: { isListItem($0.kind) }) else { return .paragraph }
        let item = components[index]
        let depth = components.filter { isListItem($0.kind) }.count
        guard seenItems.insert(item.identity).inserted else { return .listContinuation(depth: depth) }
        var ordinal = 1
        if case .listItem(let value) = item.kind { ordinal = value }
        let isOrdered = components[(index + 1)...].first { isList($0.kind) }.map {
            if case .orderedList = $0.kind { true } else { false }
        } ?? false
        return .listItem(marker: isOrdered ? "\(ordinal). " : "• ", depth: depth)
    }

    private static func isListItem(_ kind: PresentationIntent.Kind) -> Bool {
        if case .listItem = kind { true } else { false }
    }

    private static func isList(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .orderedList, .unorderedList: true
        default: false
        }
    }

    private static func isTable(_ kind: PresentationIntent.Kind) -> Bool {
        if case .table = kind { true } else { false }
    }

    private static func isTableRow(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .tableRow, .tableHeaderRow: true
        default: false
        }
    }

    // MARK: - Text

    static let tableCellSeparator = "  ·  "
    private static let indentUnit = "    "

    private static func text(_ blocks: [Block], styled: Bool) -> String {
        var output = ""
        var previous: Block?
        for block in blocks {
            if let previous {
                output += previous.group != nil && previous.group == block.group ? "\n" : "\n\n"
            }
            output += line(block, styled: styled)
            previous = block
        }
        return output
    }

    private static func line(_ block: Block, styled: Bool) -> String {
        let spans = block.cells.first ?? []
        switch block.kind {
        case .paragraph:
            return inline(spans, styled: styled)
        case .heading:
            return inline(spans, styled: styled, bold: true)
        case .code:
            var code = spans.map(\.text).joined()
            while code.hasSuffix("\n") { code.removeLast() }
            return styled ? style(code, bold: false, italic: false, monospace: true, strike: false) : code
        case .listItem(let marker, let depth):
            let indent = String(repeating: indentUnit, count: max(depth - 1, 0))
            let hanging = indent + String(repeating: " ", count: marker.count)
            return indent + marker + inline(spans, styled: styled)
                .replacingOccurrences(of: "\n", with: "\n" + hanging)
        case .listContinuation(let depth):
            let indent = String(repeating: indentUnit, count: max(depth - 1, 0)) + "  "
            return indent + inline(spans, styled: styled).replacingOccurrences(of: "\n", with: "\n" + indent)
        case .tableRow(let isHeader):
            return block.cells
                .map { inline($0, styled: styled, bold: isHeader && styled) }
                .joined(separator: tableCellSeparator)
        }
    }

    /// A link's address follows its text, unless the text is the address.
    private static func inline(_ spans: [Span], styled: Bool, bold: Bool = false) -> String {
        var output = ""
        var index = spans.startIndex
        while index < spans.endIndex {
            guard let url = spans[index].link else {
                output += render(spans[index], styled: styled, bold: bold)
                index += 1
                continue
            }
            var end = index
            var label = ""
            while end < spans.endIndex, spans[end].link == url {
                output += render(spans[end], styled: styled, bold: bold)
                label += spans[end].text
                end += 1
            }
            if !linkShowsItself(label, url) {
                output += " (\(url.absoluteString))"
            }
            index = end
        }
        return output
    }

    private static func render(_ span: Span, styled: Bool, bold: Bool) -> String {
        guard styled else { return span.text }
        return style(span.text, bold: bold || span.bold, italic: span.italic, monospace: span.code, strike: span.strike)
    }

    static func linkShowsItself(_ label: String, _ url: URL) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = url.absoluteString
        guard !label.isEmpty else { return false }
        return [label, "mailto:" + label, "tel:" + label, "https://" + label, "http://" + label]
            .contains { $0 == address || $0 + "/" == address }
    }

    // MARK: - Unicode styling

    /// Only ASCII letters and digits have styled forms; everything else stays.
    static func style(_ text: String, bold: Bool, italic: Bool, monospace: Bool, strike: Bool) -> String {
        guard bold || italic || monospace || strike else { return text }
        var output = ""
        output.unicodeScalars.reserveCapacity(text.unicodeScalars.count * 2)
        for character in text {
            if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
               let styled = styledScalar(scalar, bold: bold, italic: italic, monospace: monospace) {
                output.unicodeScalars.append(styled)
            } else {
                output.append(character)
            }
            if strike, !character.isNewline {
                output.unicodeScalars.append("\u{0336}")
            }
        }
        return output
    }

    private static func styledScalar(_ scalar: Unicode.Scalar, bold: Bool, italic: Bool,
                                     monospace: Bool) -> Unicode.Scalar? {
        let value = scalar.value
        let upper: UInt32, lower: UInt32, digits: UInt32?
        if monospace {
            (upper, lower, digits) = (0x1D670, 0x1D68A, 0x1D7F6)
        } else if bold && italic {
            (upper, lower, digits) = (0x1D63C, 0x1D656, 0x1D7EC)
        } else if bold {
            (upper, lower, digits) = (0x1D5D4, 0x1D5EE, 0x1D7EC)
        } else if italic {
            (upper, lower, digits) = (0x1D608, 0x1D622, nil)
        } else {
            return nil
        }
        switch value {
        case 0x41...0x5A: return Unicode.Scalar(upper + value - 0x41)
        case 0x61...0x7A: return Unicode.Scalar(lower + value - 0x61)
        case 0x30...0x39: return digits.flatMap { Unicode.Scalar($0 + value - 0x30) }
        default: return nil
        }
    }
}

// MARK: - PDF

extension ChatMessageExport {
    /// Letter where it's the paper people use, A4 elsewhere.
    static var defaultPageSize: CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "DO", "SV"]
        return letterRegions.contains(Locale.current.region?.identifier ?? "")
            ? CGSize(width: 612, height: 792)
            : CGSize(width: 595.28, height: 841.89)
    }

    /// The message as a document: its title, then the text with real bold,
    /// italics, code and bullets at the app's text sizes, over as many pages as
    /// it takes.
    @MainActor
    static func pdf(_ source: String, title: String, pageSize: CGSize = defaultPageSize) -> Data {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let textRect = pageRect.insetBy(dx: 56, dy: 56)
        let storage = NSTextStorage(attributedString: attributed(blocks(source), title: title))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        while containers.count < 1_000 {
            let container = NSTextContainer(size: textRect.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            // A line taller than a page would never fit; stop instead of looping.
            if NSMaxRange(range) >= layout.numberOfGlyphs || range.length == 0 { break }
        }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title]
        return UIGraphicsPDFRenderer(bounds: pageRect, format: format).pdfData { context in
            for container in containers {
                context.beginPage()
                let range = layout.glyphRange(for: container)
                layout.drawBackground(forGlyphRange: range, at: textRect.origin)
                layout.drawGlyphs(forGlyphRange: range, at: textRect.origin)
            }
        }
    }

    private enum PDFStyle {
        static let body = Font.TextStyle.body.iPhonePointSize
        static let code = Font.TextStyle.callout.iPhonePointSize
        static let title = Font.TextStyle.title2.iPhonePointSize
        static let ink = UIColor(white: 0.1, alpha: 1)
        static let quiet = UIColor(white: 0.4, alpha: 1)
        static let link = UIColor(red: 0.2, green: 0.25, blue: 0.7, alpha: 1)
        static let codeBackground = UIColor(white: 0.94, alpha: 1)
        static let listIndent: CGFloat = 22
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: Font.TextStyle.title3.iPhonePointSize
        default: Font.TextStyle.headline.iPhonePointSize
        }
    }

    static func attributed(_ blocks: [Block], title: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 14
        output.append(NSAttributedString(string: title + "\n", attributes: [
            .font: UIFont.systemFont(ofSize: PDFStyle.title, weight: .bold),
            .foregroundColor: PDFStyle.ink,
            .paragraphStyle: titleStyle,
        ]))
        var previous: Block?
        for (index, block) in blocks.enumerated() {
            let tight = previous?.group != nil && previous?.group == block.group
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = previous == nil ? 0 : tight ? 3 : 10
            paragraph.lineSpacing = 3
            var quote = block.isQuote
            let line = NSMutableAttributedString()
            switch block.kind {
            case .paragraph:
                line.append(inlineAttributed(block.cells.first ?? [], size: PDFStyle.body))
            case .heading(let level):
                line.append(inlineAttributed(block.cells.first ?? [], size: headingSize(level), bold: true))
                paragraph.paragraphSpacingBefore = previous == nil ? 0 : 14
            case .code:
                var code = (block.cells.first ?? []).map(\.text).joined()
                while code.hasSuffix("\n") { code.removeLast() }
                line.append(NSAttributedString(string: code, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: PDFStyle.code - 2, weight: .regular),
                    .foregroundColor: PDFStyle.ink,
                    .backgroundColor: PDFStyle.codeBackground,
                ]))
                quote = false
            case .listItem(let marker, let depth):
                let indent = PDFStyle.listIndent * CGFloat(max(depth - 1, 0))
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + PDFStyle.listIndent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + PDFStyle.listIndent)]
                line.append(NSAttributedString(string: marker.trimmingCharacters(in: .whitespaces) + "\t", attributes: [
                    .font: UIFont.systemFont(ofSize: PDFStyle.body),
                    .foregroundColor: PDFStyle.ink,
                ]))
                line.append(inlineAttributed(block.cells.first ?? [], size: PDFStyle.body))
            case .listContinuation(let depth):
                let indent = PDFStyle.listIndent * CGFloat(depth)
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                line.append(inlineAttributed(block.cells.first ?? [], size: PDFStyle.body))
            case .tableRow(let isHeader):
                for (cellIndex, cell) in block.cells.enumerated() {
                    if cellIndex > 0 {
                        line.append(NSAttributedString(string: tableCellSeparator, attributes: [
                            .font: UIFont.systemFont(ofSize: PDFStyle.body),
                            .foregroundColor: PDFStyle.quiet,
                        ]))
                    }
                    line.append(inlineAttributed(cell, size: PDFStyle.body, bold: isHeader))
                }
            }
            if quote {
                paragraph.firstLineHeadIndent += PDFStyle.listIndent
                paragraph.headIndent += PDFStyle.listIndent
                line.addAttribute(.foregroundColor, value: PDFStyle.quiet, range: NSRange(location: 0, length: line.length))
            }
            if index < blocks.count - 1 { line.append(NSAttributedString(string: "\n")) }
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            output.append(line)
            previous = block
        }
        return output
    }

    private static func inlineAttributed(_ spans: [Span], size: CGFloat, bold: Bool = false) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var index = spans.startIndex
        while index < spans.endIndex {
            let span = spans[index]
            // A line break inside a paragraph keeps the paragraph's spacing.
            let text = span.text == "\n" ? "\u{2028}" : span.text
            output.append(NSAttributedString(string: text, attributes: attributes(span, size: size, bold: bold)))
            index += 1
            // After the last part of a link, its address, unless the text is the address.
            if let url = span.link, index == spans.endIndex || spans[index].link != url {
                var start = index - 1
                while start > spans.startIndex, spans[start - 1].link == url { start -= 1 }
                let label = spans[start..<index].map(\.text).joined()
                if !linkShowsItself(label, url) {
                    output.append(NSAttributedString(string: " (\(url.absoluteString))", attributes: [
                        .font: UIFont.systemFont(ofSize: size * 0.85),
                        .foregroundColor: PDFStyle.quiet,
                    ]))
                }
            }
        }
        return output
    }

    private static func attributes(_ span: Span, size: CGFloat, bold: Bool) -> [NSAttributedString.Key: Any] {
        var font: UIFont
        if span.code {
            font = .monospacedSystemFont(ofSize: size - 2, weight: bold || span.bold ? .semibold : .regular)
        } else {
            font = .systemFont(ofSize: size, weight: bold || span.bold ? .semibold : .regular)
            if span.italic, let italic = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: italic, size: size)
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PDFStyle.ink]
        if span.code { attributes[.backgroundColor] = PDFStyle.codeBackground }
        if span.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if span.link != nil {
            attributes[.foregroundColor] = PDFStyle.link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }
}
