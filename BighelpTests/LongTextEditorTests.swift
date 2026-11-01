import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct LongTextEditorTests {
    private static let longText = (1...60)
        .map { "\($0). Help with financial planning: budgets, bills, savings goals and the reasoning behind each choice." }
        .joined(separator: "\n\n")

    /// Made through `makeUIView` in a window, as every screen makes it. The text view's own stored
    /// properties must be set up: made by UIKit's TextKit factory, the first color crashed.
    @Test func theEditorMakesAWorkingTextView() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.textLayoutManager != nil, "TextKit 2")
        view.applyColors(ink: .red, hint: .gray, caret: .blue)
        view.applyColors(ink: .red, hint: .gray, caret: .blue)
        #expect(view.textColor != nil)
        view.placeholder = "What should it help with?"
        view.text = ""
        view.textDidChange()
        view.layoutIfNeeded()

        let textKit1 = LongTextView(usesTextKit2: false)
        #expect(textKit1.textLayoutManager == nil, "TextKit 1, for comparing")
        textKit1.applyColors(ink: .red, hint: .gray, caret: nil)
        textKit1.text = Self.longText
        #expect(textKit1.boxHeight(forWidth: 320, minimum: 140, maximum: 260) == 260)
    }

    /// The form turns its keyboard dismissal off while the box is edited, from this.
    @Test func editingStartAndEndReachTheForm() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.becomeFirstResponder())
        #expect(host.editing == [true])
        #expect(view.resignFirstResponder())
        #expect(host.editing == [true, false])
    }

    @Test func typingInTheViewReachesTheBindingAndChangesNothingElse() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 10, length: 0)
        view.insertText("Always ")
        #expect(host.text.hasPrefix("1. Help wiAlways th"))
        host.update()
        // Its own keystroke coming back leaves the caret where the person typed.
        #expect(view.selectedRange == NSRange(location: 17, length: 0))
        #expect(view.text == host.text)
    }

    /// "The line that you type stays above the keyboard": after every keystroke, including a new
    /// empty last line, the caret is inside what the box shows above the keyboard.
    @Test func theCaretStaysInViewWhileTyping() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.becomeFirstResponder())
        for atEnd in [false, true] {
            let length = (view.text as NSString).length
            let location = atEnd ? length : length / 2
            view.selectedRange = NSRange(location: location, length: 0)
            for character in "\nKeep every receipt.\n\nAsk first." {
                view.insertText(String(character))
                let end = try #require(view.selectedTextRange?.end)
                let caret = view.caretRect(for: end)
                var visible = view.bounds
                visible.size.height -= view.contentInset.bottom
                #expect(visible.insetBy(dx: -1, dy: -1).contains(CGPoint(x: caret.midX, y: caret.maxY - 1)),
                        "Caret out of sight after typing \(character.debugDescription) at \(location)")
            }
        }
    }

    @Test func textFromElsewhereWhileTypingKeepsTheCaret() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 200, length: 0)
        host.text = "Start here.\n" + Self.longText
        host.update()
        #expect(view.text == host.text)
        #expect(view.selectedRange == NSRange(location: 212, length: 0), "The caret moves with its text")
        host.text += "\nEnd here."
        host.update()
        #expect(view.text == host.text)
        #expect(view.selectedRange == NSRange(location: 212, length: 0), "Text added after it leaves it alone")
        host.text = "Short."
        host.update()
        #expect(view.text == "Short.")
    }

    @Test func textFromElsewhereKeepsTheScrollPosition() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        view.contentOffset.y = 300
        host.text = Self.longText + "\nAlways show the total first."
        host.update()
        #expect(view.text == host.text)
        #expect(view.contentOffset.y == 300, "The full-screen editor's changes don't move the box")
    }

    @Test func aBoxNeverMeasuresLongText() throws {
        let host = try Host(text: Self.longText)
        defer { host.close() }
        let view = try #require(host.textView)
        #expect(view.boxHeight(forWidth: 320, minimum: 140, maximum: 260) == 260)
        view.text = "One line."
        #expect(view.boxHeight(forWidth: 320, minimum: 140, maximum: 260) == 140)
        view.text = (1...9).map { "Line \($0)" }.joined(separator: "\n")
        let nineLines = view.boxHeight(forWidth: 320, minimum: 140, maximum: 260)
        #expect(nineLines > 140 && nineLines < 260, "Short text is measured: \(nineLines)")
    }

    @Test func smallestEdit() throws {
        #expect(LongTextEdit.difference(from: "same", to: "same") == nil)
        #expect(LongTextEdit.difference(from: "Hello world", to: "Hello brave world")
            == LongTextEdit(range: NSRange(location: 6, length: 0), replacement: "brave "))
        #expect(LongTextEdit.difference(from: "Hello brave world", to: "Hello world")
            == LongTextEdit(range: NSRange(location: 6, length: 6), replacement: ""))
        #expect(LongTextEdit.difference(from: "aaa", to: "aaaa")
            == LongTextEdit(range: NSRange(location: 3, length: 0), replacement: "a"))
        // A face swapped for another shares its first UTF-16 unit; the pair stays whole.
        let edit = try #require(LongTextEdit.difference(from: "Hi 😀!", to: "Hi 😃!"))
        #expect(edit.range == NSRange(location: 3, length: 2))
        #expect(edit.replacement == "😃")
    }

    @Test func caretAfterAnEdit() {
        let edit = LongTextEdit(range: NSRange(location: 6, length: 0), replacement: "brave ")
        #expect(LongTextEdit.selection(NSRange(location: 2, length: 0), after: edit) == NSRange(location: 2, length: 0))
        #expect(LongTextEdit.selection(NSRange(location: 8, length: 3), after: edit) == NSRange(location: 14, length: 3))
        let removal = LongTextEdit(range: NSRange(location: 6, length: 6), replacement: "")
        #expect(LongTextEdit.selection(NSRange(location: 9, length: 0), after: removal) == NSRange(location: 6, length: 0))
    }

    @Test func keyboardOverlapAndReveal() {
        let view = CGRect(x: 0, y: 500, width: 390, height: 260)
        #expect(LongTextKeyboard.overlap(view: view, keyboard: nil) == 0)
        #expect(LongTextKeyboard.overlap(view: view, keyboard: CGRect(x: 0, y: 900, width: 390, height: 336)) == 0)
        #expect(LongTextKeyboard.overlap(view: view, keyboard: CGRect(x: 0, y: 600, width: 390, height: 336)) == 160)
        #expect(LongTextKeyboard.overlap(view: view, keyboard: CGRect(x: 0, y: 300, width: 390, height: 600)) == 260)
        // The form moves the box up by what the keyboard covers, plus a margin…
        #expect(LongTextKeyboard.revealDistance(box: view, visibleTop: 100, visibleBottom: 600) == 168)
        // …but never so far that its top leaves the screen.
        #expect(LongTextKeyboard.revealDistance(box: view, visibleTop: 400, visibleBottom: 600) == 92)
        #expect(LongTextKeyboard.revealDistance(box: view, visibleTop: 100, visibleBottom: 800) == 0)
    }

    @Test func boxHeightPolicy() {
        #expect(LongTextBox.height(measured: nil, minimum: 140, maximum: 260) == 260)
        #expect(LongTextBox.height(measured: 40, minimum: 140, maximum: 260) == 140)
        #expect(LongTextBox.height(measured: 200.2, minimum: 140, maximum: 260) == 201)
        #expect(LongTextBox.height(measured: 900, minimum: 140, maximum: 260) == 260)
    }

    /// `LongTextEditor` in a window, bound to `text`.
    @MainActor
    private final class Host {
        var text: String
        var editing: [Bool] = []
        private let window: UIWindow
        private let controller: UIHostingController<LongTextEditor>
        private let previousKeyWindow: UIWindow?

        init(text: String) throws {
            self.text = text
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .alert + 1
            controller = UIHostingController(rootView: LongTextEditor(
                text: .constant(text), accessibilityLabel: "Instructions", identifier: "test", layout: .formBox))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            update()
        }

        var textView: LongTextView? {
            func search(_ view: UIView) -> LongTextView? {
                if let match = view as? LongTextView { return match }
                return view.subviews.lazy.compactMap(search).first
            }
            return search(window)
        }

        func update() {
            controller.rootView = LongTextEditor(
                text: Binding(get: { self.text }, set: { self.text = $0 }),
                accessibilityLabel: "Instructions", identifier: "test", layout: .formBox,
                onEditingChanged: { self.editing.append($0) })
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        func close() {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }
}
