import SwiftUI

enum ChatMarkdownLayoutPolicy {
    static let growsVerticallyWithoutTruncation = true
    static let blockSpacing: CGFloat = 16
    static let headingContentSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 20
    static let listRowSpacing: CGFloat = 8
    static let unorderedMarkerWidth: CGFloat = 16
    static let orderedMarkerWidth: CGFloat = 28

    static func spacing(after previous: MarkdownBlock, before current: MarkdownBlock) -> CGFloat {
        if case .heading = current {
            return sectionSpacing
        }
        if case .heading = previous {
            return headingContentSpacing
        }
        return blockSpacing
    }
}

enum ChatMarkdownTypography {
    static func headingRole(for level: Int) -> BighelpFontRole {
        switch level {
        case 1: .display
        case 2: .screenTitle
        case 3: .sectionTitle
        default: .label
        }
    }
}

enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, markdown: String)
    case paragraph(markdown: String)
    case unorderedList(items: [String])
    case orderedList(start: Int, items: [String])
    case quote(markdown: String)
    case code(language: String?, text: String)
    /// A GitHub-style pipe table. Chats draw it as its own grid (ChatMarkdownTableView).
    case table(MarkdownTable)
    /// A thematic break: a line of three or more `-`, `*` or `_`.
    case rule
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    /// Cells are inline Markdown. Every row has one cell per column.
    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]
}

/// `- [ ] item` and `- [x] item` in a list.
enum MarkdownTaskItem {
    static func split(_ item: String) -> (done: Bool?, text: String) {
        for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(prefix) {
            return (done, String(item.dropFirst(prefix.count)))
        }
        return (nil, item)
    }

    static func marker(done: Bool) -> String { done ? "☑" : "☐" }
}

struct MarkdownDocument: Equatable, Sendable {
    let blocks: [MarkdownBlock]

    /// Worked out when asked (copying, VoiceOver, previews), never while drawing: it runs
    /// Foundation's Markdown parser over every paragraph, and making it with each document
    /// was most of the work of laying out a long message, again on each streamed word.
    var visiblePlainText: String {
        blocks.map(Self.plainText).joined(separator: "\n\n")
    }

    init(_ source: String) {
        self.init(blocks: Self.parse(source))
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    private static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let lines = normalized.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(markdown: paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let languageValue = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count,
                      !lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[cursor])
                    cursor += 1
                }
                if cursor < lines.count {
                    result.append(.code(
                        language: languageValue.isEmpty ? nil : languageValue,
                        text: codeLines.joined(separator: "\n")
                    ))
                    index = cursor + 1
                } else {
                    paragraph.append(contentsOf: Array(lines[index...]))
                    index = lines.count
                }
                continue
            }
            // A line of `===` or `---` under text makes that text a heading (Setext).
            if !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.joined(separator: " ")
                paragraph.removeAll(keepingCapacity: true)
                result.append(.heading(level: level, markdown: text))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                result.append(.rule)
                index += 1
                continue
            }
            if let found = pipeTable(startingAt: index, in: lines) {
                flushParagraph()
                result.append(.table(found.table))
                index = found.next
                continue
            }
            if let heading = heading(from: trimmed) {
                flushParagraph()
                result.append(heading)
                index += 1
                continue
            }
            if unorderedItem(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                result.append(.unorderedList(items: items))
                continue
            }
            if let first = orderedItem(from: trimmed) {
                flushParagraph()
                var items = [first.text]
                let start = first.number
                index += 1
                while index < lines.count,
                      let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item.text)
                    index += 1
                }
                result.append(.orderedList(start: start, items: items))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(markdown: quoted.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return result
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        if line.allSatisfy({ $0 == "=" }) { return 1 }
        if line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// A header row, a delimiter row (`|---|:--:|`), then body rows until a line without a pipe.
    private static func pipeTable(startingAt index: Int, in lines: [String]) -> (table: MarkdownTable, next: Int)? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let header = tableCells(lines[index])
        guard !header.isEmpty, let alignments = tableAlignments(lines[index + 1]),
              alignments.count == header.count else { return nil }
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let cells = tableCells(line)
            rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
            cursor += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), cursor)
    }

    private static func tableAlignments(_ line: String) -> [MarkdownTable.Alignment]? {
        guard line.contains("-") else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in tableCells(line) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// Splits on pipes outside code spans; `\|` is a literal pipe.
    private static func tableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        let text = String(line.dropFirst(count + 1))
        guard !text.isEmpty else { return nil }
        return .heading(level: count, markdown: text)
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dot]
        guard
            !prefix.isEmpty,
            prefix.allSatisfy(\.isNumber),
            let number = Int(prefix),
            number > 0
        else { return nil }
        let remainder = line[line.index(after: dot)...]
        guard remainder.first == " " else { return nil }
        let text = String(remainder.dropFirst())
        return text.isEmpty ? nil : (number, text)
    }

    private static func plainText(for block: MarkdownBlock) -> String {
        switch block {
        case .heading(_, let markdown), .paragraph(let markdown), .quote(let markdown):
            inlinePlainText(markdown)
        case .unorderedList(let items):
            items.map { inlinePlainText(MarkdownTaskItem.split($0).text) }.joined(separator: "\n")
        case .orderedList(_, let items):
            items.map(inlinePlainText).joined(separator: "\n")
        case .code(_, let text):
            text
        case .table(let table):
            ([table.header] + table.rows).map { $0.map(inlinePlainText).joined(separator: "\t") }
                .joined(separator: "\n")
        case .rule:
            ""
        }
    }

    private static func inlinePlainText(_ markdown: String) -> String {
        guard inlineMarkersAreBalanced(markdown) else { return markdown }
        do {
            let attributed = try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            return String(attributed.characters)
        } catch {
            return markdown
        }
    }

    private static func inlineMarkersAreBalanced(_ value: String) -> Bool {
        value.components(separatedBy: "**").count.isMultiple(of: 2) == false
            && value.filter { $0 == "`" }.count.isMultiple(of: 2)
    }
}

enum ChatInlineMarkdown {
    /// Making a link detector costs more than running it over a message, and every run of
    /// text in every message drawn needs one; a detector is safe to share.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedText(_ markdown: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        let visibleText = String(attributed.characters)
        guard let detector = linkDetector else { return attributed }

        let matches = detector.matches(
            in: visibleText,
            range: NSRange(visibleText.startIndex..<visibleText.endIndex, in: visibleText)
        )
        for match in matches {
            guard
                let url = match.url,
                let stringRange = Range(match.range, in: visibleText),
                let lowerBound = AttributedString.Index(
                    stringRange.lowerBound,
                    within: attributed
                ),
                let upperBound = AttributedString.Index(
                    stringRange.upperBound,
                    within: attributed
                )
            else { continue }
            let range = lowerBound..<upperBound
            guard !attributed[range].runs.contains(where: { $0.link != nil }) else {
                continue
            }
            attributed[range].link = url
        }
        return attributed
    }
}
