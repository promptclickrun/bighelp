import SwiftUI
import UIKit

enum RichDraftCommand: Hashable {
    case bold
    case italic
    case inlineCode
    case link
    case heading(Int)
    case unorderedList
    case orderedList
    case codeBlock
}

struct RichDraftFormattingToolbar: View {
    let identifierPrefix: String
    var activeCommands: Set<RichDraftCommand> = []
    let onCommand: (RichDraftCommand) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space4) {
                commandButton("Bold", systemImage: "bold", command: .bold, identifier: "bold")
                commandButton("Italic", systemImage: "italic", command: .italic, identifier: "italic")
                commandButton("Inline code", systemImage: "chevron.left.forwardslash.chevron.right", command: .inlineCode, identifier: "inline-code")
                commandButton("Link", systemImage: "link", command: .link, identifier: "link")

                Menu {
                    ForEach(1...6, id: \.self) { level in
                        blockButton("Heading \(level)", systemImage: "textformat.size", command: .heading(level))
                    }
                    Divider()
                    blockButton("Bulleted list", systemImage: "list.bullet", command: .unorderedList)
                    blockButton("Numbered list", systemImage: "list.number", command: .orderedList)
                    blockButton("Code block", systemImage: "curlybraces.square", command: .codeBlock)
                } label: {
                    Label("Block formatting", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .background(blockIsActive ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 8))
                .accessibilityAddTraits(blockIsActive ? .isSelected : [])
                .accessibilityLabel("Block formatting")
                .accessibilityIdentifier("\(identifierPrefix).blocks")
            }
            .padding(.horizontal, BighelpTokens.space4)
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.borderless)
    }

    private var blockIsActive: Bool {
        activeCommands.contains { command in
            switch command {
            case .heading, .unorderedList, .orderedList, .codeBlock: true
            default: false
            }
        }
    }

    private func blockButton(_ title: String, systemImage: String, command: RichDraftCommand) -> some View {
        Button { onCommand(command) } label: {
            Label(title, systemImage: activeCommands.contains(command) ? "checkmark" : systemImage)
        }
        .accessibilityAddTraits(activeCommands.contains(command) ? .isSelected : [])
    }

    private func commandButton(
        _ title: String,
        systemImage: String,
        command: RichDraftCommand,
        identifier: String
    ) -> some View {
        Button(title, systemImage: systemImage) { onCommand(command) }
            .labelStyle(.iconOnly)
            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
            .background(activeCommands.contains(command) ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 8))
            .accessibilityAddTraits(activeCommands.contains(command) ? .isSelected : [])
            .accessibilityLabel(title)
            .accessibilityIdentifier("\(identifierPrefix).\(identifier)")
    }
}

struct RichDraftLinkSheet: View {
    @Binding var target: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com", text: $target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Link destination")
            }
            .navigationTitle("Add link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: onAdd)
                        .disabled(URL(string: target.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.defaultAction)
                        #endif
                }
            }
        }
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
        .bighelpSheetSize(.compact)
    }
}

/// Focus requests can arrive before a representable is in a window. Keep the
/// request at the native owner and fulfill it at attachment, not on a timer.
/// One owner spans rich/source replacements; outgoing callbacks cannot clear it.
@MainActor
final class RichDraftFocusOwner {
    private weak var view: UITextView?
    private var needsFocus = false

    func attach(_ view: UITextView) {
        self.view = view
        let attachment = WindowAttachment()
        attachment.isUserInteractionEnabled = false
        attachment.isAccessibilityElement = false
        attachment.owner = self
        attachment.textView = view
        view.addSubview(attachment)
        focusIfReady(view)
    }

    func requestFocus() {
        needsFocus = true
        if let view { focusIfReady(view) }
    }

    func prepareForReplacement() {
        // Retire before SwiftUI removes the outgoing branch, not after UIKit
        // has already delivered its didEndEditing callback during removal.
        view = nil
        needsFocus = true
    }

    func detach(_ view: UITextView) {
        guard self.view === view else { return }
        self.view = nil
        needsFocus = false
    }

    func didBeginEditing(_ view: UITextView) -> Bool {
        guard self.view === view else { return false }
        needsFocus = false
        return true
    }

    func didEndEditing(_ view: UITextView) -> Bool {
        guard self.view === view, view.window != nil, !view.isFirstResponder else { return false }
        needsFocus = false
        return true
    }

    private func focusIfReady(_ view: UITextView) {
        guard self.view === view, needsFocus, view.window != nil, view.isEditable else { return }
        if view.isFirstResponder { needsFocus = false; return }
        let selection = view.selectedRange
        let typing = view.typingAttributes
        if view.becomeFirstResponder() {
            view.selectedRange = selection
            view.typingAttributes = typing
            needsFocus = false
        }
    }

    private final class WindowAttachment: UIView {
        weak var owner: RichDraftFocusOwner?
        weak var textView: UITextView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let textView { owner?.focusIfReady(textView) }
        }
    }
}

struct MarkdownSourceTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    var focus: FocusState<Bool>.Binding?
    var onPasteImageProviders: (([NSItemProvider]) -> Void)? = nil
    var onReturnKey: ((ComposerReturnKey) -> Bool)? = nil
    var contentRevision: Int = 0
    var focusOwner: RichDraftFocusOwner? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ClipboardPasteTextView {
        let textView = ClipboardPasteTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.bighelp(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        #if !os(visionOS)
        textView.keyboardDismissMode = .none
        #endif
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityHint = "Edits Markdown source"
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.text = text
        textView.selectedRange = clamped(selection, length: textView.textStorage.length)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        context.coordinator.focusOwner.attach(textView)
        return textView
    }

    func updateUIView(_ textView: ClipboardPasteTextView, context: Context) {
        context.coordinator.parent = self
        textView.isClipboardImagePasteEnabled = onPasteImageProviders != nil
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onReturnKey = onReturnKey
        let isExternalTransaction = context.coordinator.appliedRevision != contentRevision
        if (isExternalTransaction || !textView.isFirstResponder), textView.markedTextRange == nil {
            context.coordinator.isApplyingUpdate = true
            if Data(textView.text.utf8) != Data(text.utf8) || isExternalTransaction {
                textView.text = text
                textView.selectedRange = clamped(selection, length: textView.textStorage.length)
            }
            context.coordinator.appliedRevision = contentRevision
            context.coordinator.isApplyingUpdate = false
        }
        // UIKit owns the live caret while typing. Reapplying selection-only
        // binding echoes can move it behind the next keystroke and corrupt text.
        // Formatting transactions change text and apply their selection above.
        // SwiftUI clears the outgoing rich editor's focus during a mode swap.
        // That delayed echo must not resign the newly focused native source view.
        // UIKit owns normal responder changes; dismissal is handled by dismantle.
        if focus?.wrappedValue == true { context.coordinator.focusOwner.requestFocus() }
    }

    static func dismantleUIView(_ view: ClipboardPasteTextView, coordinator: Coordinator) {
        coordinator.focusOwner.detach(view)
        view.onPasteImageProviders = nil
        view.isClipboardImagePasteEnabled = false
        view.delegate = nil
        view.undoManager?.removeAllActions(withTarget: coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceTextView
        var isApplyingUpdate = false
        var appliedRevision: Int
        let focusOwner: RichDraftFocusOwner

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
            focusOwner = parent.focusOwner ?? RichDraftFocusOwner()
            appliedRevision = parent.contentRevision
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard !isApplyingUpdate, textView.markedTextRange == nil,
                  textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
                  replacement == "\n",
                  let result = MarkdownSourceFormatter.returning(in: textView.text, selection: range) else { return true }
            install(result.source, selection: result.selection, in: textView)
            return false
        }

        private func install(_ source: String, selection: NSRange, in textView: UITextView) {
            let oldText = textView.text ?? ""
            let oldSelection = textView.selectedRange
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.install(oldText, selection: oldSelection, in: textView)
            }
            textView.undoManager?.setActionName("Edit list")
            isApplyingUpdate = true
            let undo = textView.undoManager
            let disabledHere = undo?.isUndoRegistrationEnabled == true
            if disabledHere { undo?.disableUndoRegistration() }
            textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: textView.textStorage.length), with: source)
            textView.selectedRange = selection
            if disabledHere, undo?.isUndoRegistrationEnabled == false { undo?.enableUndoRegistration() }
            isApplyingUpdate = false
            parent.text = source
            parent.selection = selection
            textView.scrollRangeToVisible(selection)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingUpdate else { return }
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingUpdate else { return }
            parent.selection = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if focusOwner.didBeginEditing(textView) { parent.focus?.wrappedValue = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if focusOwner.didEndEditing(textView) { parent.focus?.wrappedValue = false }
        }
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}

/// Owners must retain this snapshot and block Send/Close/export while it is pending.
/// It is recovery data, not a plain-text substitute for the attributed draft.
@available(iOS 26.0, *)
struct RichDraftRecoveryState {
    var text: AttributedString?
    var selection: AttributedTextSelection?
    var lastCommittedMarkdown: String
    var reason: String?

    var hasUnexportedChanges: Bool { text != nil }
}

/// Native iOS 26 rich editor. The bound Markdown string is the only persisted authority.
/// Keep this view's identity stable; do not key it by the draft or its character count.
@available(iOS 26.0, *)
struct RichDraftEditor: View {
    @Binding private var markdown: String
    private let isFocused: FocusState<Bool>.Binding
    private let identifierPrefix: String
    private let onPasteImageProviders: (([NSItemProvider]) -> Void)?
    /// A chat's message box takes hardware Return keys; the Scratchpad doesn't.
    private let onReturnKey: ((ComposerReturnKey) -> Bool)?
    private let onRecoveryStateChange: (RichDraftRecoveryState) -> Void
    private let initialRecovery: RichDraftRecoveryState?

    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var buffer = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var sourceSelection = NSRange(location: 0, length: 0)
    @State private var sourceRevision = 0
    @State private var lastSource = ""
    @State private var isLoaded = false
    @State private var isSourceMode = false
    @State private var sourceReason: String?
    @State private var editError: String?
    @State private var pendingReason: String?
    @State private var discardConfirmation = false
    @State private var acceptedDocument: RichDraftMarkdown.Document?
    @State private var richRevision = 0
    @State private var isComposing = false
    @State private var isLinkPromptPresented = false
    @State private var linkTarget = "https://"
    @State private var focusOwner = RichDraftFocusOwner()

    init(
        markdown: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        identifierPrefix: String = "chat.composer.expanded",
        onPasteImageProviders: (([NSItemProvider]) -> Void)? = nil,
        onReturnKey: ((ComposerReturnKey) -> Bool)? = nil,
        recovery: RichDraftRecoveryState? = nil,
        onRecoveryStateChange: @escaping (RichDraftRecoveryState) -> Void
    ) {
        _markdown = markdown
        self.isFocused = isFocused
        self.identifierPrefix = identifierPrefix
        self.onPasteImageProviders = onPasteImageProviders
        self.onReturnKey = onReturnKey
        self.onRecoveryStateChange = onRecoveryStateChange
        initialRecovery = recovery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                RichDraftFormattingToolbar(identifierPrefix: identifierPrefix, activeCommands: activeCommands, onCommand: apply)
                    .disabled(isComposing)
                if verticalSizeClass == .compact, let onPasteImageProviders {
                    ClipboardImagePasteControl(onPaste: onPasteImageProviders)
                        .frame(width: 115, height: 44)
                        .accessibilityLabel("Paste Image")
                }
                Button(isSourceMode ? "Rich text" : "Markdown") {
                    if isSourceMode { tryRichMode() } else { showSource() }
                }
                .font(.bighelp(.caption))
                .frame(minHeight: BighelpTokens.hitTarget)
                .disabled(pendingReason != nil)
                .accessibilityIdentifier("\(identifierPrefix).mode")
                .accessibilityHint(sourceReason ?? "Switches between rich text and Markdown source.")
            }

            if verticalSizeClass != .compact, let onPasteImageProviders {
                ClipboardImagePasteControl(onPaste: onPasteImageProviders)
                    .frame(width: 115, height: 44)
                    .accessibilityLabel("Paste Image")
            }

            if let sourceReason, isSourceMode, verticalSizeClass != .compact {
                Text(sourceReason)
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifierPrefix).sourceReason")
            }

            if let pendingReason {
                HStack(alignment: .top) {
                    Text(pendingReason)
                        .font(.bighelp(.caption))
                        .accessibilityIdentifier("\(identifierPrefix).unsaved")
                    Button("Discard unsaved changes", role: .destructive) {
                        discardConfirmation = true
                    }
                    .font(.bighelp(.caption))
                }
            }

            if isSourceMode {
                MarkdownSourceTextView(
                    text: sourceBinding,
                    selection: $sourceSelection,
                    accessibilityIdentifier: "\(identifierPrefix).text",
                    accessibilityLabel: identifierPrefix == "chat.composer.expanded"
                        ? "Expanded message"
                        : "Scratchpad",
                    focus: isFocused,
                    onPasteImageProviders: onPasteImageProviders,
                    onReturnKey: onReturnKey,
                    contentRevision: sourceRevision,
                    focusOwner: focusOwner
                )
            } else {
                RichDraftNativeTextView(
                    text: buffer,
                    selection: selection,
                    contentRevision: richRevision,
                    fontContext: fontContext,
                    accessibilityIdentifier: "\(identifierPrefix).text",
                    accessibilityLabel: identifierPrefix == "chat.composer.expanded"
                        ? "Expanded message" : "Scratchpad",
                    focus: isFocused,
                    onPasteImageProviders: onPasteImageProviders,
                    onReturnKey: onReturnKey,
                    onEdit: { text, selection, composing in
                        accept(text, selection: selection, isComposing: composing)
                    },
                    onSelectionChange: { updatedSelection in
                        selection = updatedSelection
                        if pendingReason != nil { publishRecovery() }
                    },
                    onPasteRejected: { editError = $0 },
                    focusOwner: focusOwner
                )
                    .accessibilityAction(named: "Toggle bold") { toggle(.bold) }
                    .accessibilityAction(named: "Toggle italic") { toggle(.italic) }
                    .accessibilityAction(named: "Toggle inline code") { toggle(.code) }
                    .accessibilityAction(named: "Edit Markdown source") { showSource() }
            }
        }
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            if let initialRecovery, let text = initialRecovery.text {
                // The owner supplies recovery only for this exact draft/session identity.
                buffer = text
                selection = initialRecovery.selection ?? .init()
                richRevision &+= 1
                lastSource = initialRecovery.lastCommittedMarkdown
                pendingReason = initialRecovery.reason
                    ?? "Your unsaved rich-text edits have been recovered. Adjust or undo the last change before leaving."
                publishRecovery()
            } else {
                loadExternalSource()
            }
        }
        .onChange(of: Data(markdown.utf8)) { _, _ in
            guard !RichDraftMarkdown.sameSource(markdown, lastSource) else { return }
            // A late owner update must not destroy a retained native proposal.
            guard pendingReason == nil else {
                publishRecovery()
                return
            }
            if isSourceMode {
                lastSource = markdown
                sourceRevision &+= 1
            } else {
                loadExternalSource()
            }
        }
        .bighelpSheet(isPresented: $isLinkPromptPresented, onDismiss: resumeEditing) {
            RichDraftLinkSheet(
                target: $linkTarget,
                onCancel: { isLinkPromptPresented = false },
                onAdd: {
                    isLinkPromptPresented = false
                    applyLink()
                }
            )
        }
        .confirmationDialog("Discard unsaved rich-text changes?", isPresented: $discardConfirmation,
                            titleVisibility: .visible) {
            Button("Discard unsaved changes", role: .destructive) {
                pendingReason = nil
                loadExternalSource()
            }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Only the last saved Markdown will remain. This cannot recover the unsaved formatting or text.")
        }
        .alert("Formatting unavailable", isPresented: errorPresented) {
            if pendingReason == nil { Button("Edit Markdown") { showSource() } }
            Button("Keep editing", role: .cancel) { editError = nil }
        } message: {
            Text(editError ?? "Continue editing your draft.")
        }
    }

    private var activeCommands: Set<RichDraftCommand> {
        isSourceMode
            ? MarkdownSourceFormatter.activeCommands(in: markdown, selection: sourceSelection)
            : RichDraftFormatting.activeCommands(in: buffer, selection: selection, context: fontContext)
    }

    private var sourceBinding: Binding<String> {
        Binding(get: { markdown }, set: { value in
            lastSource = value
            markdown = value
            publishRecovery()
        })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })
    }

    private func loadExternalSource() {
        isComposing = false
        acceptedDocument = nil
        lastSource = markdown
        defer { publishRecovery() }
        switch RichDraftMarkdown.importSource(markdown) {
        case .rich(let document):
            installRichDocument(document, explainFailure: false)
        case .source(let reason):
            sourceReason = reason
            if !isSourceMode, isFocused.wrappedValue { focusOwner.prepareForReplacement() }
            isSourceMode = true
        }
    }

    private func showSource() {
        guard pendingReason == nil else { return }
        editError = nil
        sourceReason = "Markdown mode preserves every source byte. Rich Text supports headings, flat lists, links, inline code, fenced code, bold, and italic."
        focusOwner.prepareForReplacement()
        isFocused.wrappedValue = true
        isSourceMode = true
    }

    private func tryRichMode() {
        switch RichDraftMarkdown.importSource(markdown) {
        case .rich(let document):
            installRichDocument(document, explainFailure: true)
        case .source(let reason):
            sourceReason = reason
            editError = reason
        }
    }

    private func installRichDocument(_ document: RichDraftMarkdown.Document, explainFailure: Bool) {
        guard let replacement = RichDraftFormatting.losslessAttributed(document, context: fontContext) else {
            let reason = "This draft contains empty or advanced structure that needs Markdown mode to preserve it. Your draft is unchanged."
            sourceReason = reason
            if !isSourceMode, isFocused.wrappedValue { focusOwner.prepareForReplacement() }
            isSourceMode = true
            if explainFailure { editError = reason }
            return
        }
        buffer.transform(updating: &selection) { $0 = replacement }
        richRevision &+= 1
        acceptedDocument = document
        pendingReason = nil
        isComposing = false
        lastSource = markdown
        sourceReason = nil
        if isSourceMode {
            focusOwner.prepareForReplacement()
            isFocused.wrappedValue = true
        }
        isSourceMode = false
    }

    private func accept(_ proposed: AttributedString, selection updatedSelection: AttributedTextSelection,
                        isComposing composing: Bool) {
        guard isLoaded, !isSourceMode else { return }
        // The bridge already applied any shortcut atomically. Never transform its
        // callback a second time, or feed this snapshot back into active typing.
        buffer = proposed
        selection = updatedSelection
        isComposing = composing
        if composing {
            pendingReason = "Finishing the current text composition."
            publishRecovery()
            return
        }
        let after = RichDraftFormatting.document(
            buffer, context: fontContext,
            typingAttributes: RichDraftFormatting.trailingTypingAttributes(in: buffer, selection: selection)
        )
        guard RichDraftMarkdown.sameSource(markdown, lastSource) else {
            pendingReason = "The saved draft changed elsewhere. Your unsaved rich text is still here. Keep it open until you resolve which draft to keep."
            publishRecovery()
            return
        }
        if let acceptedDocument, RichDraftMarkdown.equivalent(acceptedDocument, after) {
            pendingReason = nil
            publishRecovery()
            return // Preserve exact original Markdown bytes on a semantic no-op.
        }
        do {
            let source = try RichDraftMarkdown.export(after)
            markdown = source
            guard RichDraftMarkdown.sameSource(markdown, source) else {
                pendingReason = "The draft owner could not accept these edits. Your rich text is retained here; resolve the save error before leaving."
                publishRecovery()
                return
            }
            lastSource = source
            acceptedDocument = after
            pendingReason = nil
        } catch {
            pendingReason = "These edits are still here, but cannot yet be saved as Markdown. Undo or adjust the last change before closing, sending, or exporting."
        }
        publishRecovery()
    }

    private func publishRecovery() {
        onRecoveryStateChange(.init(
            text: pendingReason == nil ? nil : buffer,
            selection: pendingReason == nil ? nil : selection,
            lastCommittedMarkdown: lastSource,
            reason: pendingReason
        ))
    }

    private func resumeEditing() {
        isFocused.wrappedValue = true
        focusOwner.requestFocus()
    }

    private func apply(_ command: RichDraftCommand) {
        guard !isComposing else { return }
        resumeEditing()
        if command == .link, !activeCommands.contains(.link) {
            linkTarget = "https://"
            isLinkPromptPresented = true
            return
        }
        if isSourceMode {
            let result = MarkdownSourceFormatter.apply(command, to: markdown, selection: sourceSelection)
            sourceSelection = result.selection
            lastSource = result.source
            markdown = result.source
            sourceRevision &+= 1
            return
        }
        do {
            if activeCommands.contains(command) {
                switch command {
                case .heading, .unorderedList, .orderedList, .codeBlock:
                    install(try RichDraftFormatting.removingBlock(in: buffer, selection: selection, context: fontContext))
                    return
                case .link:
                    install(try RichDraftFormatting.removingLink(in: buffer, selection: selection, context: fontContext))
                    return
                default: break
                }
            }
            let result: (text: AttributedString, selection: AttributedTextSelection, markdown: String)
            switch command {
            case .bold:
                result = try RichDraftFormatting.toggling(.bold, in: buffer, selection: selection, context: fontContext)
            case .italic:
                result = try RichDraftFormatting.toggling(.italic, in: buffer, selection: selection, context: fontContext)
            case .inlineCode:
                result = try RichDraftFormatting.toggling(.code, in: buffer, selection: selection, context: fontContext)
            case .heading(let level):
                result = try RichDraftFormatting.applyingBlock(.heading(level), in: buffer, selection: selection, context: fontContext)
            case .unorderedList:
                result = try RichDraftFormatting.applyingBlock(.unorderedList, in: buffer, selection: selection, context: fontContext)
            case .orderedList:
                result = try RichDraftFormatting.applyingBlock(.orderedList, in: buffer, selection: selection, context: fontContext)
            case .codeBlock:
                result = try RichDraftFormatting.applyingBlock(.codeBlock, in: buffer, selection: selection, context: fontContext)
            case .link:
                return
            }
            install(result)
        } catch {
            editError = "This formatting change was not saved. " + error.localizedDescription
        }
    }

    private func applyLink() {
        guard !isComposing else { return }
        let target = linkTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: target), url.scheme != nil else {
            editError = "Enter a complete link, including its scheme."
            return
        }
        if isSourceMode {
            let result = MarkdownSourceFormatter.apply(.link, to: markdown, selection: sourceSelection, linkTarget: target)
            sourceSelection = result.selection
            lastSource = result.source
            markdown = result.source
            sourceRevision &+= 1
            return
        }
        do {
            install(try RichDraftFormatting.applyingLink(url, in: buffer, selection: selection, context: fontContext))
        } catch {
            editError = "This link was not saved. " + error.localizedDescription
        }
    }

    private func toggle(_ style: RichDraftMarkdown.Style) {
        guard !isComposing else { return }
        do {
            install(try RichDraftFormatting.toggling(style, in: buffer, selection: selection, context: fontContext))
        } catch {
            editError = "This formatting change was not saved. " + error.localizedDescription
        }
    }

    /// Toolbar transactions also carry typing-only changes; serialization must
    /// not canonicalize the accepted source when document content is unchanged.
    static func sourceForInstallation(_ document: RichDraftMarkdown.Document,
                                      acceptedDocument: RichDraftMarkdown.Document?,
                                      lastSource: String, serializedSource: String) -> String {
        if let acceptedDocument, RichDraftMarkdown.equivalent(acceptedDocument, document) {
            return lastSource
        }
        return serializedSource
    }

    private func install(_ result: (text: AttributedString, selection: AttributedTextSelection, markdown: String)) {
        guard RichDraftMarkdown.sameSource(markdown, lastSource) else {
            editError = "The saved draft changed elsewhere. Resolve that change before applying formatting."
            return
        }
        buffer = result.text
        selection = result.selection
        richRevision &+= 1
        let document = RichDraftFormatting.document(
            buffer, context: fontContext,
            typingAttributes: RichDraftFormatting.trailingTypingAttributes(in: buffer, selection: selection)
        )
        let source = Self.sourceForInstallation(document, acceptedDocument: acceptedDocument,
                                                lastSource: lastSource, serializedSource: result.markdown)
        markdown = source
        guard RichDraftMarkdown.sameSource(markdown, source) else {
            pendingReason = "The draft owner could not accept this formatting. Your rich text is retained here; resolve the save error before leaving."
            publishRecovery()
            return
        }
        lastSource = source
        acceptedDocument = document
        pendingReason = nil
        publishRecovery()
    }
}
