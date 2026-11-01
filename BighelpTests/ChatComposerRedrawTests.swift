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
                         companionAppearance: nil, companionReaction: .idle, companionSizeScale: 1,
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

        let focusRedraws = drawn != box(model, focused: true)
        let attachmentsRedraw = drawn != box(model, attachments: false)
        let anotherChatRedraws = drawn != box(other)
        #expect(focusRedraws)
        #expect(attachmentsRedraw)
        #expect(anotherChatRedraws)
    }

    private static func answer(_ id: String, _ text: String, delivery: String = "Delivered") -> TimelineItem {
        TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                     content: .message(text), metadata: .init(delivery: delivery))
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

    var body: some View {
        ChatView(model: model, composerFocusRequest: state.focusRequest)
            .environment(\.bighelpUIV3Enabled, true)
    }
}

@MainActor
private final class MountedComposerChat {
    let window: UIWindow
    let state = ComposerChatState()

    init(model: ChatModel) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: ComposerChatHarness(model: model, state: state))
        window.makeKeyAndVisible()
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
