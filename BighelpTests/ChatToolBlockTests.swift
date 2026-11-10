import Foundation
import Testing
@testable import Bighelp

/// An unfolded tool call is one block: what the agent asked for, then what came back (#943).
@MainActor
struct ChatToolBlockTests {
    private func tool(_ name: String = "read_file", arguments: String? = nil, result: String? = nil,
                      summary: String? = nil, detail: String? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "t", sessionID: "session", turnID: "turn", kind: .tool, lifecycle: .succeeded,
                          title: name, summary: summary, detail: detail, occurredAt: 1, toolCallID: "call",
                          toolName: name, arguments: arguments, result: result)
    }

    @Test func theRequestIsOneLineThatLeadsWithWhatItWasAbout() {
        let block = ChatToolBlock(event: tool(arguments: #"{"offset":1,"path":"/tmp/notes.md","limit":200}"#))
        #expect(block.ask == .init(line: "/tmp/notes.md · Limit 200 · Offset 1"))
        #expect(block.answer.isEmpty)
    }

    @Test func theAnswerKeepsItsTextAndPutsShortValuesOnOneLine() {
        let block = ChatToolBlock(event: tool(
            arguments: #"{"path":"notes.md"}"#,
            result: #"{"content":"line one\nline two","success":true,"total_lines":2}"#))
        #expect(block.ask.line == "notes.md")
        #expect(block.answer.line == "Success Yes · Total lines 2")
        // One text needs no name; nothing shows as JSON.
        #expect(block.answer.passages == [.init(label: nil, text: "line one\nline two")])
        #expect(block.copyText == "notes.md\n\nSuccess Yes · Total lines 2\nline one\nline two")
    }

    @Test func severalTextsKeepTheirNames() {
        let block = ChatToolBlock(event: tool("patch", arguments:
            #"{"path":"a.swift","old_string":"let a = 1","new_string":"let a = 2"}"#))
        #expect(block.ask.line == "a.swift")
        #expect(block.ask.passages.map(\.label) == ["New string", "Old string"])
    }

    @Test func textThatIsNotJSONShowsAsItIs() {
        let block = ChatToolBlock(event: tool(arguments: "notes.md", result: "  Saved.\n"))
        #expect(block.ask.passages == [.init(label: nil, text: "notes.md")])
        #expect(block.answer.passages == [.init(label: nil, text: "Saved.")])
    }

    @Test func hermesOwnWordsJoinTheAnswerOnlyWhereTheyAdd() {
        let short = ChatToolBlock(event: tool(result: #"{"ok":true}"#, summary: "Read 2 lines", detail: "Read 2 lines"))
        #expect(short.answer.line == "Read 2 lines · OK Yes")
        #expect(short.answer.passages.isEmpty)

        let repeated = ChatToolBlock(event: tool(result: "Saved.", summary: "Saved.", detail: "Saved."))
        #expect(repeated.answer == .init(passages: [.init(label: nil, text: "Saved.")]))

        let long = String(repeating: "word ", count: 30)
        let noted = ChatToolBlock(event: tool(result: "Saved.", detail: long))
        #expect(noted.answer.passages.map(\.label) == [nil, "Details"])
    }

    @Test func aCodeCellLeavesTheBlockOnlyWhatItDoesNotShow() {
        let event = tool("terminal", arguments: #"{"command":"npm test"}"#, result: #"{"output":"ok","exit_code":0}"#)
        #expect(ChatToolBlock(event: event, showsCodeCell: true).isEmpty)
        #expect(!ChatToolBlock(event: event).isEmpty)
    }
}
