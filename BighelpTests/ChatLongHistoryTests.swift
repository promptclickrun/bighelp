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
    /// The row estimate counts lines in one pass over the text; it must come to what
    /// splitting the text into lines of Characters came to.
    @Test func wrappedLineCountMatchesCharacterLines() {
        let texts = [
            "", "one line", "two\nlines", "trailing\n", "\n\nleading", "a\n\n\nb",
            String(repeating: "Settled history. ", count: 400),
            "```python\n" + (0..<300).map { "    total += row[\($0)]  # week \($0)" }.joined(separator: "\n") + "\n```",
            "café ok\n" + String(repeating: "ü", count: 95),
        ]
        for columns: CGFloat in [10, 37.5, 80] {
            for text in texts {
                let split: CGFloat = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / columns)) }
                let counted: CGFloat = ChatCanvasTranscriptProjection.wrappedLineCount(text, columns: columns)
                #expect(counted == split, "\(text.prefix(20)) at \(columns)")
            }
        }
    }

    /// Plain text is worked out when read, and documents compare by their blocks as before.
    @Test func markdownPlainTextIsTheSameWhenRead() {
        let source = "### Week 4\n\n- **6 invoices** from `w4.csv`\n- [ ] Ask about PO-41\n\n"
            + "| Vendor | Amount |\n|---|---:|\n| *Parcel Bay* | $12.00 |\n\n```swift\nlet a = 1\n```\n\n> Nothing is late."
        let document = MarkdownDocument(source)
        #expect(document.visiblePlainText
            == "Week 4\n\n6 invoices from w4.csv\nAsk about PO-41\n\nVendor\tAmount\nParcel Bay\t$12.00\n\nlet a = 1\n\nNothing is late.")
        #expect(document == MarkdownDocument(source))
        #expect(document != MarkdownDocument(source + "!"))
    }

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

    /// Typing, the keyboard and the message box growing redraw the chat, but they don't
    /// change its transcript, so a long chat's rows aren't built again for them.
    @Test func typingInALongChatDoesNotRebuildItsRows() async throws {
        let model = ChatModel(conversationID: "long-history-typing", client: ConversationFixtureClient(),
                              initialItems: Self.history(turns: 200))
        let (window, controller) = try Self.host(model)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        let composer = try #require(Self.textViews(controller.view).first {
            $0.accessibilityIdentifier == "chat.composer.text"
        })
        #expect(composer.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(400))
        let built = model.transcriptCanvas.buildCount
        #expect(built > 0)
        for character in "Could you check the vendor invoices for this week? Then draft a note to the team.\n\nThanks!" {
            composer.insertText(String(character))
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(300))
        composer.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.draft.hasSuffix("Thanks!"))
        #expect(model.transcriptCanvas.buildCount == built,
                "The transcript didn't change, so its rows must not be built again.")

        // A new reply does change it, and shows.
        model.acceptExternal([Self.answer("live", "A fresh answer at the bottom", delivery: "Streaming")])
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        #expect(model.transcriptCanvas.buildCount > built)
        #expect(Self.textViews(controller.view).contains { $0.text.contains("A fresh answer at the bottom") })
    }

    /// The kept rows still follow a folder opened or closed by the reader.
    @Test func openingAFolderRebuildsTheKeptRows() async throws {
        let sender = TimelineSender.agent(id: "default", snapshot: .init(name: "Juno"))
        let items = [
            TimelineItem(id: "q", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("Check the invoices"), metadata: .init(sourceOrder: 1)),
            TimelineItem(id: "a", role: .assistant, sender: sender, content: .message("All six are paid."),
                         metadata: .init(delivery: "Delivered", sourceOrder: 4, turnDurationMilliseconds: 9_000)),
        ]
        let events = (2...3).map { order in
            ChatActivityEvent(eventID: "tool-\(order)", sessionID: "folder-cache", turnID: "turn", kind: .tool,
                              lifecycle: .succeeded, title: "read_file", summary: nil, detail: nil, occurredAt: order,
                              toolCallID: "call-\(order)", toolName: "read_file",
                              arguments: #"{"path":"invoices.csv"}"#, result: "ok", sourceOrder: order)
        }
        let model = ChatModel(conversationID: "folder-cache", client: ConversationFixtureClient(),
                              initialItems: items, initialActivityEvents: events)
        let (window, controller) = try Self.host(model)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let table = try #require(Self.tables(controller.view).first)
        let folded = table.numberOfRows(inSection: 0)
        let built = model.transcriptCanvas.buildCount
        let fold = try #require(model.transcriptCanvas.rows.compactMap { row -> String? in
            if case .transcript(.completed(let turn)) = row { return turn.id }
            return nil
        }.first)
        model.activityDisclosures.setCompletedTurnExpanded(true, id: fold)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.transcriptCanvas.buildCount > built)
        #expect(table.numberOfRows(inSection: 0) > folded)
    }

    /// Keeping turns that didn't change gives exactly the rows (and message groups) that
    /// projecting the whole chat again would, through a turn that streams, works, finishes
    /// and starts again, with folders opened and closed, every fold and interim-note
    /// setting, in Simple Bot mode, and with agents messaging each other.
    @Test(arguments: [false, true])
    func keptTurnsMatchProjectingTheWholeChat(withAgentTalk: Bool) throws {
        let card = try JSONDecoder().decode(GenerativeUICard.self, from: Data(Self.cardJSON.utf8))
        let sessionID = "turn-cache"
        let agent = TimelineSender.agent(id: "default", snapshot: .init(name: "Juno"))
        var items: [TimelineItem] = []
        var events: [ChatActivityEvent] = []
        for turn in 0..<12 {
            let base = turn * 10 + 10
            items.append(TimelineItem(id: "q\(turn)", role: .human, sender: .user(snapshot: .init(name: "You")),
                                      content: .message("Question \(turn)"),
                                      metadata: .init(timestamp: Date(timeIntervalSince1970: Double(base)), sourceOrder: base)))
            // Two questions in a row: the second groups with the first across the turn.
            if turn == 7 { continue }
            events.append(ChatActivityEvent(eventID: "r\(turn)", sessionID: sessionID, turnID: "t\(turn)", kind: .reasoning,
                                            lifecycle: .succeeded, title: "Reasoning", summary: nil,
                                            detail: "Thinking about \(turn)", occurredAt: base + 1,
                                            durationMilliseconds: turn.isMultiple(of: 3) ? 2_000 : nil, sourceOrder: base + 1))
            if turn.isMultiple(of: 2) {
                items.append(Self.answer("n\(turn)", "Looking first.", order: base + 2))
            }
            events.append(Self.tool("tool\(turn)", turn: "t\(turn)", order: base + 3, session: sessionID))
            if turn == 5, withAgentTalk {
                events.append(ChatActivityEvent(
                    eventID: "talk", sessionID: sessionID, turnID: "t\(turn)", kind: .tool, lifecycle: .succeeded,
                    title: "terminal", summary: nil, detail: nil, occurredAt: base + 4, durationMilliseconds: 900,
                    toolCallID: "call-talk", toolName: "terminal",
                    arguments: #"{"command":"hermes -p travel chat -Q --oneshot -q 'Hotel ideas?'"}"#,
                    result: #"{"output":"Two near the station.","exit_code":0}"#, sourceOrder: base + 4))
            }
            if turn == 3 {
                items.append(TimelineItem(id: "live-card", role: .assistant, sender: agent, content: .generativeUI(card),
                                          metadata: .init(sourceOrder: base + 4)))
            }
            items.append(Self.answer("a\(turn)", turn == 3 ? "Here:\n\n" + Self.cardFence : "Answer \(turn)",
                                     order: base + 5))
        }
        let model = ChatModel(conversationID: sessionID, client: ConversationFixtureClient(), initialItems: items,
                              initialActivityEvents: events)
        let caches = (0..<8).map { _ in ChatTranscriptCanvasCache() }
        var foldedRows: [ChatCanvasRow] = []
        func check(_ step: String) {
            var index = 0
            for folds in [true, false] {
                for placement in [ChatInterimReplyPlacement.inline, .fold, .hidden] {
                    for simpleBots in [false, true] where !simpleBots || placement == .inline {
                        let context = ChatTranscriptCanvasCache.DisplayContext(
                            ledgerRevision: model.activityLedgerRevision, isSending: model.isSending, isBotMode: false,
                            foldsCompletedTurns: folds, interimReplies: placement,
                            simpleBotsReasoning: simpleBots ? .init(agentName: "Juno", showsReasoning: true) : nil)
                        let kept = caches[index].buildCanvas(
                            from: model.transcriptEntries, activityEvents: { model.activityLedger.allEvents },
                            context: context, disclosures: model.activityDisclosures, readsAgentMessages: true)
                        let whole = ChatTranscriptCanvasCache.wholeCanvas(
                            from: model.transcriptEntries, activityEvents: model.activityLedger.allEvents,
                            context: context, disclosures: model.activityDisclosures, readsAgentMessages: true)
                        let setting = "\(step): folds \(folds), \(placement), simple bots \(simpleBots)"
                        if index == 0 { foldedRows = kept.rows }
                        #expect(kept.rows == whole.rows, "\(setting)")
                        #expect(kept.groupedIDs == whole.groupedIDs, "\(setting)")
                        #expect(kept.continuedIDs == whole.continuedIDs, "\(setting)")
                        index += 1
                    }
                }
            }
        }
        check("history")
        let fold = try #require(foldedRows.compactMap { row -> String? in
            if case .transcript(.completed(let turn)) = row { return turn.id }
            return nil
        }.dropFirst(2).first)
        model.activityDisclosures.setCompletedTurnExpanded(true, id: fold)
        check("folder opened")
        model.isSending = true
        model.acceptExternal([TimelineItem(id: "q-new", role: .human, sender: .user(snapshot: .init(name: "You")),
                                           content: .message("One more"), metadata: .init(sourceOrder: 500))])
        check("question")
        model.acceptActivity(Self.tool("live-tool", turn: "t-new", order: 501, session: sessionID, running: true))
        check("running tool")
        model.acceptExternal([Self.answer("n-new", "Checking now.", order: 502)], isLiveAssistantText: true)
        check("interim note")
        let beforeTool = caches[0].turnBuildCount
        model.acceptActivity(Self.tool("live-tool", turn: "t-new", order: 501, session: sessionID))
        check("tool finished")
        if !withAgentTalk {
            #expect(caches[0].turnBuildCount == beforeTool + 1, "A tool in the last turn folds only that turn again.")
        }
        // Work Hermes reports late for an old turn changes that turn's fold.
        model.acceptActivity(Self.tool("late-tool", turn: "t2", order: 36, session: sessionID))
        check("late work in an old turn")
        // With tool calls hidden, such work changes only the ledger; the fold still counts it.
        model.setToolCallsVisible(false)
        check("tool calls hidden")
        model.acceptActivity(Self.tool("hidden-late-tool", turn: "t4", order: 57, session: sessionID))
        check("hidden late work in an old turn")
        model.setToolCallsVisible(true)
        check("tool calls shown")
        for words in ["The", "The totals", "The totals are in."] {
            model.acceptExternal([Self.answer("a-new", words, delivery: "Streaming", order: 503)], isLiveAssistantText: true)
            check("streaming \(words)")
        }
        model.acceptExternal([Self.answer("a-new", "The totals are in.", order: 503)])
        check("answer")
        model.isSending = false
        check("turn ended")
        model.activityDisclosures.setCompletedTurnExpanded(false, id: fold)
        check("folder closed")
        let folded = caches[0].turnBuildCount
        model.acceptExternal([Self.answer("a-late", "Two of them are late.", order: 504)])
        check("late note")
        if !withAgentTalk {
            #expect(caches[0].turnBuildCount == folded + 1, "Only the turn that changed is folded again.")
        }
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

    private static let cardJSON = #"{"schema":"loopdy.generative_ui","version":1,"component":"summary","title":"Totals","body":"Six invoices"}"#
    private static var cardFence: String { "```loopdy-card\n" + cardJSON + "\n```" }

    private static func tool(_ id: String, turn: String, order: Int, session: String, running: Bool = false) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: session, turnID: turn, kind: .tool,
                          lifecycle: running ? .running : .succeeded, title: "read_file", summary: nil, detail: nil,
                          occurredAt: order, durationMilliseconds: running ? nil : 400, toolCallID: "call-\(id)",
                          toolName: "read_file", arguments: #"{"path":"week.csv"}"#, result: running ? nil : "ok",
                          sourceOrder: order)
    }

    static func history(turns: Int) -> [TimelineItem] {
        (0..<turns).flatMap { turn -> [TimelineItem] in
            [
                TimelineItem(id: "q-\(turn)", role: .human, sender: .user(snapshot: .init(name: "You")),
                             content: .message("Question \(turn): what changed this week?"),
                             metadata: .init(delivery: "Saved", sourceOrder: turn * 2)),
                answer("a-\(turn)", "### Week \(turn)\n\n- **Six** invoices\n- See [the calendar](https://example.com/\(turn))",
                       order: turn * 2 + 1),
            ]
        }
    }

    static func answer(_ id: String, _ text: String, delivery: String = "Delivered", order: Int? = nil) -> TimelineItem {
        TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                     content: .message(text), metadata: .init(delivery: delivery, sourceOrder: order))
    }

    static func host(_ model: ChatModel) throws -> (UIWindow, UIViewController) {
        let controller = UIHostingController(rootView: ChatView(model: model).environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        return (window, controller)
    }

    static func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    static func tables(_ view: UIView) -> [UITableView] {
        (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
}
