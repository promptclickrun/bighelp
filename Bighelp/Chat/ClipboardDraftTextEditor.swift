import SwiftUI
import UIKit

/// Public-UIKit fallback for the expanded plain-text composer. Rich iOS 26
/// editing has a separate native editor seam and must opt into the same paste
/// callback explicitly rather than relying on SwiftUI paste modifiers.
struct ClipboardDraftTextEditor: UIViewRepresentable {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let isEnabled: Bool
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    var onDropAttachmentProviders: (([NSItemProvider]) -> Void)? = nil
    var onReturnKey: ((ComposerReturnKey) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onPasteImageProviders: onPasteImageProviders)
    }

    func makeUIView(context: Context) -> ClipboardPasteTextView {
        let view = ClipboardPasteTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.bighelp(.body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        #if !os(visionOS)
        view.keyboardDismissMode = .none
        #endif
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "Expanded message"
        view.accessibilityIdentifier = "chat.composer.expanded.text"
        view.text = text
        view.isEditable = isEnabled
        view.isClipboardImagePasteEnabled = isEnabled
        view.onPasteImageProviders = context.coordinator.pasteImages
        view.attachmentDrop.onDropProviders = isEnabled ? onDropAttachmentProviders : nil
        view.onReturnKey = onReturnKey
        return view
    }

    func updateUIView(_ view: ClipboardPasteTextView, context: Context) {
        view.onReturnKey = onReturnKey
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onPasteImageProviders = onPasteImageProviders
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(
                location: min(selection.location, view.text.utf16.count),
                length: 0
            )
        }
        view.isEditable = isEnabled
        view.isClipboardImagePasteEnabled = isEnabled
        view.onPasteImageProviders = context.coordinator.pasteImages
        view.attachmentDrop.onDropProviders = isEnabled ? onDropAttachmentProviders : nil

        if isFocused.wrappedValue, !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, view.isEditable else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused.wrappedValue, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: ClipboardPasteTextView, coordinator: Coordinator) {
        view.isClipboardImagePasteEnabled = false
        view.onPasteImageProviders = nil
        view.attachmentDrop.onDropProviders = nil
        view.delegate = nil
        view.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isFocused: FocusState<Bool>.Binding
        var onPasteImageProviders: ([NSItemProvider]) -> Void

        init(
            text: Binding<String>,
            isFocused: FocusState<Bool>.Binding,
            onPasteImageProviders: @escaping ([NSItemProvider]) -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onPasteImageProviders = onPasteImageProviders
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused.wrappedValue = false
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func pasteImages(_ providers: [NSItemProvider]) {
            onPasteImageProviders(providers)
        }
    }
}
