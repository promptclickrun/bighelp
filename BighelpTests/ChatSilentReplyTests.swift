import Foundation
import Testing
@testable import Bighelp

/// The app shows what Hermes would deliver. Marker cases come from Hermes' own
/// tests of `gateway/response_filters.py`.
@MainActor
struct ChatSilentReplyTests {
    @Test func exactMarkersMatchHermes() {
        let markers = ["[SILENT]", " SILENT ", "NO_REPLY", "no reply", "  no_reply\n", "*SILENT*", "NO_REPLY.",
                       "[静默]", "**沉默**", "【静默】", "静默。", "【沉默】", "沉默。", "**[静默]**"]
        for marker in markers { #expect(ChatSilentReply.isMarker(marker), "\(marker)") }
        let prose = ["", "   ", "Use NO_REPLY when no answer is needed.", "The reply was [SILENT], intentionally.",
                     "status: 静默 means the lane is quiet", "Silent films are great.", "[SILENT", "SILENT]",
                     String(repeating: "[SILENT]", count: 9)]
        for text in prose { #expect(!ChatSilentReply.isMarker(text), "\(text)") }
    }

    @Test func streamingHoldsOnlyWhatMayStillBecomeAMarker() {
        for partial in ["[", "[SIL", "N", "no_rep", "[静", "[SILENT]"] {
            #expect(ChatSilentReply.mayBecomeMarker(partial), "\(partial)")
        }
        for text in ["", "Sure!", "No problem", "Nope, that's wrong", "[Link](https://example.com)"] {
            #expect(!ChatSilentReply.mayBecomeMarker(text), "\(text)")
        }
    }

    @Test func aBareMarkerAnsweringThePersonShowsHermesNotice() {
        let person = Self.message(.human, "Thanks!")
        let marker = Self.message(.assistant, "NO_REPLY")
        #expect(ChatSilentReply.presentation(of: marker, after: person, lane: .chat) == .notice)
        #expect(ChatSilentReply.presented([person, marker], lane: .chat).map(Self.text)
            == ["Thanks!", ChatSilentReply.notice])
        // A list rebuilt from the middle still knows what came before it.
        #expect(ChatSilentReply.presented([marker], lane: .chat, after: person).map(Self.text) == [ChatSilentReply.notice])
    }

    @Test func aReactionToThePersonIsTheWholeReply() {
        let person = Self.message(.human, "Ok")
        let marker = Self.message(.assistant, "[SILENT]")
        #expect(ChatSilentReply.presentation(of: marker, after: person, lane: .chat, answeredWithReaction: true) == .hide)
        #expect(ChatSilentReply.presented([person, marker], lane: .chat, reactedTo: { $0.id == person.id })
            .map(Self.text) == ["Ok"])
        #expect(ChatSilentReply.presented([marker], lane: .chat, after: person, reactedTo: { $0.id == person.id }).isEmpty)
        // A reaction on an earlier message doesn't excuse a bare marker to this one.
        let earlier = Self.message(.human, "Morning")
        #expect(ChatSilentReply.presented([earlier, Self.message(.assistant, "Hi!"), person, marker], lane: .chat,
                                          reactedTo: { $0.id == earlier.id }).map(Self.text).last == ChatSilentReply.notice)
    }

    @Test func silenceAfterSomethingUnseenOrInRoomsAndScheduledRunsLeavesNoBubble() {
        let person = Self.message(.human, "Thanks!")
        let marker = Self.message(.assistant, "[SILENT]")
        // An off-screen note is hidden, so the marker follows the agent's own message.
        #expect(ChatSilentReply.presentation(of: marker, after: Self.message(.assistant, "Here you go."), lane: .chat) == .hide)
        #expect(ChatSilentReply.presentation(of: marker, after: nil, lane: .chat) == .hide)
        #expect(ChatSilentReply.presentation(of: marker, after: person, lane: .room) == .hide)
        #expect(ChatSilentReply.presentation(of: marker, after: person, lane: .scheduled) == .hide)
        #expect(ChatSilentReply.presented([marker], lane: .chat).isEmpty)
    }

    @Test func proseStreamingAndPeoplesOwnWordsShowAsWritten() {
        let person = Self.message(.human, "Thanks!")
        #expect(ChatSilentReply.presentation(of: Self.message(.assistant, "Say [SILENT] to skip."), after: person, lane: .chat) == .show)
        #expect(ChatSilentReply.presentation(of: Self.message(.human, "[SILENT]"), after: nil, lane: .chat) == .show)
        #expect(ChatSilentReply.presentation(of: Self.message(.assistant, "[SIL", streaming: true), after: person, lane: .chat) == .hide)
        #expect(ChatSilentReply.presentation(of: Self.message(.assistant, "Sure", streaming: true), after: person, lane: .chat) == .show)
    }

    @Test func savedHistoryUsesEachTurnsRealKind() throws {
        let rows = try [
            Self.row(1, "user", "Tell me a joke"),
            Self.row(2, "assistant", "[SILENT]"),
            Self.row(3, "user", "[The user reacted ❤️ to your message]", displayKind: "hidden"),
            Self.row(4, "assistant", "NO_REPLY"),
            Self.row(5, "user", "Background job finished", displayKind: "internal_notification"),
            Self.row(6, "assistant", "SILENT"),
            Self.row(7, "user", "Group chatter", replyExpected: false),
            Self.row(8, "assistant", "[SILENT]"),
            Self.row(9, "user", "Anything new?"),
            Self.row(10, "assistant", "Say [SILENT] to skip.")
        ].map { try DirectHermesHistoryRow($0, sessionID: "tip") }
        let chat = try DirectHermesHistoryProjection(rows: rows, appID: "app", profileID: "alpha", source: nil, sourceOrderBase: 0)
        #expect(chat.messages.map(Self.text) == ["Tell me a joke", ChatSilentReply.notice, "Group chatter",
                                                 "Anything new?", "Say [SILENT] to skip."])
        // A scheduled run's prompt isn't a person waiting for an answer.
        let cron = try DirectHermesHistoryProjection(rows: rows, appID: "app", profileID: "alpha", source: "cron", sourceOrderBase: 0)
        #expect(!cron.messages.map(Self.text).contains(ChatSilentReply.notice))
        // A page that starts mid-turn doesn't know who asked, so it stays quiet.
        let page = try DirectHermesHistoryProjection(rows: Array(rows[1...]), appID: "app", profileID: "alpha", source: nil, sourceOrderBase: 1)
        #expect(!page.messages.map(Self.text).contains(ChatSilentReply.notice))
    }

    @Test func savedHistoryCountsTheAgentsReactionAsTheReply() throws {
        let rows = try [
            Self.row(1, "user", "Ok", reactions: [("👍", "agent")]),
            Self.row(2, "assistant", "[SILENT]"),
            Self.row(3, "user", "Got it", reactions: [("❤️", "user")]),
            Self.row(4, "assistant", "NO_REPLY")
        ].map { try DirectHermesHistoryRow($0, sessionID: "tip") }
        let chat = try DirectHermesHistoryProjection(rows: rows, appID: "app", profileID: "alpha", source: nil, sourceOrderBase: 0)
        // Only the agent's own reaction answers; the person's reaction on their message doesn't.
        #expect(chat.messages.map(Self.text) == ["Ok", "Got it", ChatSilentReply.notice])
    }

    private static func message(_ role: TimelineRole, _ text: String, streaming: Bool = false) -> TimelineItem {
        TimelineItem(id: UUID().uuidString, role: role,
                     sender: role == .human ? .user(snapshot: .init(name: "You")) : .agent(id: "default", snapshot: .init(name: "Juno")),
                     content: .message(text),
                     metadata: .init(source: "Direct Hermes", delivery: streaming ? "Streaming" : "Received"))
    }

    private static func text(_ item: TimelineItem) -> String {
        guard case .message(let text) = item.content else { return "" }
        return text
    }

    private static func row(_ id: Int, _ role: String, _ content: String, displayKind: String? = nil,
                            replyExpected: Bool? = nil, reactions: [(String, String)] = []) -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = [
            "id": .integer(id), "session_id": .string("tip"), "role": .string(role),
            "content": .string(content), "timestamp": .number(Double(id)),
            "tool_calls": .null, "tool_call_id": .null, "tool_name": .null
        ]
        if let displayKind { value["display_kind"] = .string(displayKind) }
        var metadata: [String: BighelpJSONValue] = [:]
        if let replyExpected { metadata["reply_expected"] = .boolean(replyExpected) }
        if !reactions.isEmpty {
            metadata["reactions"] = .array(reactions.map { .object(["emoji": .string($0.0), "author": .string($0.1)]) })
        }
        if !metadata.isEmpty { value["display_metadata"] = .object(metadata) }
        return .object(value)
    }
}
