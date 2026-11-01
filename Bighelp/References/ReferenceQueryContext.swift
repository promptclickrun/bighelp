import Foundation

/// A local source token, never a provider request or command invocation.
struct ReferenceQueryContext: Equatable, Sendable {
    let range: NSRange
    let query: String
    let selection: NSRange
    // String equality is canonically equivalent, not byte equality. A stale
    // result must not edit a byte-distinct replacement draft.
    private let originalBytes: Data

    private init(range: NSRange, query: String, selection: NSRange, source: String) {
        self.range = range
        self.query = query
        self.selection = selection
        self.originalBytes = Data(source.utf8)
    }

    static func parse(source: String, selection: NSRange) -> ReferenceQueryContext? {
        // Every query starts with `/`; most drafts have none, and this runs on every key.
        guard source.utf8.contains(UInt8(ascii: "/")) else { return nil }
        let units = Array(source.utf16)
        guard ReferenceSourceSyntax.valid(selection, in: units) else { return nil }
        var start = selection.location
        while start > 0, isQueryUnit(units[start - 1]) { start -= 1 }
        if start > 0, units[start - 1] == 47 { start -= 1 }
        guard start < units.count, units[start] == 47,
              start == 0 || isBoundary(units[start - 1]),
              !ReferenceSourceSyntax.isSuppressed(at: start, in: units) else { return nil }
        var end = start + 1
        while end < units.count, isQueryUnit(units[end]) { end += 1 }
        guard selection.location >= start,
              selection.length > 0 || selection.location > start,
              selection.location + selection.length <= end,
              // A slash/path/URL suffix is not a partial reference token.
              end == units.count || isTerminator(units[end]) else { return nil }
        let range = NSRange(location: start, length: end - start)
        guard ReferenceSourceSyntax.valid(range, in: units) else { return nil }
        return Self(range: range,
                    query: String(decoding: units[(start + 1)..<end], as: UTF16.self),
                    selection: selection, source: source)
    }

    fileprivate func matches(_ source: String) -> Bool {
        originalBytes == Data(source.utf8)
    }

    private static func isQueryUnit(_ unit: UInt16) -> Bool {
        if unit == 45 || unit == 95 { return true }
        // Supplementary letters/emoji are kept intact by the range checks.
        if (0xD800...0xDFFF).contains(unit) { return true }
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private static func isBoundary(_ unit: UInt16) -> Bool {
        ReferenceSourceSyntax.isWhitespace(unit) || [40, 91, 123].contains(unit)
    }

    private static func isTerminator(_ unit: UInt16) -> Bool {
        ReferenceSourceSyntax.isWhitespace(unit) || [41, 93, 125, 44, 59, 33].contains(unit)
    }
}

/// Apply synchronously to the same native editor revision/owner that produced
/// the query, outside marked-text composition, as one native undo operation.
/// Session/owner/revision and IME guards belong to the editor, not this DTO.
struct ReferenceEditTransaction: Equatable, Sendable {
    let source: String
    let selection: NSRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && Data(lhs.source.utf8) == Data(rhs.source.utf8)
    }

    enum Failure: Error, Equatable, Sendable {
        case staleQuery
        case invalidAnchor
    }

    static func replacing(_ query: ReferenceQueryContext, in source: String,
                          with anchor: String) throws -> ReferenceEditTransaction {
        guard query.matches(source),
              let current = ReferenceQueryContext.parse(source: source, selection: query.selection),
              current == query else { throw Failure.staleQuery }
        // Also accepts caller-supplied readable links (not only snapshot links).
        // Commands and arbitrary imported title/content are not replacements.
        guard ReferenceSourceSyntax.isSingleLink(anchor) else { throw Failure.invalidAnchor }
        let units = Array(source.utf16)
        let prefix = String(decoding: units[..<query.range.location], as: UTF16.self)
        let suffix = String(decoding: units[(query.range.location + query.range.length)...], as: UTF16.self)
        return Self(source: prefix + anchor + suffix,
                    selection: NSRange(location: query.range.location + anchor.utf16.count, length: 0))
    }
}

/// Conservative source grammar shared by token and anchor validation. It does
/// not render Markdown. Ambiguous/unclosed constructs remain literal input.
enum ReferenceSourceSyntax: Sendable {
    static func valid(_ range: NSRange, in units: [UInt16]) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        return boundary(range.location, in: units) && boundary(range.location + range.length, in: units)
    }

    private static func boundary(_ offset: Int, in units: [UInt16]) -> Bool {
        !(offset > 0 && offset < units.count
          && (0xD800...0xDBFF).contains(units[offset - 1])
          && (0xDC00...0xDFFF).contains(units[offset]))
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func isSuppressed(at target: Int, in units: [UInt16]) -> Bool {
        guard target >= 0, target <= units.count else { return true }
        var index = 0
        var lineStart = 0
        var fence: (marker: UInt16, count: Int)?
        var ticks = 0
        var brackets = 0
        var linkParentheses = 0
        var angle = false
        while index < target {
            let c = units[index]
            if c == 10 || c == 13 {
                lineStart = index + 1
                index += 1
                continue
            }
            if index == lineStart {
                var first = index
                while first < units.count, units[first] == 32 { first += 1 }
                let indent = first - index
                if first < units.count, indent <= 3, units[first] == 96 || units[first] == 126 {
                    let marker = units[first]
                    var end = first
                    while end < units.count, units[end] == marker { end += 1 }
                    if end - first >= 3 {
                        if let active = fence {
                            if active.marker == marker, end - first >= active.count {
                                var tail = end
                                while tail < units.count, units[tail] == 32 || units[tail] == 9 { tail += 1 }
                                if tail == units.count || units[tail] == 10 || units[tail] == 13 { fence = nil }
                            }
                        } else if ticks == 0 {
                            fence = (marker, end - first)
                        }
                        // Fence declaration lines themselves are never query sites.
                        while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
                        if target <= end { return true }
                        index = end
                        continue
                    }
                }
                if fence == nil, indent >= 4 || (first < units.count && units[first] == 9) {
                    var end = first
                    while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
                    if target <= end { return true }
                    index = end
                    continue
                }
            }
            // Conservatively recognize tilde fences behind container prefixes
            // (for example `> ~~~`) too, rather than offering a command inside
            // quoted code. Backtick runs are handled by the inline-code state.
            if c == 126, ticks == 0 {
                var end = index
                while end < units.count, units[end] == 126 { end += 1 }
                if end - index >= 3 {
                    if let active = fence {
                        if active.marker == 126, end - index >= active.count {
                            var tail = end
                            while tail < units.count, units[tail] == 32 || units[tail] == 9 { tail += 1 }
                            if tail == units.count || units[tail] == 10 || units[tail] == 13 { fence = nil }
                        }
                    } else {
                        fence = (126, end - index)
                    }
                    if target < end { return true }
                    index = end
                    continue
                }
            }
            if fence != nil { index += 1; continue }
            if c == 96 {
                var end = index
                while end < units.count, units[end] == 96 { end += 1 }
                if ticks == 0 { ticks = end - index }
                else if ticks == end - index { ticks = 0 }
                if target < end { return true }
                index = end
                continue
            }
            if ticks != 0 { index += 1; continue }
            if c == 92 {
                if index + 1 == target { return true }
                index += min(2, units.count - index)
                continue
            }
            if c == 60 { angle = true }
            if c == 62 { angle = false }
            if c == 91 { brackets += 1 }
            if c == 93, brackets > 0 {
                brackets -= 1
                if index + 1 < units.count, units[index + 1] == 40 {
                    linkParentheses += 1
                    index += 2
                    continue
                }
            }
            if linkParentheses > 0 {
                if c == 40 { linkParentheses += 1 }
                if c == 41 { linkParentheses -= 1 }
            }
            index += 1
        }
        return fence != nil || ticks != 0 || brackets != 0 || linkParentheses != 0 || angle
    }

    static func isSingleLink(_ source: String) -> Bool {
        let bytes = Array(source.utf8)
        guard bytes.first == 91, bytes.last == 41,
              !source.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return false }
        var index = 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 91 || bytes[index] == 96 { return false }
            if bytes[index] == 93 { break }
            index += 1
        }
        guard index > 1, index + 2 < bytes.count, bytes[index + 1] == 40 else { return false }
        let target = String(decoding: bytes[(index + 2)..<(bytes.count - 1)], as: UTF8.self)
        // No URL repair or implicit percent-encoding is performed here.
        // Snapshot targets have a stricter exact grammar.
        guard !target.isEmpty, !target.utf8.contains(where: { $0 <= 32 || $0 >= 127 || [40, 41, 92, 60, 62].contains($0) }),
              target.hasPrefix("https://") || target.hasPrefix("loopdy-wiki://reference/") else { return false }
        guard let url = URL(string: target, encodingInvalidCharacters: false),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              Data(url.absoluteString.utf8) == Data(target.utf8) else { return false }
        return true
    }
}
