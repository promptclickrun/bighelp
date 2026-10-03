import Foundation
import os

/// A tool's arguments or result made readable: the key facts ("Exit code 0",
/// "Path /tmp/notes.md") and its text with real line breaks, instead of a
/// wall of escaped JSON. Lists become lines; search results become titles
/// and addresses. Text that isn't JSON is already readable and isn't parsed.
///
/// The original value stays the truth: the row still copies it whole and
/// opens it in the full reader.
struct ChatToolReadableDetail: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        /// A short value on one line.
        case fact(label: String, value: String)
        /// Text with line breaks (output, a command, a list), shown in monospace.
        case block(label: String?, text: String)
    }

    let items: [Item]

    /// Bigger values are left to the bounded preview and the full reader, so
    /// a cell never parses an arbitrarily large result.
    static let maximumInputBytes = 32_768
    static let maximumItems = 24
    static let maximumListLines = 20
    static let inlineLength = 80

    static func parse(_ raw: String) -> ChatToolReadableDetail? {
        guard raw.utf8.count <= maximumInputBytes else { return nil }
        if let cached = cache.withLock({ $0[raw] }) { return cached.detail }
        let detail = uncachedParse(raw)
        cache.withLock { storage in
            if storage.count >= 64 { storage.removeAll(keepingCapacity: true) }
            storage[raw] = Cached(detail: detail)
        }
        return detail
    }

    private struct Cached: Sendable { let detail: ChatToolReadableDetail? }
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Cached]())

    private static func uncachedParse(_ raw: String) -> ChatToolReadableDetail? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, "{[\"".contains(first), let value = json(trimmed) else { return nil }
        var builder = Builder()
        if let text = value as? String {
            // Hermes often stores a JSON result inside a JSON string.
            let inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let innerFirst = inner.first, "{[".contains(innerFirst), let nested = json(inner) {
                builder.add(nested, key: nil, label: nil, depth: 0)
            } else if !inner.isEmpty {
                builder.items.append(.block(label: nil, text: inner))
            }
        } else {
            builder.add(value, key: nil, label: nil, depth: 0)
        }
        return builder.items.isEmpty ? nil : ChatToolReadableDetail(items: builder.items)
    }

    fileprivate static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private struct Builder {
        var items: [Item] = []
        private var omitted = 0

        /// What matters first: what ran and on what, then how it went. The
        /// rest follow alphabetically.
        private static let priority = [
            "command", "cmd", "code", "path", "file_path", "filename", "file", "url", "urls", "query", "pattern",
            "name", "title", "status", "success", "ok", "exit_code", "returncode", "error", "message",
        ]
        /// Keys whose text reads best as a block, even when short.
        private static let blockKeys: Set<String> = [
            "command", "cmd", "code", "script", "content", "output", "stdout", "stderr", "diff", "patch", "body",
            "text", "source", "old_string", "new_string",
        ]
        private static let titleKeys = ["title", "name", "label", "path", "file", "filename", "id", "key"]
        private static let linkKeys = ["url", "link", "href", "uri"]
        private static let detailKeys = ["description", "snippet", "summary", "content", "text"]

        mutating func add(_ value: Any, key: String?, label: String?, depth: Int) {
            switch value {
            case is NSNull:
                return
            case let object as [String: Any]:
                guard depth < 3 else { return append(.block(label: label, text: pretty(object))) }
                for key in Self.ordered(object.keys) {
                    guard let child = object[key] else { continue }
                    let name = ChatToolReadableDetail.label(for: key)
                    add(child, key: key, label: label.map { "\($0) › \(name)" } ?? name, depth: depth + 1)
                }
            case let array as [Any]:
                addList(array, label: label)
            case let number as NSNumber:
                let text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No")
                    : number.stringValue
                append(.fact(label: label ?? "Value", value: text))
            case let string as String:
                let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if let first = text.first, "{[".contains(first), text.utf8.count <= maximumInputBytes,
                   let nested = ChatToolReadableDetail.json(text), !(nested is String) {
                    return add(nested, key: key, label: label, depth: depth)
                }
                let isBlock = text.contains(where: \.isNewline) || text.count > inlineLength
                    || key.map(Self.blockKeys.contains) == true
                append(isBlock ? .block(label: label, text: text) : .fact(label: label ?? "Value", value: text))
            default:
                return
            }
        }

        private mutating func addList(_ array: [Any], label: String?) {
            let values = array.filter { !($0 is NSNull) }
            guard !values.isEmpty else { return }
            let scalars = values.compactMap(Self.scalarText)
            if scalars.count == values.count {
                let inline = scalars.joined(separator: ", ")
                if inline.count <= inlineLength, !inline.contains(where: \.isNewline) {
                    return append(.fact(label: label ?? "Values", value: inline))
                }
                return append(.block(label: label, text: Self.trimmedList(scalars)))
            }
            let objects = values.compactMap { $0 as? [String: Any] }
            guard objects.count == values.count else {
                return append(.block(label: label, text: pretty(values)))
            }
            let entries = objects.map { object -> String in
                let title = Self.firstText(in: object, keys: Self.titleKeys)
                let link = Self.firstText(in: object, keys: Self.linkKeys)
                var line = "• " + ([title, link].compactMap { $0 }.joined(separator: " — "))
                if title == nil, link == nil { line = "• " + Self.oneLine(pretty(object, compact: true), limit: 160) }
                if let detail = Self.firstText(in: object, keys: Self.detailKeys) {
                    line += "\n  " + Self.oneLine(detail, limit: 160)
                }
                return line
            }
            append(.block(label: label, text: Self.trimmedList(entries)))
        }

        private mutating func append(_ item: Item) {
            guard items.count < maximumItems else {
                omitted += 1
                let more = Item.fact(label: "More", value: omitted == 1 ? "1 more field" : "\(omitted) more fields")
                if items.count == maximumItems { items.append(more) } else { items[items.count - 1] = more }
                return
            }
            items.append(item)
        }

        private static func ordered(_ keys: Dictionary<String, Any>.Keys) -> [String] {
            keys.sorted { left, right in
                let leftRank = priority.firstIndex(of: left.lowercased()) ?? priority.count
                let rightRank = priority.firstIndex(of: right.lowercased()) ?? priority.count
                return leftRank == rightRank ? left < right : leftRank < rightRank
            }
        }

        private static func scalarText(_ value: Any) -> String? {
            switch value {
            case let string as String: string.trimmingCharacters(in: .whitespacesAndNewlines)
            case let number as NSNumber:
                CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
            default: nil
            }
        }

        private static func firstText(in object: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let text = object[key].flatMap(scalarText), !text.isEmpty { return text }
            }
            return nil
        }

        private static func trimmedList(_ lines: [String]) -> String {
            let shown = lines.prefix(maximumListLines)
            let rest = lines.count - shown.count
            return (shown + (rest > 0 ? ["… and \(rest) more"] : [])).joined(separator: "\n")
        }

        private static func oneLine(_ text: String, limit: Int) -> String {
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }

        private func pretty(_ value: Any, compact: Bool = false) -> String {
            let options: JSONSerialization.WritingOptions = compact
                ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: options) else {
                return String(describing: value)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// "exit_code" → "Exit code", "filePath" → "File path", "urls" → "URLs".
    static func label(for key: String) -> String {
        if let renamed = renamedKeys[key.lowercased()] { return renamed }
        var words: [String] = []
        var word = ""
        for character in key {
            if character == "_" || character == "-" || character == " " || character == "." {
                if !word.isEmpty { words.append(word) }
                word = ""
            } else if character.isUppercase, let last = word.last, last.isLowercase {
                words.append(word)
                word = String(character)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        let lowered = words.map { acronyms[$0.lowercased()] ?? $0.lowercased() }
        guard let first = lowered.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + lowered.dropFirst()).joined(separator: " ")
    }

    private static let renamedKeys = ["stdout": "Output", "stderr": "Errors", "returncode": "Exit code"]
    private static let acronyms = ["url": "URL", "urls": "URLs", "id": "ID", "ids": "IDs", "ok": "OK", "api": "API",
                                   "json": "JSON", "http": "HTTP", "ip": "IP", "pid": "PID", "html": "HTML"]
}
