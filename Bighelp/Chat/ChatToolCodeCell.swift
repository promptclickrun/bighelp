import Foundation
import os

/// A tool call that ran code, as one notebook cell (#926): the code in its
/// language, then what it printed and how it ended. Only Hermes' `execute_code`
/// (always Python) and `terminal` (a shell command) make one; every other tool
/// keeps its readable details (`ChatToolReadableDetail`).
struct ChatToolCodeCell: Equatable, Sendable {
    enum Language: String, Sendable {
        case python = "Python"
        case shell = "Shell"
    }

    enum Ending: Equatable, Sendable {
        case running, succeeded, failed, stopped
    }

    let language: Language
    let code: String
    let lines: [ChatCodeLine]
    /// What the code printed, or the result itself when it isn't Hermes' usual shape.
    let output: String?
    let error: String?
    let exitCode: Int?
    let ending: Ending

    /// Bigger arguments or results are left to the plain details (a bounded
    /// preview), so a cell never parses an arbitrarily large value.
    static let maximumCodeBytes = 65_536
    static let maximumResultBytes = 262_144

    static func make(for event: ChatActivityEvent) -> ChatToolCodeCell? {
        guard event.kind == .tool, let language = language(for: event.canonicalToolName),
              let arguments = event.arguments, arguments.utf8.count <= maximumCodeBytes,
              (event.result?.utf8.count ?? 0) <= maximumResultBytes else { return nil }
        let key = Key(language: language, arguments: arguments, result: event.result, lifecycle: event.lifecycle)
        if let cached = cache.withLock({ $0[key] }) { return cached.cell }
        let cell = make(key)
        cache.withLock { storage in
            if storage.count >= 32 { storage.removeAll(keepingCapacity: true) }
            storage[key] = Cached(cell: cell)
        }
        return cell
    }

    private struct Key: Hashable, Sendable {
        let language: Language
        let arguments: String
        let result: String?
        let lifecycle: ChatActivityLifecycle
    }

    private struct Cached: Sendable { let cell: ChatToolCodeCell? }
    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Cached]())

    private static func language(for toolName: String?) -> Language? {
        switch toolName {
        case "execute_code": .python
        case "terminal": .shell
        default: nil
        }
    }

    private static func make(_ key: Key) -> ChatToolCodeCell? {
        let codeKey = key.language == .python ? "code" : "command"
        guard let arguments = json(key.arguments) as? [String: Any],
              let code = (arguments[codeKey] as? String)?.trimmingCharacters(in: .newlines),
              !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var output: String?
        var error: String?
        var exitCode: Int?
        var status: String?
        if let result = key.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Hermes sends `{"output", "exit_code", "error"}` (terminal) or
            // `{"status", "output", "error"}` (execute_code), sometimes inside a JSON string.
            var value = json(result)
            if let text = value as? String { value = json(text) }
            if let object = value as? [String: Any], object["output"] != nil || object["error"] != nil {
                output = object["output"] as? String
                error = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                exitCode = (object["exit_code"] ?? object["returncode"]) as? Int
                status = object["status"] as? String
            } else {
                output = result
            }
        }
        output = output.flatMap { $0.trimmingCharacters(in: .newlines).isEmpty ? nil : $0 }
        // An error fails the run even when the output already says it and it isn't shown twice.
        let reportsError = error != nil
        if let message = error, output?.contains(message) == true { error = nil }

        let ending: Ending = switch key.lifecycle {
        case .running: .running
        case .failed: .failed
        case .cancelled: .stopped
        case .succeeded, .recorded:
            reportsError || status == "error" || status == "timeout" || (exitCode ?? 0) != 0 ? .failed : .succeeded
        }
        return ChatToolCodeCell(language: key.language, code: code, lines: ChatCodeSyntax.lines(code, language: key.language),
                                output: output, error: error, exitCode: exitCode, ending: ending)
    }

    private static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
}

/// One line of code as runs of text, each marked with what it is.
struct ChatCodeLine: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        let text: String
        let token: ChatCodeToken?
    }

    let runs: [Run]
    var text: String { runs.map(\.text).joined() }
}

enum ChatCodeToken: Equatable, Sendable {
    case keyword, string, number, comment, call
}

/// A small, forgiving highlighter for the code agents run: keywords, strings,
/// numbers and constants, comments, and what gets called (a Python function,
/// a shell command). Text it doesn't know stays plain; it never fails.
enum ChatCodeSyntax {
    static func lines(_ code: String, language: ChatToolCodeCell.Language) -> [ChatCodeLine] {
        var lexer = Lexer(scalars: Array(code.unicodeScalars), language: language)
        lexer.run()
        return lexer.lines
    }

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
        "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case",
    ]
    private static let pythonConstants: Set<String> = ["True", "False", "None"]
    private static let stringPrefixes: Set<String> = ["f", "r", "b", "u", "rb", "br", "fr", "rf"]
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "while", "until", "do", "done", "case", "esac",
        "function", "select", "return", "local", "export", "declare", "readonly", "unset",
    ]
    /// Shell words after which the next word is a command again.
    private static let shellCommandStarters: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "time", "sudo", "exec", "env", "xargs", "nohup",
    ]

    private struct Lexer {
        let scalars: [Unicode.Scalar]
        let language: ChatToolCodeCell.Language
        var lines: [ChatCodeLine] = []
        private var runs: [ChatCodeLine.Run] = []
        /// The run being built, as scalars not yet copied: adding to a String a
        /// character at a time copied the whole run each time, quadratic in its length.
        private var pending: (range: Range<Int>, token: ChatCodeToken?)?
        private var index = 0
        /// Shell: the next word names a command.
        private var commandPosition = true
        /// Python: the next word is the name `def` or `class` gives.
        private var namesDefinition = false

        init(scalars: [Unicode.Scalar], language: ChatToolCodeCell.Language) {
            self.scalars = scalars
            self.language = language
        }

        mutating func run() {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "#", language == .python || index == 0 || isShellBreak(scalars[index - 1]) {
                    emit(upTo: endOfLine(from: index), .comment)
                } else if scalar == "\"" || scalar == "'" {
                    emit(upTo: endOfString(from: index), .string)
                    commandPosition = false
                } else if language == .shell, scalar == "$" {
                    shellDollar()
                } else if isDigit(scalar), !isWordScalar(previous) {
                    var end = index
                    while end < scalars.count, isWordScalar(scalars[end]) || scalars[end] == "." { end += 1 }
                    emit(upTo: end, .number)
                } else if isWordStart(scalar) {
                    word()
                } else if language == .python, scalar == "@", isWordStart(next(after: index)) {
                    var end = index + 1
                    while end < scalars.count, isWordScalar(scalars[end]) || scalars[end] == "." { end += 1 }
                    emit(upTo: end, .keyword)
                } else {
                    if language == .shell, !isSpace(scalar) { commandPosition = "|;&(\n{".unicodeScalars.contains(scalar) }
                    if scalar == "\n" { commandPosition = true }
                    emit(upTo: index + 1, nil)
                }
            }
            flushLine()
        }

        private var previous: Unicode.Scalar? { index > 0 ? scalars[index - 1] : nil }

        private mutating func word() {
            var end = index
            while end < scalars.count, isWordScalar(scalars[end]) || (language == .shell && "-./".unicodeScalars.contains(scalars[end])) {
                end += 1
            }
            let text = String(String.UnicodeScalarView(scalars[index..<end]))
            let follows = next(after: end - 1, skippingSpaces: true)
            let isAttribute = previous == "."
            if language == .python {
                if ChatCodeSyntax.stringPrefixes.contains(text.lowercased()), end < scalars.count,
                   scalars[end] == "\"" || scalars[end] == "'" {
                    return emit(upTo: endOfString(from: end), .string)
                }
                let token: ChatCodeToken? = if namesDefinition { .call }
                    else if isAttribute { follows == "(" ? .call : nil }
                    else if ChatCodeSyntax.pythonKeywords.contains(text) { .keyword }
                    else if ChatCodeSyntax.pythonConstants.contains(text) { .number }
                    else if follows == "(" { .call }
                    else { nil }
                namesDefinition = text == "def" || text == "class"
                return emit(upTo: end, token)
            }
            let isAssignment = end < scalars.count && scalars[end] == "="
            let token: ChatCodeToken? = if ChatCodeSyntax.shellKeywords.contains(text) { .keyword }
                else if commandPosition, !isAssignment { .call }
                else { nil }
            commandPosition = ChatCodeSyntax.shellCommandStarters.contains(text)
            emit(upTo: end, token)
        }

        /// `$NAME`, `${…}`, `$1`, `$?`: a variable. `$(`: a command inside.
        private mutating func shellDollar() {
            let following = next(after: index)
            if following == "(" {
                commandPosition = true
                return emit(upTo: index + 2, nil)
            }
            var end = index + 1
            if following == "{" {
                while end < scalars.count, scalars[end] != "}", scalars[end] != "\n" { end += 1 }
                if end < scalars.count, scalars[end] == "}" { end += 1 }
            } else if let following, "?@#*$!-".unicodeScalars.contains(following) || isDigit(following) {
                end += 1
            } else {
                while end < scalars.count, isWordScalar(scalars[end]) { end += 1 }
            }
            commandPosition = false
            emit(upTo: end, end > index + 1 ? .number : nil)
        }

        private func endOfLine(from start: Int) -> Int {
            var end = start
            while end < scalars.count, scalars[end] != "\n" { end += 1 }
            return end
        }

        /// The end of the string that opens at `start`. Python's single-quoted
        /// strings end at the line; its triple-quoted ones and the shell's may
        /// span lines. An unclosed string runs to the end.
        private func endOfString(from start: Int) -> Int {
            let quote = scalars[start]
            let isTriple = language == .python && start + 2 < scalars.count
                && scalars[start + 1] == quote && scalars[start + 2] == quote
            var end = start + (isTriple ? 3 : 1)
            while end < scalars.count {
                let scalar = scalars[end]
                if scalar == "\\", !(language == .shell && quote == "'") {
                    end += 2
                    continue
                }
                if scalar == "\n", language == .python, !isTriple { return end }
                if scalar == quote {
                    if !isTriple { return end + 1 }
                    if end + 2 < scalars.count, scalars[end + 1] == quote, scalars[end + 2] == quote { return end + 3 }
                }
                end += 1
            }
            return scalars.count
        }

        /// Adds `scalars[index..<end]` as `token`, starting a new line at each line break.
        private mutating func emit(upTo end: Int, _ token: ChatCodeToken?) {
            let end = min(end, scalars.count)
            var start = index
            for position in index..<end where scalars[position] == "\n" {
                append(start..<position, token)
                flushLine()
                start = position + 1
            }
            append(start..<end, token)
            index = max(end, index + 1)
        }

        private mutating func append(_ range: Range<Int>, _ token: ChatCodeToken?) {
            guard !range.isEmpty else { return }
            if let current = pending, current.token == token, current.range.upperBound == range.lowerBound {
                pending = (current.range.lowerBound..<range.upperBound, token)
            } else {
                closeRun()
                pending = (range, token)
            }
        }

        private mutating func closeRun() {
            guard let current = pending else { return }
            runs.append(.init(text: String(String.UnicodeScalarView(scalars[current.range])), token: current.token))
            pending = nil
        }

        private mutating func flushLine() {
            closeRun()
            lines.append(ChatCodeLine(runs: runs))
            runs = []
        }

        private func next(after position: Int, skippingSpaces: Bool = false) -> Unicode.Scalar? {
            var position = position + 1
            while skippingSpaces, position < scalars.count, scalars[position] == " " || scalars[position] == "\t" {
                position += 1
            }
            return position < scalars.count ? scalars[position] : nil
        }

        private func isShellBreak(_ scalar: Unicode.Scalar) -> Bool {
            isSpace(scalar) || ";|&(".unicodeScalars.contains(scalar)
        }
        private func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" || scalar == "\n" }
        private func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
        private func isWordStart(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar == "_" || scalar.properties.isAlphabetic
        }
        private func isWordScalar(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return isWordStart(scalar) || isDigit(scalar)
        }
    }
}
