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
}
