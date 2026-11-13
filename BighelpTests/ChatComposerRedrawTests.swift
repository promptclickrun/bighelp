import Observation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// The message box draws again only for what it shows, never for each streamed piece of an
/// answer that redraws the chat around it (#738).
@Suite(.serialized)
@MainActor
struct ChatComposerRedrawTests {
    @Test func aStreamingAnswerDoesNotRedrawTheMessageBox() async throws {
        let model = ChatModel(conversationID: "composer-redraw-stream", client: ConversationFixtureClient(),
                              initialItems: (0..<40).map { Self.answer("history-\($0)", "Settled message \($0)") })
        let mounted = try MountedComposerChat(model: model)
        defer { mounted.close() }
        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        #expect(editor.becomeFirstResponder())
        // The open and the focus draw the box a few times; count only what streaming does.
        try await Task.sleep(for: .milliseconds(400))
        let coordinator = try #require(editor.delegate as? ReferenceComposerTextView.Coordinator)
        let before = coordinator.surfaceUpdates
        var revisions: Set<UInt64> = []

        for index in 1...20 {
            model.acceptExternal([Self.answer("live", String(repeating: "More of the answer. ", count: index),
                                              delivery: "Streaming")])
            // `ChatView` draws from this revision, so each piece redraws the chat screen.
            revisions.insert(model.transcriptRevision)
            try await Task.sleep(for: .milliseconds(30))
            mounted.window.layoutIfNeeded()
        }

        #expect(model.transcriptEntries.count == 41)
        #expect(revisions.count == 20, "Every piece must change the transcript, or this checks nothing")
        let redraws = coordinator.surfaceUpdates - before
        #expect(redraws <= 3, "Each streamed piece redrew the message box: \(redraws) times")
        #expect(editor.isFirstResponder)
        #expect(mounted.editor === editor)
    }

    /// The chat screen still hands the box its focus: `ChatView` asks for it, and the box,
    /// which compares its own copy of the focus, takes the keyboard.
    @Test func aFocusRequestFromTheChatScreenStillReachesTheMessageBox() async throws {
        let model = ChatModel(conversationID: "composer-redraw-focus", client: ConversationFixtureClient(),
                              initialItems: [])
        let mounted = try MountedComposerChat(model: model)
        defer { mounted.close() }
        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        #expect(!editor.isFirstResponder)

        mounted.state.focusRequest = 1
        await mounted.settle(tries: 60) { editor.isFirstResponder }
        #expect(editor.isFirstResponder)
    }

    @Test func theMessageBoxComparesEqualWhenOnlyTheChatScreensClosuresChange() {
        let model = ChatModel(conversationID: "composer-equal", client: ConversationFixtureClient(), initialItems: [])
        let other = ChatModel(conversationID: "composer-equal-other", client: ConversationFixtureClient(),
                              initialItems: [])
        let actions = ChatComposerActions()
        let hub = ReferenceHubStore(owner: nil, providers: [])
        func box(_ model: ChatModel, focused: Bool = false, attachments: Bool = true) -> ChatComposer {
            ChatComposer(model: model, agentName: "Juno", sessionCatalog: nil, actions: actions,
                         offersAttachments: attachments, draftFocus: .constant(focused), isDraftFocused: focused,
                         companionPet: nil, companionReaction: .idle, companionSizeScale: 1,
                         companionIsAdventurous: false, referenceHub: hub, referenceSkills: nil)
        }
        var voiceTaps: [String] = []
        actions.voice = { voiceTaps.append("first") }
        let drawn = box(model)
        // A redraw of the chat screen hands over new closures and nothing else.
        actions.voice = { voiceTaps.append("second") }
        let keepsTheBox = drawn == box(model)
        #expect(keepsTheBox)
        // The box that stays calls the newest one.
        drawn.actions.voice()
        #expect(voiceTaps == ["second"])
        // A new chat's Send hook comes and goes the same way.
        actions.sendOverride = { true }
        let keepsTheBoxWithAHook = drawn == box(model)
        #expect(keepsTheBoxWithAHook)
        #expect(drawn.actions.sendOverride?() == true)

        let focusRedraws = drawn != box(model, focused: true)
        let attachmentsRedraw = drawn != box(model, attachments: false)
        let anotherChatRedraws = drawn != box(other)
        #expect(focusRedraws)
        #expect(attachmentsRedraw)
        #expect(anotherChatRedraws)
    }

    /// Send, the placeholder and the mention list read the draft's shape, not the draft: a key
    /// that changes nothing they show redraws none of them.
    @Test func aKeyThatChangesNothingSendShowsRedrawsNeitherSendNorThePlaceholder() {
        let model = ChatModel(conversationID: "composer-redraw-keys", client: ConversationFixtureClient(),
                              initialItems: [])
        model.draft = "H"
        let redraws = ComposerRedrawCounter()
        withObservationTracking {
            _ = model.draftShape.isEmpty
            _ = model.canSend
            _ = model.sendUnavailableReason
            _ = model.mentionSuggestions
        } onChange: {
            redraws.increment()
        }
        model.draft = "Hi"
        model.draft = "Hi there, could you check the invoices"
        #expect(redraws.value == 0)
        #expect(model.canSend)

        model.draft = ""
        #expect(redraws.value == 1)
        #expect(!model.canSend)
        #expect(model.draftShape == ChatDraftShape())
    }

    @Test func theDraftShapeAgreesWithTheChecksItReplaces() {
        let samples = ["", " ", "\n\t ", "\u{00A0}", "\u{2028}\u{3000}", "\u{200B}", "a", "  a  ", "e\u{301}", "👋",
                       " /plan it", "/", "\n/note", "a/b", "@", "Ask @ju", "Ask @", "mail@example.com"]
        for sample in samples {
            let shape = ChatDraftShape(sample)
            #expect(shape.isEmpty == sample.isEmpty, "\(sample.debugDescription)")
            #expect(shape.hasText == !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(sample.debugDescription)")
            #expect(shape.isCommand == (sample.first(where: { !$0.isWhitespace }) == "/"), "\(sample.debugDescription)")
            #expect(shape.mayMention == sample.unicodeScalars.contains("@"), "\(sample.debugDescription)")
            #expect(ChatComposerPrimaryAction.resolve(draft: sample)
                    == ChatComposerPrimaryAction.resolve(hasText: shape.hasText), "\(sample.debugDescription)")
        }
        // Restored with the chat, not typed.
        let restored = ChatModel(conversationID: "composer-redraw-restored", client: ConversationFixtureClient(),
                                 initialItems: [], initialDraft: "Ask @ju")
        #expect(restored.draftShape == ChatDraftShape("Ask @ju"))
    }

    /// New chat's Send asks its hook first, once a send. A message the hook takes goes nowhere
    /// else and stays in the box for whoever took it; one it leaves is sent here as usual, and
    /// from then on the chat is an ordinary one that asks nobody.
    @Test func aNewChatsSendAsksItsHookOnceAndATakenMessageIsNotSentHere() async throws {
        let client = RecordingFixtureClient()
        let model = ChatModel(conversationID: "composer-send-hook", client: client, initialItems: [])
        let hook = SendHook()
        let mounted = try MountedComposerChat(model: model, newChat: ChatNewChatSlot(
            toRow: AnyView(Color.clear.frame(height: 44)),
            sendOverride: {
                hook.asked += 1
                return hook.takes
            }))
        defer { mounted.close() }
        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        model.draft = "Fix the widget tap"
        #expect(model.canSend)

        // Command-Return sends whatever Settings › Chat › Return sends says.
        #expect(editor.onReturnKey?(.command) == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(hook.asked == 1)
        #expect(client.sent.isEmpty, "A taken message must not also go to this chat")
        #expect(model.draft == "Fix the widget tap", "Whoever takes the message empties the box")
        #expect(model.transcriptEntries.isEmpty)

        hook.takes = false
        #expect(editor.onReturnKey?(.command) == true)
        await mounted.settle(tries: 100) { client.sent.count == 1 && !model.isSending }
        #expect(hook.asked == 2)
        #expect(client.sent.count == 1)
        #expect(model.draft.isEmpty)
        #expect(!model.transcriptEntries.isEmpty)

        // The chat has a message now: it draws again without the hook.
        try await Task.sleep(for: .milliseconds(200))
        mounted.window.layoutIfNeeded()
        model.draft = "And the alert tap"
        await mounted.settle(tries: 100) { model.canSend }
        #expect(model.canSend)
        #expect(editor.onReturnKey?(.command) == true)
        await mounted.settle(tries: 100) { client.sent.count == 2 }
        #expect(client.sent.count == 2)
        #expect(hook.asked == 2, "Only a chat with nothing sent asks the hook")
    }

    /// New chat's choices are a sibling under the box. When they change and grow, the chat screen
    /// makes room and moves the box up, without drawing the box again.
    @Test func aChangeInTheChoicesRowDoesNotRedrawTheMessageBox() async throws {
        let model = ChatModel(conversationID: "composer-redraw-choices", client: ConversationFixtureClient(),
                              initialItems: [])
        let row = ChoicesRowState()
        let mounted = try MountedComposerChat(model: model, newChat: ChatNewChatSlot(
            toRow: AnyView(Color.clear.frame(height: 44)),
            choicesRow: AnyView(ChoicesRowStandIn(state: row))))
        defer { mounted.close() }
        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        // The open draws the box a few times; count only what the row does.
        try await Task.sleep(for: .milliseconds(400))
        mounted.window.layoutIfNeeded()
        let coordinator = try #require(editor.delegate as? ReferenceComposerTextView.Coordinator)
        let before = coordinator.surfaceUpdates
        let restingBottom = mounted.bottom(of: editor)

        for step in 1...8 {
            row.height = 40 + CGFloat(step) * 10
            try await Task.sleep(for: .milliseconds(30))
            mounted.window.layoutIfNeeded()
        }
        await mounted.settle { mounted.bottom(of: editor) <= restingBottom - 70 }

        #expect(mounted.bottom(of: editor) <= restingBottom - 70,
                "The row grew by 80 points under the box, or this checks nothing")
        let redraws = coordinator.surfaceUpdates - before
        #expect(redraws <= 2, "A change in the choices row redrew the message box: \(redraws) times")
        #expect(mounted.editor === editor)
    }

    private static func answer(_ id: String, _ text: String, delivery: String = "Delivered") -> TimelineItem {
        TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                     content: .message(text), metadata: .init(delivery: delivery))
    }
}

private final class ComposerRedrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}

/// What a test's Send hook was asked and answers.
@MainActor
private final class SendHook {
    var asked = 0
    var takes = true
}

/// The demo client, keeping what the chat sent through it.
private final class RecordingFixtureClient: ConversationFixtureClient {
    private(set) var sent: [String] = []

    override func send(message: String, conversationID: String) async throws -> ConversationResponse {
        sent.append(message)
        return try await super.send(message: message, conversationID: conversationID)
    }
}

@MainActor
@Observable
private final class ChoicesRowState {
    var height: CGFloat = 40
}

/// Stands in for New chat's choices row: its own state changes it, as a chip does the real one.
private struct ChoicesRowStandIn: View {
    let state: ChoicesRowState

    var body: some View {
        Color.clear.frame(height: state.height)
    }
}

@MainActor
@Observable
private final class ComposerChatState {
    var focusRequest = 0
}

@MainActor
private struct ComposerChatHarness: View {
    let model: ChatModel
    let state: ComposerChatState
    /// New chat's parts, with the pushed header they come with.
    var newChat: ChatNewChatSlot? = nil

    var body: some View {
        ChatView(model: model, composerFocusRequest: state.focusRequest, newChat: newChat)
            .environment(\.bighelpUIV3Enabled, true)
            .environment(\.agentHomeChrome, newChat == nil ? AgentHomeChrome() : .pushedChat(onProfile: { _ in }))
    }
}

@MainActor
private final class MountedComposerChat {
    let window: UIWindow
    let state = ComposerChatState()

    init(model: ChatModel, newChat: ChatNewChatSlot? = nil) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(
            rootView: ComposerChatHarness(model: model, state: state, newChat: newChat))
        window.makeKeyAndVisible()
    }

    /// Where the view ends, down the window.
    func bottom(of view: UIView) -> CGFloat {
        view.convert(view.bounds, to: window).maxY
    }

    var editor: ClipboardPasteTextView? {
        func find(in view: UIView) -> ClipboardPasteTextView? {
            if let editor = view as? ClipboardPasteTextView, editor.accessibilityIdentifier == "chat.composer.text" {
                return editor
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: window)
    }

    func settle(tries: Int = 30, until condition: () -> Bool) async {
        for _ in 0..<tries {
            window.layoutIfNeeded()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}
