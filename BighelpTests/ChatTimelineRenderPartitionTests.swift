import Testing
import SwiftUI
import UIKit
@testable import Bighelp

@Suite(.serialized) @MainActor
struct ChatTimelineRenderPartitionTests {
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func longAssistantRepliesUseTheAvailablePhoneWidth(typeSize: DynamicTypeSize) async throws {
        let text = """
        I can help inspect code, test changes, and explain what I find. A useful reply should be easy to read without being squeezed into a narrow column.

        Longer paragraphs need room for complete phrases, with comfortable padding and the text size you chose.
        """
        let item = TimelineItem(id: "readable-reply", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message(text), metadata: .init(delivery: "Delivered"))
        let model = ChatModel(conversationID: "readable-replies", client: ConversationFixtureClient(), initialItems: [item])
        let host = UIHostingController(rootView: ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true)
            .environment(\.dynamicTypeSize, typeSize))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        try await Task.sleep(for: .milliseconds(400))
        let table = try #require(descendants(host.view, of: ChatTimelineTableView.self).first)
        let prose = try #require(descendants(table, of: UITextView.self).first {
            $0.text.contains("A useful reply should be easy to read")
        })
        let expectedProseWidth = ChatBubbleLayoutMetrics.maximumWidth(
            containerWidth: table.bounds.width - (BighelpTokens.space12 * 2),
            maximumWidthFraction: BighelpV3MessagePresentation.incomingMaximumWidthFraction
        ) - (BighelpV3MessagePresentation.horizontalContentPadding * 2)
        #expect(abs(prose.bounds.width - expectedProseWidth) <= 1,
                "Long replies must fill the conversational incoming lane after row and bubble padding.")
        #expect(prose.convert(.zero, to: table).x <= 32,
                "A one-to-one reply must not reserve an empty avatar column beside every paragraph.")
        #expect(prose.isSelectable && !prose.isScrollEnabled)
    }

    @Test func streamingDoesNotRepeatAnUnchangedReferenceDurabilityWrite() {
        var writes = 0
        var savedDraft = ""
        var source = SessionRecord(id: "references", kind: .direct, agentIDs: ["default"], title: "Chat")
        source.referenceState = .init(selections: [], submission: nil)
        let model = ChatModel(conversationID: source.id, client: ConversationFixtureClient(),
            initialDraft: "Draft", sourceSession: source, onSessionChange: { _, _, _, _ in },
            onReferenceStateChange: { draft, _ in writes += 1; savedDraft = draft })
        model.flushPersistence()
        #expect(writes == 1)
        for index in 0..<4 {
            _ = model.acceptActivity(.init(eventID: "event-\(index)", sessionID: source.id,
                turnID: "turn", kind: .tool, lifecycle: .succeeded, title: "Read", summary: "Done", detail: nil,
                occurredAt: index, toolCallID: "call-\(index)", toolName: "read_file"))
            model.flushPersistence()
        }
        #expect(writes == 1, "Tool checkpoints must not force unchanged reference state back through a synchronous full-catalog save.")
        model.draft = "Changed draft"
        model.flushPersistence()
        #expect(writes == 2)
        #expect(savedDraft == "Changed draft")
    }

    @Test func clarificationDraftsAreScopedToTheRequestAndAccount() {
        let model = DashboardModel(source: DashboardFixtureSource())
        func request(_ id: String, session: String = "session") -> DashboardClarificationRequest {
            .init(eventID: "event", requestID: id, sessionID: session, question: "Choose",
                  choices: ["A", "B"], allowsCustomResponse: true, isMultiSelect: true, expiresAt: nil)
        }
        let draft = model.clarificationDraft(itemID: "item", request: request("first"))
        draft.customResponse = "Unsent text"
        draft.selectedChoices = ["B"]
        let restored = model.clarificationDraft(itemID: "item", request: request("first"))
        #expect(restored === draft)
        #expect(restored.selectedChoices == ["B"])
        #expect(model.clarificationDraft(itemID: "item", request: request("second")).customResponse.isEmpty)
        #expect(model.clarificationDraft(itemID: "item", request: request("first", session: "another")).customResponse.isEmpty)
        model.resetForAccountBoundary()
        #expect(model.clarificationDraft(itemID: "item", request: request("first")).customResponse.isEmpty)
    }

    @Test func clarificationDraftSurvivesScrollingOffscreenAndBack() async throws {
        let dashboard = DashboardModel(source: DashboardFixtureSource())
        let timeline = ChatTimelineController()
        let request = DashboardClarificationRequest(eventID: "draft-event", requestID: "draft-request",
            sessionID: "draft-session", question: "Which approach?", choices: [],
            allowsCustomResponse: true, isMultiSelect: false, expiresAt: nil)
        let rows = (0..<50).map { ChatCanvasRow.divider("Row \($0)") }
        let host = UIHostingController(rootView: NativeChatTimeline(conversationID: "draft-session",
            ownerID: ObjectIdentifier(dashboard), rows: rows, controller: timeline, entryCount: rows.count) { row in
                if row.id == rows[0].id {
                    DashboardClarificationAttentionCard(itemID: "draft-item", request: request, model: dashboard)
                } else { Text(row.id).frame(height: 100) }
            })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(tables(host.view).first)
        timeline.beginReview()
        table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(250))
        let input = try #require(textViews(table).first)
        input.becomeFirstResponder()
        input.insertText("Keep this unsent answer")
        try await Task.sleep(for: .milliseconds(150))
        input.resignFirstResponder()
        table.scrollToRow(at: IndexPath(row: 35, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(table.cellForRow(at: IndexPath(row: 0, section: 0)) == nil)
        table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(textViews(table).first?.text == "Keep this unsent answer")
    }

    @Test func incrementalNativeTextPreservesExactCharactersAndFormatting() {
        let cases = [
            ("Stable text", "Stable text plus an emoji 👨‍👩‍👧‍👦"),
            ("Prefix 👋🏽", "Prefix 👋🏻 changed"),
            ("A longer answer to remove", "A shorter answer"),
            ("Unchanged characters", "Unchanged characters"),
            ("Everything removed", ""),
        ]
        for (old, new) in cases {
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.red, .font: UIFont.systemFont(ofSize: 17)]
            let previous = NSAttributedString(string: old, attributes: attributes)
            let storage = NSTextStorage(attributedString: previous)
            let updated = NSMutableAttributedString(string: new, attributes: attributes)
            if updated.length > 3 {
                updated.addAttributes([.font: UIFont.boldSystemFont(ofSize: 19), .link: URL(string: "https://example.com")!],
                                      range: NSRange(location: 1, length: 2))
            }
            ChatNativeTextStorageUpdater.apply(updated, previous: previous, to: storage)
            let expected = NSTextStorage(attributedString: updated)
            expected.fixAttributes(in: NSRange(location: 0, length: expected.length))
            #expect(storage.isEqual(to: expected), "Changed earlier formatting and UTF-16 boundaries must remain exact.")
        }
    }

    @Test func streamingTextEditsOnlyTheChangedSuffix() async throws {
        let originalText = "Ask @sage.\n\n" + String(repeating: "Already rendered paragraph.\n\n", count: 60)
        func view(_ text: String) -> some View {
            MessageBubble(role: .assistant, speakerName: "Agent", text: text,
                          delivery: "Streaming", isPendingSubmission: false, onFork: nil,
                          mentionIdentities: [.init(handle: "sage", name: "Sage Green")])
                .environment(\.bighelpUIV3Enabled, true)
                .frame(width: 350)
        }
        let host = UIHostingController(rootView: view(originalText))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        try await Task.sleep(for: .milliseconds(250))
        let textView = try #require(textViews(host.view).first)
        let mention = try #require(textView.textStorage.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment)
        #expect(mention.displayName == "Sage Green")
        let originalPlainText = ChatMentionRendering.plainText(textView.textStorage)
        let edits = TimelineTextStorageEdits()
        textView.textStorage.delegate = edits
        textView.selectedRange = NSRange(location: 10, length: 8)
        host.rootView = view(originalText + "One appended **formatted** paragraph.")
        try await Task.sleep(for: .milliseconds(250))
        #expect(textViews(host.view).first === textView)
        #expect(textView.text.contains("One appended formatted paragraph."))
        #expect(!edits.characterRanges.isEmpty)
        #expect(edits.characterRanges.allSatisfy { $0.location > 1000 },
                "Streaming must preserve the stable text prefix instead of replacing and laying out the entire answer.")
        #expect(textView.selectedRange == NSRange(location: 10, length: 8))
        #expect(textView.textStorage.attribute(.attachment, at: 4, effectiveRange: nil) as? ChatMentionAttachment === mention)
        #expect(ChatMentionRendering.plainText(textView.textStorage).hasPrefix(originalPlainText))
    }

    @Test func retainedIdealLayoutMatchesFullMeasurementAcrossTextAndFontEdits() {
        let storage = NSTextStorage()
        let layout = ChatNativeMarkdownIdealLayout(textStorage: storage)
        var previous = NSAttributedString(string: "")
        for (source, size) in [
            ("A short reply", 17.0),
            ("A short reply\nA second line with a family 👨‍👩‍👧‍👦", 17.0),
            ("A short reply\nA second line with a family 👨‍👩‍👧‍👦\nمرحبا بالعالم", 17.0),
            ("A completely different answer\nwith a larger font", 24.0),
            ("Short again", 17.0),
            ("", 17.0),
        ] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            let updated = NSMutableAttributedString(string: source, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .regular), .paragraphStyle: paragraph
            ])
            if updated.length > 5 {
                updated.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: size), range: NSRange(location: 0, length: 5))
            }
            ChatNativeTextStorageUpdater.apply(updated, previous: previous, to: storage)
            previous = updated
            let expected = updated.boundingRect(
                with: CGSize(width: ChatNativeMarkdownIdealLayout.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let measured = layout.size()
            #expect(abs(measured.width - ceil(expected.width)) <= 1)
            #expect(abs(measured.height - ceil(expected.height)) <= 1)
            #expect(storage.string == source)
        }
    }

    @Test func recycledRowsStartWithTheirOwnLocalState() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        let rows = (0..<50).map { ChatCanvasRow.divider("Row \($0)") }
        let host = UIHostingController(rootView: NativeChatTimeline(
            conversationID: "reuse-state", ownerID: ObjectIdentifier(owner), rows: rows,
            controller: timeline, entryCount: rows.count) { row in
                TimelineLocalStateProbe(initialID: row.id).frame(height: 100)
            })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(tables(host.view).first)
        timeline.beginReview()
        var assignments: [ObjectIdentifier: String] = [:]
        var reusedForAnotherRow = false
        for target in [0, 20, 40, 10, 30] {
            table.scrollToRow(at: IndexPath(row: target, section: 0), at: .top, animated: false)
            try await Task.sleep(for: .milliseconds(150))
            for cell in table.visibleCells {
                let id = try #require(cell.accessibilityIdentifier)
                let key = ObjectIdentifier(cell)
                if let previous = assignments[key], previous != id { reusedForAnotherRow = true }
                assignments[key] = id
                #expect(buttons(cell).first?.title(for: .normal) == id,
                        "A recycled card must not retain another item's draft/selection/runtime state.")
            }
        }
        #expect(reusedForAnotherRow, "Exercise actual UIKit cell reuse.")
    }

    @Test func livePresentationChangesUpdateAnOtherwiseUnchangedRow() async throws {
        let state = TimelinePresentationProbe()
        let timeline = ChatTimelineController()
        let host = UIHostingController(rootView: NativeChatTimeline(
            conversationID: "presentation", ownerID: ObjectIdentifier(state),
            rows: [.failure("unchanged")], controller: timeline, entryCount: 1) { _ in
                let phase = state.phase
                TimelineActionProbe(title: phase) { state.lastAction = phase }.frame(height: 44)
            })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        try await Task.sleep(for: .milliseconds(300))
        let button = try #require(buttons(host.view).first)
        #expect(button.title(for: .normal) == "Pending")
        state.phase = "Accepted"
        try await Task.sleep(for: .milliseconds(300))
        #expect(button.title(for: .normal) == "Accepted")
        button.sendActions(for: .touchUpInside)
        #expect(state.lastAction == "Accepted")
    }

    @Test func oneExpandedWorkTrailRecyclesIndividualToolRows() async throws {
        let model = ChatModel(conversationID: "many-tools", client: ConversationFixtureClient(), initialItems: [])
        for index in 0..<100 {
            let event = ChatActivityEvent(eventID: "tool-\(index)", sessionID: model.conversationID,
                turnID: "one-turn", kind: .tool, lifecycle: .running, title: "Read \(index)",
                summary: nil, detail: nil, occurredAt: index, toolCallID: "call-\(index)",
                toolName: "read_file", arguments: "{\"path\":\"source-\(index).swift\"}")
            _ = model.acceptActivity(event)
            model.activityDisclosures.setExpanded(true, for: event)
        }
        let host = UIHostingController(rootView: ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        try await Task.sleep(for: .milliseconds(500))
        let table = try #require(tables(host.view).first)
        #expect(model.transcriptEntries.count == 1)
        #expect(table.numberOfRows(inSection: 0) >= 100,
                "One work trail must not render all expanded tools inside one enormous cell.")
        #expect(table.visibleCells.count < 15)
    }

    @Test func completedToolBurstsShareOnePersistenceCheckpointWithoutLosingResults() async throws {
        var checkpointCount = 0
        var saved: [ChatActivityEvent] = []
        let model = ChatModel(conversationID: "tool-checkpoint", client: ConversationFixtureClient(),
                              persistenceCheckpointDelay: .milliseconds(20),
                              onSessionChange: { _, _, ledger, _ in
                                  checkpointCount += 1
                                  saved = ledger.allEvents
                              })
        for index in 0..<100 {
            _ = model.acceptActivity(ChatActivityEvent(eventID: "event-\(index)", sessionID: model.conversationID,
                turnID: "turn", kind: .tool, lifecycle: .succeeded, title: "Read source",
                summary: "Completed", detail: "Exact result \(index)", occurredAt: index,
                toolCallID: "call-\(index)", toolName: "read_file"))
        }
        #expect(checkpointCount == 0, "A completed tool is one event within a turn, not a reason to serialize the entire session again.")
        try await Task.sleep(for: .milliseconds(60))
        #expect(checkpointCount == 1)
        #expect(saved.map(\.detail) == (0..<100).map { "Exact result \($0)" })
        model.flushPersistence()
        #expect(checkpointCount == 1, "An already saved checkpoint must not write again.")
    }

    @Test func catchUpToolBurstsStayCoalescedUntilTheirDurableCheckpoint() {
        var checkpoints = 0
        var saved: [ChatActivityEvent] = []
        let model = ChatModel(conversationID: "catch-up", client: ConversationFixtureClient(),
            onSessionChange: { _, _, ledger, _ in
                checkpoints += 1
                saved = ledger.allEvents
            })
        model.setTranscriptPresentationDeferred(true)
        checkpoints = 0 // Entering suspension may flush the already existing draft.
        for index in 0..<100 {
            _ = model.acceptActivity(.init(eventID: "event-\(index)", sessionID: "catch-up",
                turnID: "turn", kind: .tool, lifecycle: .succeeded, title: "Read",
                summary: "Done", detail: "Result \(index)", occurredAt: index,
                toolCallID: "call-\(index)", toolName: "read_file"))
        }
        #expect(checkpoints == 0, "Catch-up presentation must not force a full disk snapshot per event.")
        model.setTranscriptPresentationDeferred(false)
        #expect(checkpoints == 1)
        #expect(saved.count == 100)
    }

    @Test func replacingTheModelWithMatchingRowIDsRetiresItsVisibleActions() async throws {
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        let timeline = ChatTimelineController()
        var firstActions = 0
        var secondActions = 0
        func view(owner: NSObject, action: @escaping () -> Void) -> some View {
            NativeChatTimeline(conversationID: "same-session", ownerID: ObjectIdentifier(owner),
                               rows: [.failure("same-row")], controller: timeline, entryCount: 1) { _ in
                TimelineActionProbe(action: action).frame(height: 44)
            }
        }
        let host = UIHostingController(rootView: view(owner: firstOwner) { firstActions += 1 })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func buttons(_ view: UIView) -> [UIButton] {
            (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        try await Task.sleep(for: .milliseconds(300))
        let first = try #require(buttons(host.view).first)
        first.sendActions(for: .touchUpInside)
        #expect(firstActions == 1)
        host.rootView = view(owner: secondOwner) { secondActions += 1 }
        try await Task.sleep(for: .milliseconds(300))
        let current = try #require(buttons(host.view).first)
        current.sendActions(for: .touchUpInside)
        #expect(firstActions == 1, "A reused row ID must not retain the previous model's callbacks.")
        #expect(secondActions == 1)
    }

    @Test func nativeRowsRecycleAndPrependingHistoryKeepsTheVisibleMessageInPlace() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        func rows(_ range: Range<Int>) -> [ChatCanvasRow] {
            range.map { .divider("History \($0)") }
        }
        func view(_ rows: [ChatCanvasRow]) -> some View {
            NativeChatTimeline(conversationID: "history", ownerID: ObjectIdentifier(owner),
                               rows: rows, controller: timeline, entryCount: rows.count) { row in
                Text(row.id).frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        let host = UIHostingController(rootView: view(rows(100..<1100)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        try await Task.sleep(for: .milliseconds(400))
        let table = try #require(tables(host.view).first)
        #expect(table.numberOfRows(inSection: 0) == 1000)
        #expect(table.visibleCells.count < 15, "Long history must keep a viewport-sized working set.")
        timeline.beginReview()
        table.scrollToRow(at: IndexPath(row: 20, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let original = try #require(table.cellForRow(at: IndexPath(row: 20, section: 0)))
        let y = original.convert(.zero, to: host.view).y
        host.rootView = view(rows(0..<1100))
        try await Task.sleep(for: .milliseconds(300))
        let retained = try #require(table.cellForRow(at: IndexPath(row: 120, section: 0)))
        #expect(retained.accessibilityIdentifier == "divider:History 120")
        #expect(abs(retained.convert(.zero, to: host.view).y - y) <= 1,
                "Loading previous history must retain the reader's visible row and offset.")
        timeline.scrollToLatest(animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(table.indexPathsForVisibleRows?.last?.row == 1099)
        #expect(table.visibleCells.count < 15)
    }

    @Test func typingDuringLongHistoryStreamingKeepsTheNativeComposerAndCaret() async throws {
        func item(_ id: String, text: String, delivery: String = "Delivered") -> TimelineItem {
            TimelineItem(id: id, role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message(text), metadata: .init(delivery: delivery))
        }
        let model = ChatModel(conversationID: "typing-during-stream",
            client: ConversationFixtureClient(),
            initialItems: (0..<400).map { item("history-\($0)", text: "Settled message \($0)") })
        let controller = UIHostingController(rootView: ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        try await Task.sleep(for: .milliseconds(600))
        let composer = try #require(textViews(controller.view).first { $0.accessibilityIdentifier == "chat.composer.text" })
        #expect(composer.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(300))
        let undoManager = try #require(composer.undoManager)
        var expected = ""
        for (index, character) in "Keep my draft 👋 while the answer streams.".enumerated() {
            let insertion = String(character)
            composer.insertText(insertion)
            expected += insertion
            model.acceptExternal([item("live", text: String(repeating: "New streamed text.\n", count: index + 1), delivery: "Streaming")])
            try await Task.sleep(for: .milliseconds(16))
            #expect(model.draft == expected)
            #expect(composer.text == expected)
            #expect(composer.selectedRange == NSRange(location: expected.utf16.count, length: 0))
            #expect(composer.isFirstResponder)
        }
        #expect(textViews(controller.view).first { $0.accessibilityIdentifier == "chat.composer.text" } === composer)
        #expect(composer.undoManager === undoManager)
        #expect(model.transcriptEntries.count == 401)
    }

    @Test func appendingTextPreservesThePreviousNativeMessageAndItsSelection() async throws {
        func item(_ id: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message("Readable message \(id)"), metadata: .init(delivery: "Delivered"))
        }
        let model = ChatModel(conversationID: "stable-message-container",
            client: ConversationFixtureClient(), initialItems: [item("first")])
        let controller = UIHostingController(rootView: ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        let original = try #require(textViews(controller.view).first { $0.text.contains("Readable message first") })
        original.selectedRange = NSRange(location: 0, length: 8)

        model.acceptExternal([item("second")])
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let retained = try #require(textViews(controller.view).first { $0.text.contains("Readable message first") })
        #expect(retained === original, "Appending a message must not recreate the previous row and discard its measured layout.")
        #expect(retained.selectedRange == NSRange(location: 0, length: 8))
    }

    @Test func growingVisibleAnswerRetainsNativeSelectionAndUpdatesItsHeight() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        func content(_ text: String) -> some View {
            let item = TimelineItem(id: "answer", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message(text), metadata: .init(delivery: "Streaming"))
            return NativeChatTimeline(conversationID: "growing-answer", ownerID: ObjectIdentifier(owner),
                rows: [.transcript(.entry(.message(item))), .bottom], controller: timeline, entryCount: 1) { row in
                if case .transcript(.entry(.message(let message))) = row {
                    TimelineItemView(item: message, onApprovalTap: { _ in })
                } else { Color.clear.frame(height: 1) }
            }
            .environment(\.bighelpUIV3Enabled, true)
        }
        var source = "The first **formatted** line.\n"
        let host = UIHostingController(rootView: content(source))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(descendants(host.view, of: ChatTimelineTableView.self).first)
        let textView = try #require(descendants(table, of: UITextView.self).first)
        let originalHeight = textView.bounds.height
        textView.selectedRange = NSRange(location: 4, length: 5)
        for index in 0..<12 {
            source += "Appended paragraph \(index) with **formatted** content and a stable selection.\n"
            host.rootView = content(source)
            try await Task.sleep(for: .milliseconds(80))
            #expect(descendants(table, of: UITextView.self).first === textView)
            #expect(textView.text.contains("Appended paragraph \(index)"))
            #expect(textView.selectedRange == NSRange(location: 4, length: 5))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(textView.bounds.height > originalHeight)
        #expect(abs(table.distanceFromBottom) <= 1, "Growing content must keep the native table following its tail.")
    }

    @Test func nativeContentInsetsPreserveReviewAndTailAnchors() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        let rows = (0..<80).map { ChatCanvasRow.divider("Inset row \($0)") }
        func view(_ insets: UIEdgeInsets) -> some View {
            NativeChatTimeline(
                conversationID: "inset-anchors",
                ownerID: ObjectIdentifier(owner),
                rows: rows,
                controller: timeline,
                entryCount: rows.count,
                contentInsets: insets
            ) { row in
                Text(row.id)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }

        let host = UIHostingController(rootView: view(.zero))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(400))

        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let table = try #require(tables(host.view).first as? ChatTimelineTableView)
        timeline.beginReview()
        table.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(200))
        let reviewedCell = try #require(table.cellForRow(at: IndexPath(row: 30, section: 0)))
        let reviewedY = reviewedCell.convert(.zero, to: host.view).y

        host.rootView = view(UIEdgeInsets(top: 68, left: 0, bottom: 132, right: 0))
        try await Task.sleep(for: .milliseconds(300))
        let retainedCell = try #require(table.cellForRow(at: IndexPath(row: 30, section: 0)))
        #expect(abs(retainedCell.convert(.zero, to: host.view).y - reviewedY) <= 1,
                "Changing the chrome inset must preserve the reader's visible row.")
        #expect(!table.followsTail)
        #expect(table.contentInset.top == 68)
        #expect(table.contentInset.bottom == 132)
        #expect(table.verticalScrollIndicatorInsets.top == 68)
        #expect(table.verticalScrollIndicatorInsets.bottom == 132)

        timeline.scrollToLatest(animated: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(table.followsTail)
        #expect(abs(table.distanceFromBottom) <= ChatTimelineBottomPinning.correctionThreshold,
                "Returning to latest must pin against the new adjusted bottom inset.")
    }

    @Test func nativeContentInsetsDoNotOverrideAnInFlightReviewGesture() async throws {
        let owner = NSObject()
        let timeline = ChatTimelineController()
        let rows = (0..<80).map { ChatCanvasRow.divider("Gesture row \($0)") }
        let host = UIHostingController(rootView: NativeChatTimeline(
            conversationID: "inset-gesture", ownerID: ObjectIdentifier(owner), rows: rows,
            controller: timeline, entryCount: rows.count
        ) { row in
            Text(row.id).frame(maxWidth: .infinity, minHeight: 100)
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(400))

        func tables(_ view: UIView) -> [UITableView] {
            (view as? UITableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let table = try #require(tables(host.view).first as? ChatTimelineTableView)
        timeline.beginReview()
        table.scrollToRow(at: IndexPath(row: 32, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(200))

        var programmaticWrites = 0
        table.onProgrammaticContentOffsetWrite = { programmaticWrites += 1 }
        table.interactionStateOverride = true
        // Model the offset after the user's drag; this value must remain the
        // user's resulting position when the interaction finishes.
        table.contentOffset = CGPoint(x: table.contentOffset.x, y: table.contentOffset.y + 48)
        table.applyCustomContentInsets(UIEdgeInsets(top: 68, left: 0, bottom: 132, right: 0))
        let resultingOffset = table.contentOffset
        #expect(programmaticWrites == 0,
                "Chrome inset updates must not write a competing content offset during a gesture.")

        table.interactionStateOverride = false
        table.setNeedsLayout()
        table.layoutIfNeeded()
        #expect(abs(table.contentOffset.y - resultingOffset.y) <= 1,
                "Ending a gesture must not restore a stale pre-inset offset.")
    }

}

private struct TimelineActionProbe: UIViewRepresentable {
    var title = "Use current model"
    let action: () -> Void
    func makeUIView(context: Context) -> UIButton { UIButton(type: .system) }
    func updateUIView(_ button: UIButton, context: Context) {
        button.setTitle(title, for: .normal)
        button.removeAction(identifiedBy: .init("current-model"), for: .touchUpInside)
        button.addAction(UIAction(identifier: .init("current-model")) { _ in action() }, for: .touchUpInside)
    }
}

private struct TimelineLocalStateProbe: View {
    @State private var initialID: String
    init(initialID: String) { _initialID = State(initialValue: initialID) }
    var body: some View { TimelineActionProbe(title: initialID, action: {}) }
}

@MainActor private final class TimelineTextStorageEdits: NSObject, @preconcurrency NSTextStorageDelegate {
    var characterRanges: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { characterRanges.append(editedRange) }
    }
}

@MainActor @Observable private final class TimelinePresentationProbe {
    var phase = "Pending"
    var lastAction = ""
}
