import SwiftUI
import UIKit

/// The batch chat's text field: plain text, with each `#` mention drawn in its session's
/// color in place. Mentions are ordinary text, so deleting a letter simply un-colors one.
struct CodeMentionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Exact substrings to color, longest first.
    let mentions: [(text: String, color: UIColor)]
    var textColor: UIColor = .label
    var maximumLines = 6
    var accessibilityIdentifier = "code.batch.field"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.font = UIFont.bighelp(.body)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .default
        view.accessibilityIdentifier = accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        style(view)
        if isFocused, !view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let lineHeight = view.font?.lineHeight ?? 22
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximum = lineHeight * CGFloat(maximumLines)
        view.isScrollEnabled = fitting > maximum
        return CGSize(width: width, height: min(max(fitting, lineHeight), maximum))
    }

    /// Colors the mentions without touching the text or the cursor.
    private func style(_ view: UITextView) {
        let storage = view.textStorage
        let whole = NSRange(location: 0, length: storage.length)
        let selection = view.selectedRange
        storage.beginEditing()
        storage.setAttributes([.font: UIFont.bighelp(.body), .foregroundColor: textColor], range: whole)
        let string = storage.string as NSString
        var colored = IndexSet()
        for mention in mentions.sorted(by: { $0.text.count > $1.text.count }) {
            var searchRange = whole
            while searchRange.length > 0 {
                let found = string.range(of: mention.text, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                let span = found.location..<(found.location + found.length)
                if !colored.intersects(integersIn: span) {
                    storage.addAttributes([.foregroundColor: mention.color,
                                           .backgroundColor: mention.color.withAlphaComponent(0.16)], range: found)
                    colored.insert(integersIn: span)
                }
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: whole.length - next)
            }
        }
        storage.endEditing()
        view.selectedRange = selection
        view.typingAttributes = [.font: UIFont.bighelp(.body), .foregroundColor: textColor]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeMentionTextView

        init(_ parent: CodeMentionTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
