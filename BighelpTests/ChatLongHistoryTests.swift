import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Bighelp

/// What keeps a long chat smooth: its rows aren't rebuilt for redraws that leave the
/// transcript alone, and the checks run on every message for each redraw stay cheap
/// without changing what they find.
@Suite(.serialized) @MainActor
struct ChatLongHistoryTests {
    @Test func markerSearchFindsEverythingContainsFinds() {
        let markers = ["```loopdy-card", "```loopdy-references-", "hermes"]
        let texts = [
            "", "plain answer", "```loopdy-card\n{}\n```", "before ```loopdy-references-v1\n{}",
            #"{"command":"hermes -p travel chat -q hi"}"#, "café ```loopdy-card 👋🏽", "e\u{301}```loopdy-card",
            "```loopdy-card\u{301}", "```loopdy-car", "HERMES", "ｈｅｒｍｅｓ",
            String(repeating: "Settled history. ", count: 2_000) + "```loopdy-card",
            NSString(string: "bridged ```loopdy-references-v1 text") as String,
        ]
        for marker in markers {
            for text in texts {
                if text.contains(marker) {
                    #expect(ChatTextMarker.mayContain(marker, in: text), "\(marker) in \(text.prefix(40))")
                }
            }
        }
        #expect(!ChatTextMarker.mayContain("```loopdy-card", in: "plain answer"))
        #expect(!ChatTextMarker.mayContain("```loopdy-card", in: "```loopdy-car"))
        #expect(!ChatTextMarker.mayContain("hermes", in: "HERMES"))
        #expect(ChatTextMarker.mayContain("", in: ""))
    }

    /// Text with the marker's bytes but not its characters reads exactly as before.
    @Test func markerBytesWithoutTheMarkerStillReadAsPlainText() {
        let text = "Here: ```loopdy-card\u{301}\n{}\n```"
        #expect(ChatCardMessageProjection.cardIDs(in: text).isEmpty)
        let decoded = ReferenceCodec.decode("A note ```loopdy-references-\u{301} here")
        #expect(decoded.failure == nil)
        #expect(decoded.prose == "A note ```loopdy-references-\u{301} here")
    }

    @Test func lifecycleLabelsAreStillEmptyReasoning() {
        func thought(_ detail: String?, summary: String? = nil) -> ChatActivityEvent {
            ChatActivityEvent(eventID: UUID().uuidString, sessionID: "s", turnID: "t", kind: .reasoning,
                              lifecycle: .succeeded, title: "Reasoning", summary: summary, detail: detail, occurredAt: 1)
        }
        #expect(thought("Response ready").reasoningText == nil)
        #expect(thought("  \n PREPARING A RESPONSE \n").reasoningText == nil)
        #expect(thought(String(repeating: " ", count: 60) + "reasoning completed" + String(repeating: "\n", count: 60))
            .reasoningText == nil)
        #expect(thought("   ").reasoningText == nil)
        #expect(thought("", summary: "Checking the invoices").reasoningText == "Checking the invoices")
        #expect(thought("preparing a response.").reasoningText == "preparing a response.")
        let long = String(repeating: "Totals by vendor first. ", count: 40)
        #expect(thought(long).reasoningText == long)
    }

    /// Reopening a long chat merges the saved thinking with the host's tools, so most tools
    /// arrive after thinking that comes later in the chat. Building the ledger from that
    /// must not grow with the square of the chat's length.
    @Test func buildingALongLedgerOutOfOrderStaysQuick() {
        let sessionID = "ledger-build"
        func event(_ index: Int, kind: ChatActivityKind, running: Bool = false) -> ChatActivityEvent {
            let turn = index / 3
            return ChatActivityEvent(
                eventID: "\(kind.rawValue)-\(index)", sessionID: sessionID, turnID: "turn-\(turn)", kind: kind,
                lifecycle: running ? .running : .succeeded, title: kind == .tool ? "read_file" : "Reasoning",
                summary: nil, detail: kind == .tool ? nil : "Thinking \(index)", occurredAt: index,
                toolCallID: kind == .tool ? "call-\(index)" : nil, toolName: kind == .tool ? "read_file" : nil,
                arguments: kind == .tool ? #"{"path":"a.csv"}"# : nil, result: kind == .tool ? "ok" : nil,
                sourceOrder: index)
        }
        let turns = 1_500
        let thinking = (0..<turns).map { event($0 * 3, kind: .reasoning) }
        let tools = (0..<turns).flatMap { [event($0 * 3 + 1, kind: .tool), event($0 * 3 + 2, kind: .tool)] }
        let started = ContinuousClock.now
        let ledger = ChatActivityLedger(sessionID: sessionID, events: thinking + tools + thinking)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(800), "Took \(elapsed)")
        #expect(ledger.allEvents.map(\.sourceOrder) == (0..<(turns * 3)).map { $0 })
        #expect(ledger.turnIDs == (0..<turns).map { "turn-\($0)" })
        #expect(ledger.events(for: "turn-7").map(\.sourceOrder) == [21, 22, 23])
    }

    /// Building the ledger in one go leaves it as receiving each event in turn would,
    /// with updates, events that arrive early or late, and events without an order.
    @Test func buildingALedgerMatchesReceivingItsEvents() {
        let sessionID = "ledger-same"
        var events: [ChatActivityEvent] = []
        for index in [5, 1, 9, 3, 7, 2, 8, 0, 6, 4, 11, 10] {
            events.append(ChatActivityEvent(
                eventID: "e\(index)", sessionID: sessionID, turnID: "turn-\(index % 4)", kind: .tool, lifecycle: .running,
                title: "terminal", summary: nil, detail: nil, occurredAt: 100 - index, toolCallID: "call-\(index)",
                toolName: "terminal", arguments: #"{"command":"ls"}"#,
                sourceOrder: index == 11 ? nil : index * 2))
        }
        // Later reports of the same calls: finished, and one at an earlier order.
        events += [3, 8, 11].map { index in
            ChatActivityEvent(eventID: "e\(index)-done", sessionID: sessionID, turnID: "turn-\(index % 4)", kind: .tool,
                              lifecycle: .succeeded, title: "terminal", summary: "Done", detail: nil,
                              occurredAt: 200 + index, toolCallID: "call-\(index)", toolName: "terminal",
                              arguments: #"{"command":"ls"}"#, result: "ok",
                              sourceOrder: index == 8 ? 1 : nil)
        }
        let built = ChatActivityLedger(sessionID: sessionID, events: events)
        var received = ChatActivityLedger(sessionID: sessionID)
        for event in events { received.receive(event) }
        #expect(built.allEvents == received.allEvents)
        #expect(built.turnIDs == received.turnIDs)
        for turn in 0..<4 {
            #expect(built.events(for: "turn-\(turn)") == received.events(for: "turn-\(turn)"))
        }
        var builtNext = built
        var receivedNext = received
        let late = ChatActivityEvent(eventID: "late", sessionID: sessionID, turnID: "turn-9", kind: .tool,
                                     lifecycle: .running, title: "terminal", summary: nil, detail: nil, occurredAt: 1,
                                     toolCallID: "call-late", toolName: "terminal", sourceOrder: 3)
        #expect(builtNext.receive(late) == receivedNext.receive(late))
        #expect(builtNext.allEvents == receivedNext.allEvents)
        #expect(builtNext.turnIDs == receivedNext.turnIDs)
    }
}
