import Foundation
import Testing
@testable import Bighelp

/// Code a tool ran, unfolded as a notebook cell (#926): the code, its
/// language and colors, what it printed and how it ended.
struct ChatToolCodeCellTests {
    private func event(_ tool: String?, arguments: String?, result: String?,
                       lifecycle: ChatActivityLifecycle = .succeeded) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "code", sessionID: "session", turnID: "turn", kind: .tool, lifecycle: lifecycle,
                          title: tool ?? "tool", summary: nil, detail: nil, occurredAt: 1, toolCallID: "call",
                          toolName: tool, arguments: arguments, result: result)
    }

    /// Hermes' `execute_code` result: what the code printed is in `output`.
    @Test func pythonShowsItsCodeAndWhatItPrinted() throws {
        let cell = try #require(ChatToolCodeCell.make(for: event("execute_code",
            arguments: #"{"code":"import math\nprint(math.pi)\n"}"#,
            result: #"{"status":"success","output":"3.141592653589793\n","tool_calls_made":0,"duration_seconds":0.1}"#)))
        #expect(cell.language == .python)
        #expect(cell.code == "import math\nprint(math.pi)")
        #expect(cell.lines.map(\.text) == ["import math", "print(math.pi)"])
        #expect(cell.output == "3.141592653589793\n")
        #expect(cell.error == nil)
        #expect(cell.ending == .succeeded)
    }

    /// Output that is one value (`84.5`) is text to show, never JSON to rewrite (#924).
    @Test func oneValueOfOutputStaysText() throws {
        let cell = try #require(ChatToolCodeCell.make(for: event("execute_code",
            arguments: #"{"code":"print(84.5)"}"#, result: #"{"status":"success","output":"84.5\n"}"#)))
        #expect(cell.output == "84.5\n")
        #expect(ChatToolDetailPreview(cell.output ?? "").text == "84.5\n")
    }

    /// A shell command that exits with an error ends badly, whatever the tool call's own status.
    @Test func aShellCommandThatExitsWithAnErrorFailed() throws {
        let cell = try #require(ChatToolCodeCell.make(for: event("terminal",
            arguments: #"{"command":"python3 check.py","timeout":60}"#,
            result: #"{"output":"FileNotFoundError: week45.csv","exit_code":1,"error":null}"#)))
        #expect(cell.language == .shell)
        #expect(cell.code == "python3 check.py")
        #expect(cell.exitCode == 1)
        #expect(cell.ending == .failed)
    }

    @Test func aPythonErrorShowsOnceAndEndsBadly() throws {
        let failed = try #require(ChatToolCodeCell.make(for: event("execute_code",
            arguments: #"{"code":"1/0"}"#,
            result: #"{"status":"error","output":"","error":"ZeroDivisionError: division by zero"}"#)))
        #expect(failed.output == nil)
        #expect(failed.error == "ZeroDivisionError: division by zero")
        #expect(failed.ending == .failed)

        // A timeout notice Hermes already put in the output isn't repeated as the error.
        let timedOut = try #require(ChatToolCodeCell.make(for: event("execute_code",
            arguments: #"{"code":"while True: pass"}"#,
            result: #"{"status":"timeout","output":"Timed out after 300s","error":"Timed out after 300s"}"#)))
        #expect(timedOut.error == nil)
        #expect(timedOut.ending == .failed)
    }

    /// A result inside a JSON string is read once; one in another shape shows as it came.
    @Test func otherResultsShowAsTheyCame() throws {
        let inner = #"{"output":"ok","exit_code":0}"#
        let wrapped = String(decoding: try JSONSerialization.data(withJSONObject: inner, options: .fragmentsAllowed),
                             as: UTF8.self)
        let unwrapped = try #require(ChatToolCodeCell.make(for: event("terminal",
            arguments: #"{"command":"echo ok"}"#, result: wrapped)))
        #expect(unwrapped.output == "ok")

        let plain = try #require(ChatToolCodeCell.make(for: event("terminal",
            arguments: #"{"command":"echo ok"}"#, result: "Command finished")))
        #expect(plain.output == "Command finished")
    }

    @Test func aRunningCallHasCodeButNoOutputYet() throws {
        let cell = try #require(ChatToolCodeCell.make(for: event("execute_code",
            arguments: #"{"code":"import time"}"#, result: nil, lifecycle: .running)))
        #expect(cell.output == nil)
        #expect(cell.ending == .running)
    }

    /// Only code tools make a cell, and only with code to show.
    @Test func otherToolsAndMissingCodeKeepTheReadableDetails() {
        #expect(ChatToolCodeCell.make(for: event("read_file", arguments: #"{"path":"/tmp/a"}"#, result: "a")) == nil)
        #expect(ChatToolCodeCell.make(for: event("execute_code", arguments: #"{"code":"  "}"#, result: nil)) == nil)
        #expect(ChatToolCodeCell.make(for: event("terminal", arguments: "not json", result: nil)) == nil)
        #expect(ChatToolCodeCell.make(for: event("execute_code", arguments: nil, result: "1")) == nil)
    }

    /// The token of the first run that is exactly `text`; nil when it's plain or missing.
    private func token(_ text: String, _ line: ChatCodeLine) -> ChatCodeToken? {
        line.runs.first { $0.text == text }?.token
    }

    @Test func pythonKeywordsStringsNumbersCommentsAndCalls() {
        let lines = ChatCodeSyntax.lines("from x import y\nresult = round(total / 4, 1)  # the mean\nprint(f\"{result}\", None)",
                                         language: .python)
        #expect(token("from", lines[0]) == .keyword)
        #expect(token("import", lines[0]) == .keyword)
        #expect(token("round", lines[1]) == .call)
        #expect(token("4", lines[1]) == .number)
        #expect(token("# the mean", lines[1]) == .comment)
        #expect(token("f\"{result}\"", lines[2]) == .string)
        #expect(token("None", lines[2]) == .number)
    }

    /// A string or comment marker inside a string stays string; a triple-quoted
    /// string colors every line it spans.
    @Test func pythonStringsSpanLinesAndHideMarkers() {
        let lines = ChatCodeSyntax.lines("note = \"\"\"first # not a comment\nsecond\"\"\"\nx = 'it''s'", language: .python)
        #expect(lines.count == 3)
        #expect(lines[0].runs.last == .init(text: "\"\"\"first # not a comment", token: .string))
        #expect(lines[1].runs == [.init(text: "second\"\"\"", token: .string)])
        #expect(lines[2].runs.last == .init(text: "'it''s'", token: .string))
    }

    @Test func shellCommandsVariablesAndKeywords() {
        let lines = ChatCodeSyntax.lines("cd app && npm test --watch=false\nif [ -n \"$HOME\" ]; then echo $PATH; fi # done",
                                         language: .shell)
        #expect(token("cd", lines[0]) == .call)
        #expect(token("npm", lines[0]) == .call)
        // A command's arguments stay plain.
        #expect(lines[0].runs.last == .init(text: " test --watch=false", token: nil))
        #expect(token("if", lines[1]) == .keyword)
        #expect(token("\"$HOME\"", lines[1]) == .string)
        #expect(token("echo", lines[1]) == .call)
        #expect(token("$PATH", lines[1]) == .number)
        #expect(token("# done", lines[1]) == .comment)
    }

    /// Every character comes back, in order, on the line it was on.
    @Test func highlightingKeepsEveryCharacter() {
        let code = "def f(a):\n\treturn a*2  # twice\n\n\ns = \"unclosed\nprint(s)"
        let lines = ChatCodeSyntax.lines(code, language: .python)
        #expect(lines.map(\.text).joined(separator: "\n") == code)
        #expect(lines[0].runs.contains(.init(text: "f", token: .call)))
    }
}
