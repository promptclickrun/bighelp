import Foundation
import Testing
@testable import Bighelp

/// A tool's arguments and result, unfolded: key facts and real text, not
/// escaped JSON.
struct ChatToolReadableDetailTests {
    private typealias Item = ChatToolReadableDetail.Item

    @Test func aCommandResultShowsItsExitCodeAndRealOutputLines() throws {
        let raw = #"{"output":"Cloning into 'weather-app'...\nremote: Counting objects: 42, done.\n","exit_code":0,"error":null}"#
        let detail = try #require(ChatToolReadableDetail.parse(raw))
        #expect(detail.items == [
            .fact(label: "Exit code", value: "0"),
            .block(label: "Output", text: "Cloning into 'weather-app'...\nremote: Counting objects: 42, done."),
        ])
    }

    @Test func argumentsPutTheCommandOrPathFirst() throws {
        let raw = #"{"timeout":120,"command":"git clone https://github.com/example/app.git","background":false}"#
        let detail = try #require(ChatToolReadableDetail.parse(raw))
        #expect(detail.items.first == .block(label: "Command", text: "git clone https://github.com/example/app.git"))
        #expect(detail.items.contains(.fact(label: "Timeout", value: "120")))
        #expect(detail.items.contains(.fact(label: "Background", value: "No")))

        let file = try #require(ChatToolReadableDetail.parse(#"{"offset":1,"path":"/tmp/notes.md","limit":200}"#))
        #expect(file.items.first == .fact(label: "Path", value: "/tmp/notes.md"))
    }

    /// Hermes often wraps a JSON result in a JSON string; it unwraps once.
    @Test func aResultEncodedTwiceIsReadOnce() throws {
        let inner = #"{"content":"line one\nline two","total_lines":2}"#
        let outer = String(decoding: try JSONSerialization.data(withJSONObject: inner, options: .fragmentsAllowed),
                           as: UTF8.self)
        let detail = try #require(ChatToolReadableDetail.parse(outer))
        #expect(detail.items == [
            .block(label: "Content", text: "line one\nline two"),
            .fact(label: "Total lines", value: "2"),
        ])
    }

    @Test func searchResultsBecomeAListOfTitlesAndAddresses() throws {
        let raw = #"""
        {"success":true,"data":{"web":[
          {"title":"Ryokan Hatanaka","url":"https://hatanaka.example","description":"Steps from Yasaka Shrine"},
          {"title":"Gion Hatanaka Inn","url":"https://inn.example"}
        ]}}
        """#
        let detail = try #require(ChatToolReadableDetail.parse(raw))
        #expect(detail.items == [
            .fact(label: "Success", value: "Yes"),
            .block(label: "Data › Web", text: """
            • Ryokan Hatanaka — https://hatanaka.example
              Steps from Yasaka Shrine
            • Gion Hatanaka Inn — https://inn.example
            """),
        ])
    }

    @Test func shortListsReadInlineAndLongOnesAreTrimmed() throws {
        let short = try #require(ChatToolReadableDetail.parse(#"{"urls":["https://a.example","https://b.example"]}"#))
        #expect(short.items == [.fact(label: "URLs", value: "https://a.example, https://b.example")])

        let files = (1...30).map { "file-\($0).txt" }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
        let long = try #require(ChatToolReadableDetail.parse(json))
        guard case .block(let label, let text)? = long.items.first else {
            Issue.record("Expected a list block")
            return
        }
        #expect(label == "Files")
        #expect(text.split(separator: "\n").count == 21)
        #expect(text.hasSuffix("… and 10 more"))
    }

    @Test func emptyValuesAreLeftOutAndPlainTextIsNotParsed() throws {
        let detail = try #require(ChatToolReadableDetail.parse(#"{"error":null,"stderr":"","warnings":[],"ok":true}"#))
        #expect(detail.items == [.fact(label: "OK", value: "Yes")])
        #expect(ChatToolReadableDetail.parse("Command completed successfully") == nil)
        #expect(ChatToolReadableDetail.parse("42") == nil)
        #expect(ChatToolReadableDetail.parse("") == nil)
        // A JSON string that isn't JSON inside is just its text, unescaped.
        #expect(ChatToolReadableDetail.parse(#""first\nsecond""#)?.items == [.block(label: nil, text: "first\nsecond")])
    }

    @Test func veryLargeValuesAreLeftForTheFullReader() {
        let huge = #"{"content":""# + String(repeating: "x", count: 300_000) + #""}"#
        #expect(ChatToolReadableDetail.parse(huge) == nil)
    }
}
