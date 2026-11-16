import Observation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@Suite(.serialized)
@MainActor
struct CompactChatComposerTests {
    @Test func longUnbrokenDraftRemainsInsideComposerViewport() async throws {
        let model = ChatModel(conversationID: "bounded-native-editor", client: ConversationFixtureClient(), initialItems: [])
        model.draft = String(repeating: "unbroken", count: 2_000)
        let state = CompactEditorLayoutState()
        let mounted = try MountedCompactChat(model: model, state: state)
        defer { mounted.close() }

        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        await mounted.settle { editor.bounds.width > 0 }

        #expect(editor.frame.minX >= -0.5)
        #expect(editor.frame.maxX <= mounted.window.bounds.maxX + 0.5)
        // Send sits beside the text: the editor ends at least one control short of the edge.
        #expect(editor.convert(editor.bounds, to: nil).maxX <= mounted.window.bounds.maxX - BighelpTokens.hitTarget)
        #expect(editor.textContainer.widthTracksTextView)
        #expect(editor.contentSize.width <= editor.bounds.width + 1)
    }

    @Test func compactLayoutRetainsNativeEditorSelectionCaretAndUndo() async throws {
        let source = (0..<8).map { "Line \($0): preserve this draft and its native selection." }.joined(separator: "\n")
        let model = ChatModel(conversationID: "compact-native-editor", client: ConversationFixtureClient(), initialItems: [])
        model.draft = source
        let state = CompactEditorLayoutState()
        let mounted = try MountedCompactChat(model: model, state: state)
        defer { mounted.close() }
        await mounted.settle { mounted.editor != nil }
        let editor = try #require(mounted.editor)
        #expect(editor.becomeFirstResponder())
        await mounted.settle { editor.isFirstResponder }
        let manager = try #require(editor.undoManager)
        let replacement = (source as NSString).range(of: "Line 5:")
        editor.selectedRange = replacement
        manager.beginUndoGrouping()
        editor.insertText("Fifth:")
        editor.delegate?.textViewDidChange?(editor)
        manager.endUndoGrouping()
        let edited = try #require(editor.text)
        #expect(manager.canUndo)
        let selection = NSRange(location: replacement.location + 7, length: 8)
        editor.selectedRange = selection
        editor.delegate?.textViewDidChangeSelection?(editor)
        editor.scrollRangeToVisible(selection)

        mounted.setCompact(true)
        await mounted.settle { editor.bounds.height <= 44.5 && caretIsVisible(in: editor) }
        #expect(mounted.editor === editor)
        #expect(editor.undoManager === manager)
        #expect(editor.isFirstResponder)
        #expect(editor.text == edited)
        #expect(model.draft == edited)
        #expect(editor.selectedRange == selection)
        #expect(editor.bounds.height <= 44.5)
        #expect(editor.bounds.height >= (try #require(editor.font)).lineHeight)
        let caret = editor.caretRect(for: try #require(editor.selectedTextRange?.end))
        #expect(caret.minY >= editor.bounds.minY - 1)
        #expect(caret.maxY <= editor.bounds.maxY + 1)

        manager.undo()
        await mounted.settle { model.draft == source }
        #expect(editor.text == source)
        #expect(model.draft == source)
        #expect(manager.canRedo)
        manager.redo()
        await mounted.settle { model.draft == edited }
        #expect(editor.text == edited)
        let restoredSelection = editor.selectedRange

        mounted.setCompact(false)
        await mounted.settle { editor.bounds.height > 44.5 && caretIsVisible(in: editor) }
        #expect(mounted.editor === editor)
        #expect(editor.undoManager === manager)
        #expect(editor.isFirstResponder)
        #expect(editor.text == edited)
        #expect(editor.selectedRange == restoredSelection)
        let restoredCaret = editor.caretRect(for: try #require(editor.selectedTextRange?.end))
        #expect(restoredCaret.minY >= editor.bounds.minY - 1)
        #expect(restoredCaret.maxY <= editor.bounds.maxY + 1)
    }

    private func caretIsVisible(in editor: UITextView) -> Bool {
        guard let end = editor.selectedTextRange?.end else { return false }
        let caret = editor.caretRect(for: end)
        return caret.minY >= editor.bounds.minY - 1 && caret.maxY <= editor.bounds.maxY + 1
    }
}

@MainActor
@Observable
private final class CompactEditorLayoutState {
    var compact = false
}

@MainActor
private struct CompactEditorLayoutHarness: View {
    let model: ChatModel
    @Bindable var state: CompactEditorLayoutState

    var body: some View {
        ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.verticalSizeClass, state.compact ? .compact : .regular)
            .ignoresSafeArea(.keyboard)
    }
}

@MainActor
private final class MountedCompactChat {
    let window: UIWindow
    let state: CompactEditorLayoutState

    init(model: ChatModel, state: CompactEditorLayoutState) throws {
        self.state = state
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: CompactEditorLayoutHarness(model: model, state: state))
        window.makeKeyAndVisible()
    }

    var editor: ClipboardPasteTextView? {
        func find(in view: UIView) -> ClipboardPasteTextView? {
            if let editor = view as? ClipboardPasteTextView, editor.isEditable { return editor }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: window)
    }

    func setCompact(_ compact: Bool) {
        state.compact = compact
        window.frame = compact
            ? CGRect(x: 0, y: 0, width: 750, height: 198)
            : CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController?.view.frame = window.bounds
    }

    func settle(until condition: () -> Bool) async {
        for _ in 0..<30 {
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
