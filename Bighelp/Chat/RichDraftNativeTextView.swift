import SwiftUI
import UIKit

/// UIKit owns the live attributed value and UTF-16 caret. SwiftUI only installs
/// explicit toolbar/load transactions, never echoes the results of native typing.
@available(iOS 26.0, *)
struct RichDraftNativeTextView: UIViewRepresentable {
    let text: AttributedString
    let selection: AttributedTextSelection
    let contentRevision: Int
    let fontContext: Font.Context
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    var focus: FocusState<Bool>.Binding
    var onPasteImageProviders: (([NSItemProvider]) -> Void)?
    var onDropAttachmentProviders: (([NSItemProvider]) -> Void)? = nil
    var onReturnKey: ((ComposerReturnKey) -> Bool)? = nil
    var onEdit: (AttributedString, AttributedTextSelection, Bool) -> Void
    var onSelectionChange: (AttributedTextSelection) -> Void
    var onPasteRejected: (String) -> Void = { _ in }
    var focusOwner: RichDraftFocusOwner? = nil

    @BighelpThemeReader private var theme

    @MainActor
    static func pasteRejectionReason(_ text: NSAttributedString, context: Font.Context) -> String? {
        let warning = "This content was not pasted because its formatting or attachments cannot be saved as Markdown. Paste plain text instead, or attach images separately."
        guard RichDraftNativeAttributes.supportsPaste(text) else { return warning }
        do {
            _ = try RichDraftMarkdown.export(RichDraftFormatting.document(
                RichDraftNativeAttributes.attributed(text), context: context))
            return nil
        } catch { return warning }
    }

    @MainActor
    static func nativeAttributed(_ text: AttributedString, context: Font.Context) -> NSAttributedString {
        RichDraftNativeAttributes.native(text, context: context)
    }

    @MainActor
    static func swiftAttributed(_ text: NSAttributedString, context _: Font.Context) -> AttributedString {
        RichDraftNativeAttributes.attributed(text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> RichDraftUIKitTextView {
        let view = RichDraftUIKitTextView()
        view.backgroundColor = .clear
        view.font = theme.uiFont(.body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        #if !os(visionOS)
        view.keyboardDismissMode = .none
        #endif
        view.allowsEditingTextAttributes = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = "Formatting is saved as Markdown"
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        context.coordinator.view = view
        view.onCompositionEnded = { [weak coordinator = context.coordinator] in
            coordinator?.compositionEnded()
        }
        context.coordinator.install(text, selection: selection, in: view)
        context.coordinator.focusOwner.attach(view)
        return view
    }

    func updateUIView(_ view: RichDraftUIKitTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.isEditable != context.environment.isEnabled {
            view.isEditable = context.environment.isEnabled
        }
        view.onPasteImageProviders = onPasteImageProviders
        view.attachmentDrop.onDropProviders = onDropAttachmentProviders
        view.onReturnKey = onReturnKey
        if coordinator.appliedRevision != contentRevision, !view.isComposing {
            // Toolbar edits participate in undo. Loading an external document does
            // not replay a stale selection-only echo while the view is focused.
            coordinator.installExternal(text, selection: selection, in: view)
            coordinator.appliedRevision = contentRevision
        }
        if focus.wrappedValue { coordinator.focusOwner.requestFocus() }
        // Responder changes belong to UIKit; a delayed outgoing-mode focus echo
        // must not resign the new editor. Dismantling removes all callbacks.
    }

    static func dismantleUIView(_ view: RichDraftUIKitTextView, coordinator: Coordinator) {
        coordinator.focusOwner.detach(view)
        view.onPasteImageProviders = nil
        view.attachmentDrop.onDropProviders = nil
        view.onReturnKey = nil
        view.onCompositionEnded = nil
        view.delegate = nil
        view.pasteDelegate = nil
        view.undoManager?.removeAllActions(withTarget: coordinator)
        coordinator.view = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: RichDraftNativeTextView
        weak var view: RichDraftUIKitTextView?
        var appliedRevision: Int
        let focusOwner: RichDraftFocusOwner
        private var isApplying = false
        private var editingState = RichDraftEditingTransaction.State()
        private var lastPublishedText = NSAttributedString(string: "")
        private var publishedComposition = false

        init(parent: RichDraftNativeTextView) {
            self.parent = parent
            focusOwner = parent.focusOwner ?? RichDraftFocusOwner()
            appliedRevision = parent.contentRevision
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard !isApplying, let view = textView as? RichDraftUIKitTextView else { return true }
            guard !view.isComposing, textView.undoManager?.isUndoing != true,
                  textView.undoManager?.isRedoing != true else {
                editingState = .init()
                return true
            }
            var attributes = textView.typingAttributes
            if range.length == 0, range.location >= 0, range.location <= textView.textStorage.length,
               !replacement.isEmpty, !replacement.contains("\n") {
                let paragraph = (textView.textStorage.string as NSString).paragraphRange(for: range)
                let text = RichDraftNativeAttributes.attributed(textView.textStorage.attributedSubstring(from: paragraph))
                if let level = RichDraftFormatting.headingLevel(in: text, context: parent.fontContext) {
                    // UIKit may reset typing attributes after a view update. The
                    // current paragraph's semantic heading role remains authoritative.
                    let insertion = RichDraftNativeAttributes.attributed(NSAttributedString(string: replacement, attributes: attributes))
                    let styled = RichDraftFormatting.settingParagraphRole(insertion, heading: level, context: parent.fontContext)
                    let native = RichDraftNativeAttributes.native(styled, context: parent.fontContext, theme: parent.theme)
                    attributes = native.attributes(at: 0, effectiveRange: nil)
                    textView.typingAttributes = attributes
                }
            }
            let insertion = NSAttributedString(string: replacement, attributes: attributes)
            return replace(in: view, range: range, insertion: insertion, allowNativeOrdinaryEdit: true)
        }

        /// The public paste delegate supplies the actual attributed payload, not
        /// shouldChange's plain-string preview. Keep all its runs for the transaction.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString, to textRange: UITextRange
        ) -> UITextRange {
            guard let view else { return textRange }
            // Validate the original native payload before semantic projection can
            // discard foreign attributes, and before changing selection or undo.
            if let reason = RichDraftNativeTextView.pasteRejectionReason(attributedString, context: parent.fontContext) {
                parent.onPasteRejected(reason)
                return textRange
            }
            if view.isComposing { view.unmarkText() }
            let start = view.offset(from: view.beginningOfDocument, to: textRange.start)
            let end = view.offset(from: view.beginningOfDocument, to: textRange.end)
            _ = replace(in: view, range: NSRange(location: start, length: end - start),
                        insertion: attributedString, allowNativeOrdinaryEdit: false)
            return view.selectedTextRange ?? textRange
        }

        /// Returns true only when UIKit should perform the ordinary edit itself.
        /// Shortcuts are installed (including caret/typing attributes) before this
        /// stack unwinds, so the next keystroke sees precisely the transformed value.
        private func replace(in view: RichDraftUIKitTextView, range: NSRange,
                             insertion: NSAttributedString, allowNativeOrdinaryEdit: Bool) -> Bool {
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location <= view.textStorage.length,
                  range.length <= view.textStorage.length - range.location else { return false }
            let before = Snapshot(view)
            let previous = RichDraftNativeAttributes.attributed(before.text)
            let selection = RichDraftNativeAttributes.selection(
                range, in: previous, typing: before.typing)
            let proposedNative = NSMutableAttributedString(attributedString: before.text)
            proposedNative.replaceCharacters(in: range, with: insertion)
            let proposed = RichDraftNativeAttributes.attributed(proposedNative)
            let transaction = RichDraftEditingTransaction.apply(
                previous: previous, proposed: proposed, selection: selection,
                state: &editingState, context: parent.fontContext)
            if transaction.kind == .ordinary, allowNativeOrdinaryEdit { return true }

            let updatedSelection = transaction.selection ?? RichDraftNativeAttributes.selection(
                NSRange(location: range.location + insertion.length, length: 0), in: proposed,
                typing: insertion.length > 0
                    ? insertion.attributes(at: insertion.length - 1, effectiveRange: nil) : before.typing)
            registerUndo(before, in: view)
            if transaction.kind == .ordinary {
                // Do not rebuild foreign paste attributes from a restricted palette.
                apply(Snapshot(text: proposedNative, selection: RichDraftNativeAttributes.range(
                    updatedSelection, in: proposed), typing: insertion.length > 0
                    ? insertion.attributes(at: insertion.length - 1, effectiveRange: nil) : before.typing), in: view)
            } else {
                install(transaction.text, selection: updatedSelection, in: view)
            }
            publish(view)
            view.scrollRangeToVisible(view.selectedRange)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying, let view = textView as? RichDraftUIKitTextView else { return }
            if view.isComposing || view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
                editingState = .init()
            }
            // Ordinary input, dictation and marked text remain UIKit operations.
            // Capture their actual attributes without another shortcut pass.
            publish(view)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying, let view = textView as? RichDraftUIKitTextView else { return }
            // UIKit can notify selection before didChange for the same edit.
            // Never publish a new caret against the parent's old attributed value.
            guard sameNativeText(view.textStorage, lastPublishedText) else { return }
            let text = RichDraftNativeAttributes.attributed(view.textStorage)
            parent.onSelectionChange(RichDraftNativeAttributes.selection(
                view.selectedRange, in: text, typing: view.typingAttributes))
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if focusOwner.didBeginEditing(textView) { parent.focus.wrappedValue = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard focusOwner.didEndEditing(textView) else { return }
            if let view = textView as? RichDraftUIKitTextView { publish(view) }
            parent.focus.wrappedValue = false
        }

        func compositionEnded() {
            guard !isApplying, let view, !view.isComposing, publishedComposition else { return }
            editingState = .init()
            publish(view)
        }

        private func publish(_ view: RichDraftUIKitTextView) {
            let text = RichDraftNativeAttributes.attributed(view.textStorage)
            let selection = RichDraftNativeAttributes.selection(
                view.selectedRange, in: text, typing: view.typingAttributes)
            lastPublishedText = NSAttributedString(attributedString: view.textStorage)
            publishedComposition = view.isComposing
            parent.onEdit(text, selection, publishedComposition)
        }

        func installExternal(_ text: AttributedString, selection: AttributedTextSelection,
                             in view: RichDraftUIKitTextView) {
            if view.isFirstResponder { registerUndo(Snapshot(view), in: view) }
            else { view.undoManager?.removeAllActions() }
            editingState = .init()
            install(text, selection: selection, in: view)
        }

        func install(_ text: AttributedString, selection: AttributedTextSelection,
                     in view: RichDraftUIKitTextView) {
            apply(Snapshot(
                text: RichDraftNativeAttributes.native(text, context: parent.fontContext, theme: parent.theme),
                selection: RichDraftNativeAttributes.range(selection, in: text),
                typing: RichDraftNativeAttributes.native(selection.typingAttributes(in: text),
                                                         context: parent.fontContext, theme: parent.theme)), in: view)
        }

        private func apply(_ snapshot: Snapshot, in view: RichDraftUIKitTextView) {
            isApplying = true
            let undo = view.undoManager
            let disabledByThisEdit = undo?.isUndoRegistrationEnabled == true
            if disabledByThisEdit { undo?.disableUndoRegistration() }
            view.textStorage.setAttributedString(snapshot.text)
            view.selectedRange = snapshot.selection
            view.typingAttributes = snapshot.typing
            // UIKit may reset its undo manager while installing initial text.
            // Only balance our disable if that manager remains disabled.
            if disabledByThisEdit, undo?.isUndoRegistrationEnabled == false {
                undo?.enableUndoRegistration()
            }
            isApplying = false
            lastPublishedText = NSAttributedString(attributedString: view.textStorage)
        }

        private func registerUndo(_ snapshot: Snapshot, in view: RichDraftUIKitTextView) {
            view.undoManager?.registerUndo(withTarget: self) { coordinator in
                guard let view = coordinator.view else { return }
                coordinator.registerUndo(Snapshot(view), in: view)
                coordinator.editingState = .init()
                coordinator.apply(snapshot, in: view)
                coordinator.publish(view)
                view.scrollRangeToVisible(view.selectedRange)
            }
            view.undoManager?.setActionName("Edit text")
        }

        private struct Snapshot {
            let text: NSAttributedString
            let selection: NSRange
            let typing: [NSAttributedString.Key: Any]

            @MainActor
            init(_ view: UITextView) {
                self.init(text: view.textStorage, selection: view.selectedRange, typing: view.typingAttributes)
            }

            init(text: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]) {
                self.text = NSAttributedString(attributedString: text)
                self.selection = selection
                self.typing = typing
            }
        }

        private func sameNativeText(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> Bool {
            lhs.string.utf8.elementsEqual(rhs.string.utf8) && lhs.isEqual(to: rhs)
        }
    }
}

/// Only public UITextInput and Paste responder hooks. The composition flag covers
/// the *first* setMarkedText call, before markedTextRange becomes non-nil.
@available(iOS 26.0, *)
@MainActor
final class RichDraftUIKitTextView: UITextView, ComposerReturnKeyHandling {
    var onPasteImageProviders: (([NSItemProvider]) -> Void)?
    /// Dropped photos and files (`ComposerAttachmentDropTarget`).
    lazy var attachmentDrop = ComposerAttachmentDropTarget(textView: self)
    /// Hardware Return keys in a chat's message box; nil elsewhere (the Scratchpad).
    var onReturnKey: ((ComposerReturnKey) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + returnKeyCommands(
            plain: #selector(returnKey(_:)), shift: #selector(shiftReturnKey(_:)),
            command: #selector(commandReturnKey(_:)))
    }

    @objc private func returnKey(_ sender: UIKeyCommand) { handleReturnKey(.plain) }
    @objc private func shiftReturnKey(_ sender: UIKeyCommand) { handleReturnKey(.shift) }
    @objc private func commandReturnKey(_ sender: UIKeyCommand) { handleReturnKey(.command) }
    var onCompositionEnded: (() -> Void)?
    private var isSettingMarkedText = false
    var isComposing: Bool { isSettingMarkedText || markedTextRange != nil }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        isSettingMarkedText = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        isSettingMarkedText = false
        if markedTextRange == nil { onCompositionEnded?() }
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionEnded?()
    }

    override func paste(_ sender: Any?) {
        guard let request = ClipboardImagePasteRequest.capture() else {
            super.paste(sender)
            return
        }
        guard isEditable, window != nil, let onPasteImageProviders else { return }
        onPasteImageProviders(request.providers)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return isEditable && window != nil && onPasteImageProviders != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// The box is app-owned metadata, not a private SDK attribute. It retains the
/// exact SwiftUI semantic font/color roles across UIKit edits and undo copies.
@available(iOS 26.0, *)
@MainActor
private enum RichDraftNativeAttributes {
    private static let semanticKey = NSAttributedString.Key("app.loopdy.richDraft.semanticAttributes")

    private final class SemanticBox: NSObject, NSCopying {
        let attributes: AttributeContainer
        let rendered: [NSAttributedString.Key: Any]

        init(_ attributes: AttributeContainer, rendered: [NSAttributedString.Key: Any]) {
            self.attributes = attributes
            self.rendered = rendered
        }

        nonisolated func copy(with zone: NSZone? = nil) -> Any { self }
    }

    static func native(_ text: AttributedString, context: Font.Context, theme: BighelpTheme = .light) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            result.append(NSAttributedString(string: String(text[run.range].characters),
                                            attributes: native(run.attributes, context: context, theme: theme)))
        }
        return result
    }

    static func native(_ attributes: AttributeContainer, context: Font.Context, theme: BighelpTheme = .light) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: RichDraftFormatting.nativeFont(for: attributes.font, context: context, theme: theme),
            .foregroundColor: attributes.foregroundColor.map { UIColor($0) } ?? UIColor.label
        ]
        if let background = attributes.backgroundColor { result[.backgroundColor] = UIColor(background) }
        if let link = attributes.link { result[.link] = link }
        if attributes.underlineStyle != nil { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        result[semanticKey] = SemanticBox(attributes, rendered: result)
        return result
    }

    static func supportsPaste(_ text: NSAttributedString) -> Bool {
        var supported = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let box = attributes[semanticKey] as? SemanticBox
            let hasLink = attributes[.link] is URL
                || (attributes[.link] as? String).flatMap { URL(string: $0) } != nil
            for (key, value) in attributes {
                switch key {
                case semanticKey:
                    supported = value is SemanticBox
                case .font:
                    // Family and point size are presentation defaults; retain the
                    // Markdown traits, but never silently drop condensed/expanded styling.
                    if let font = value as? UIFont {
                        let unsupported: UIFontDescriptor.SymbolicTraits = [.traitCondensed, .traitExpanded, .traitVertical]
                        supported = font.fontDescriptor.symbolicTraits.intersection(unsupported).isEmpty
                    } else { supported = false }
                case .foregroundColor:
                    if let color = value as? UIColor {
                        supported = color.isEqual(UIColor.label) || color.isEqual(UIColor.black)
                            || (hasLink && (color.isEqual(UIColor.link) || color.isEqual(UIColor.systemBlue)))
                            || color.isEqual(box?.rendered[key])
                    } else { supported = false }
                case .backgroundColor:
                    if let color = value as? UIColor {
                        supported = color.isEqual(UIColor.clear) || color.isEqual(box?.rendered[key])
                    } else { supported = false }
                case .link:
                    supported = value is URL || (value as? String).flatMap { URL(string: $0) } != nil
                case .underlineStyle:
                    let style = (value as? NSNumber)?.intValue
                    supported = style == 0 || (hasLink && style == NSUnderlineStyle.single.rawValue)
                case .paragraphStyle:
                    if let paragraph = value as? NSParagraphStyle,
                       let normalized = paragraph.mutableCopy() as? NSMutableParagraphStyle {
                        if normalized.alignment == .left { normalized.alignment = .natural }
                        supported = normalized.isEqual(NSParagraphStyle.default)
                    } else { supported = false }
                case .strikethroughStyle, .kern, .baselineOffset, .strokeWidth:
                    supported = (value as? NSNumber)?.doubleValue == 0
                case .ligature:
                    supported = (value as? NSNumber)?.intValue == 1
                default:
                    supported = false
                }
                if !supported { stop.pointee = true; return }
            }
        }
        return supported
    }

    static func attributed(_ native: NSAttributedString) -> AttributedString {
        let string = native.string
        var result = AttributedString(string)
        native.enumerateAttributes(in: NSRange(location: 0, length: native.length)) { attributes, range, _ in
            guard let stringRange = Range(range, in: string),
                  let start = AttributedString.Index(stringRange.lowerBound, within: result),
                  let end = AttributedString.Index(stringRange.upperBound, within: result) else { return }
            result[start..<end].setAttributes(semantic(attributes))
        }
        return result
    }

    private static func semantic(_ native: [NSAttributedString.Key: Any]) -> AttributeContainer {
        let box = native[semanticKey] as? SemanticBox
        var result = box?.attributes ?? AttributeContainer()
        func changed(_ key: NSAttributedString.Key) -> Bool {
            guard let box else { return true }
            let previous = box.rendered[key] as? NSObject
            let current = native[key] as? NSObject
            return previous != current
        }
        if changed(.font) {
            result.font = (native[.font] as? UIFont).map { RichDraftFormatting.semanticFont(for: $0) } ?? .body
        }
        if changed(.foregroundColor) {
            if let color = native[.foregroundColor] as? UIColor {
                result.foregroundColor = color.isEqual(UIColor.secondaryLabel) ? .secondary : Color(uiColor: color)
            } else { result.foregroundColor = nil }
        }
        if changed(.backgroundColor) {
            result.backgroundColor = (native[.backgroundColor] as? UIColor).map { Color(uiColor: $0) }
        }
        if changed(.link) {
            result.link = native[.link] as? URL
                ?? (native[.link] as? String).flatMap { URL(string: $0) }
        }
        if changed(.underlineStyle) {
            let style = (native[.underlineStyle] as? NSNumber)?.intValue ?? 0
            result.underlineStyle = style == 0 ? nil : .single
        }
        return result
    }

    static func selection(_ proposed: NSRange, in text: AttributedString,
                          typing: [NSAttributedString.Key: Any]) -> AttributedTextSelection {
        let string = String(text.characters)
        let length = string.utf16.count
        let location = min(max(0, proposed.location), length)
        let end = location + min(max(0, proposed.length), length - location)
        // UIKit uses UTF-16, while formatting transactions use Characters. Snap a
        // selection outward at grapheme boundaries without splitting surrogate pairs.
        let startIndex = index(location, in: text, roundingUp: false)
        if proposed.length == 0 {
            return .init(insertionPoint: startIndex, typingAttributes: semantic(typing))
        }
        return .init(range: startIndex..<index(end, in: text, roundingUp: true))
    }

    static func range(_ selection: AttributedTextSelection, in text: AttributedString) -> NSRange {
        func offset(_ index: AttributedString.Index) -> Int {
            String(text[text.startIndex..<index].characters).utf16.count
        }
        switch selection.indices(in: text) {
        case .insertionPoint(let index): return NSRange(location: offset(index), length: 0)
        case .ranges(let ranges):
            guard let first = ranges.ranges.first else { return NSRange(location: 0, length: 0) }
            let start = offset(first.lowerBound)
            return NSRange(location: start, length: offset(first.upperBound) - start)
        }
    }

    private static func index(_ utf16Offset: Int, in text: AttributedString,
                              roundingUp: Bool) -> AttributedString.Index {
        var offset = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if offset == utf16Offset { return cursor }
            let next = text.characters.index(after: cursor)
            let nextOffset = offset + String(text[cursor..<next].characters).utf16.count
            if nextOffset > utf16Offset { return roundingUp ? next : cursor }
            offset = nextOffset
            cursor = next
        }
        return text.endIndex
    }
}
