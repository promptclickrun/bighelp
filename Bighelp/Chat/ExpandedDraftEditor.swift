import SwiftUI
import UIKit

struct ExpandedDraftEditor: View {
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    @Bindable var model: ChatModel
    let agentName: String
    let onAttachmentTap: (() -> Void)?
    let onSend: () -> Void
    var referenceHub: ReferenceHubStore? = nil
    var referenceSkills: SkillsAndToolsStore? = nil
    var referenceEditorSession: ReferenceComposerEditorSession? = nil
    var onReferenceMidSessionSend: ((MidSessionChatBehavior) -> Void)? = nil
    @State private var localReferenceEditorSession = ReferenceComposerEditorSession()
    @State private var isReferenceSourceMode = true
    @AppStorage(ChatLayoutPreferences.returnSendsKey) private var returnSends = true
    @State private var keyboardSendOptionsRequest = 0

    @FocusState private var isEditorFocused: Bool
    @State private var isReferenceEditorFocused = false
    @State private var clipboardImportSession = ClipboardImageImportSession()
    @State private var clipboardImportTask: Task<Void, Never>?
    @State private var clipboardErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompactHeight ? BighelpTokens.space4 : BighelpTokens.space16) {
            HStack(spacing: BighelpTokens.space12) {
                Button(action: collapse) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse message editor")
                .accessibilityIdentifier("chat.composer.expanded.collapse")
                .disabled(model.richDraftRecovery.hasUnexportedChanges)
                #if targetEnvironment(macCatalyst)
                // Esc closes the editor like any Mac sheet; an open Skills &
                // commands list takes Esc first (`ReferenceComposerContainer`).
                .keyboardShortcut(.cancelAction)
                #endif

                Text("Message \(agentName)")
                    .bighelpFont(.sectionTitle, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: BighelpTokens.space12)
                if referenceHub != nil, #available(iOS 26.0, *), uiV2Enabled {
                    Button(isReferenceSourceMode ? "Rich text" : "References / Markdown") {
                        isReferenceSourceMode.toggle()
                        isEditorFocused = true
                        isReferenceEditorFocused = true
                    }
                    .font(.bighelp(.caption))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("reference-hub.editor-mode")
                    .disabled(model.richDraftRecovery.hasUnexportedChanges)
                }
                if isCompactHeight { composerActions }
            }

            VStack(spacing: BighelpTokens.space12) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty && !usesRichEditor {
                        Text("Write a message")
                            .bighelpFont(.body)
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }

                    GeometryReader { viewport in
                        expandedInput
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .foregroundStyle(theme.primaryText)
                            .disabled(model.isComposerInputDisabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(isCompactHeight ? BighelpTokens.space8 : BighelpTokens.space12)
                .bighelpSurface(uiV2Enabled ? .input : .composer)

                if let referenceHub, isReferenceSourceMode {
                    if referenceHub.isPresented {
                        ReferenceHubDrawer(hub: referenceHub, commands: model.slashCommandCatalog,
                            skills: referenceSkills, agentID: referenceHub.owner?.agentID,
                            reservesResultsSpace: true)
                    }
                    if !referenceHub.selected.isEmpty || referenceHub.message != nil {
                        ReferenceDraftStrip(hub: referenceHub)
                    }
                }

                DraftAttachmentRail(model: model, leadingInset: 0)

                if !isCompactHeight { composerActions }
            }
            .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? BighelpTokens.space24 : BighelpTokens.space16)
        .padding(.vertical, isCompactHeight ? BighelpTokens.space4 : BighelpTokens.space12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        // Long editor flings must scroll text, not pull the iPad sheet closed.
        // Explicit Collapse still preserves the draft and checks recovery ownership.
        .interactiveDismissDisabled()
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification < 0.88 { collapse() }
            }
        )
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isEditorFocused = true
            isReferenceEditorFocused = true
        }
        .alert("Couldn’t Paste Image", isPresented: clipboardErrorIsPresented) {
            Button("OK", role: .cancel) { clipboardErrorMessage = nil }
        } message: {
            Text(clipboardErrorMessage ?? "Copy the image again and try pasting.")
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            cancelClipboardImport()
        }
        .onDisappear {
            cancelClipboardImport()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.expanded")
    }

    private var composerActions: some View {
        HStack(spacing: BighelpTokens.space8) {
            if onAttachmentTap != nil {
                Button(action: openAttachments) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.isComposerAttachmentInputDisabled)
                .accessibilityLabel("Attach a file")
                .accessibilityIdentifier("chat.composer.expanded.attachment")
                .disabled(model.richDraftRecovery.hasUnexportedChanges)
            }

            if !isCompactHeight { Spacer(minLength: BighelpTokens.space8) }

            AdaptiveComposerActionButton(
                action: uiV2Enabled && !model.canSend && !model.isSending ? .send : ChatComposerPrimaryAction.resolve(
                    draft: model.draft,
                    isTurnActive: model.isSending,
                                hasAttachments: model.hasDraftAttachmentActivity
                ),
                isBusy: model.isStopping || model.hasExclusiveMidSessionSubmission,
                canSend: model.canSend,
                canStop: model.canStop,
                onVoice: {},
                onSend: send,
                onStop: stop,
                defaultMidSessionBehavior: model.isMidSessionTurnLive
                    ? model.defaultMidSessionBehavior
                    : nil,
                onMidSessionSend: sendMidSession,
                            allowedMidSessionBehaviors: model.allowedMidSessionBehaviors,
                keyboardSendOptionsRequest: keyboardSendOptionsRequest
            )
        }
    }

    private var usesRichEditor: Bool {
        if referenceHub != nil && isReferenceSourceMode { return false }
        if #available(iOS 26.0, *) { return uiV2Enabled }
        return false
    }

    @ViewBuilder
    private var expandedInput: some View {
        if let referenceHub, isReferenceSourceMode {
            ReferenceComposerTextView(text: $model.draft, hub: referenceHub,
                session: referenceEditorSession ?? localReferenceEditorSession,
                focus: $isReferenceEditorFocused, isEnabled: !model.isComposerInputDisabled,
                expanded: true, onPasteImageProviders: importClipboardImages,
                onReturnKey: handleReturnKey,
                onSelectionChange: {
                    model.setMentionCursor(offset: $0)
                    guard Data(model.draft.utf8) == Data(referenceHub.source.utf8) else { return }
                    do { try model.updateReferenceDraft(source: referenceHub.source, selections: referenceHub.selected) }
                    catch { referenceHub.showMessage("The reference draft could not be saved. Keep this editor open.") }
                })
        } else if #available(iOS 26.0, *), uiV2Enabled {
            RichDraftEditor(markdown: $model.draft, isFocused: $isEditorFocused,
                            onPasteImageProviders: importClipboardImages,
                            onReturnKey: handleReturnKey,
                            recovery: model.richDraftRecovery.state,
                            onRecoveryStateChange: { model.richDraftRecovery.update($0) })
                .id(ObjectIdentifier(model))
        } else {
            ClipboardDraftTextEditor(
                text: $model.draft,
                isFocused: $isEditorFocused,
                isEnabled: !model.isComposerInputDisabled,
                onPasteImageProviders: importClipboardImages,
                onReturnKey: handleReturnKey
            )
                .accessibilityLabel("Expanded message")
                .accessibilityValue(model.draft.isEmpty ? "Empty" : model.draft)
                .accessibilityIdentifier("chat.composer.expanded.text")
        }
    }

    private var clipboardErrorIsPresented: Binding<Bool> {
        Binding(
            get: { clipboardErrorMessage != nil },
            set: { if !$0 { clipboardErrorMessage = nil } }
        )
    }

    private func importClipboardImages(_ providers: [NSItemProvider]) {
        guard !model.isComposerAttachmentInputDisabled else { return }
        clipboardImportTask?.cancel()
        clipboardErrorMessage = nil
        let targetModel = model
        let token = clipboardImportSession.begin(target: targetModel)
        clipboardImportTask = Task { @MainActor in
            do {
                let attachments = try await ClipboardImageImporter().importImages(from: providers)
                try Task.checkCancellation()
                guard clipboardImportSession.owns(token, target: targetModel) else { return }

                var addedIDs: [String] = []
                do {
                    for attachment in attachments {
                        try targetModel.addDraftAttachment(attachment)
                        addedIDs.append(attachment.id)
                    }
                } catch {
                    for id in addedIDs {
                        targetModel.removeDraftAttachment(id: id)
                    }
                    throw error
                }
            } catch is CancellationError {
                return
            } catch {
                guard clipboardImportSession.owns(token, target: targetModel) else { return }
                clipboardErrorMessage = ClipboardImageImportError.userMessage(for: error)
            }
            guard clipboardImportSession.owns(token, target: targetModel) else { return }
            clipboardImportTask = nil
        }
    }

    private func cancelClipboardImport() {
        clipboardImportSession.invalidate()
        clipboardImportTask?.cancel()
        clipboardImportTask = nil
    }

    private func collapse() {
        guard !model.richDraftRecovery.hasUnexportedChanges else { return }
        isEditorFocused = false
        isReferenceEditorFocused = false
        dismiss()
    }

    private func openAttachments() {
        guard !model.richDraftRecovery.hasUnexportedChanges else { return }
        guard let onAttachmentTap else { return }
        isEditorFocused = false
        isReferenceEditorFocused = false
        dismiss()
        Task { @MainActor in
            await Task.yield()
            onAttachmentTap()
        }
    }

    private func send() {
        guard model.canSend else { return }
        synchronizeReferenceSource()
        isEditorFocused = false
        isReferenceEditorFocused = false
        (referenceEditorSession ?? localReferenceEditorSession).dismissKeyboard()
        BighelpKeyboard.dismiss()
        if referenceHub?.selected.isEmpty == false {
            isReferenceSourceMode = true
            onSend()
            return
        }
        isEditorFocused = false
        isReferenceEditorFocused = false
        dismiss()
        onSend()
    }

    /// A hardware keyboard's Return, the same as in the message box. True means handled.
    private func handleReturnKey(_ key: ComposerReturnKey) -> Bool {
        #if targetEnvironment(macCatalyst)
        // Return picks the Skills & commands row chosen with ↑ ↓.
        if key == .plain, isReferenceSourceMode, let referenceHub, referenceHub.isPresented,
           referenceHub.keyboard.pickHighlighted() { return true }
        #endif
        switch ComposerReturnKeyAction.resolve(key, returnSends: returnSends, canSend: model.canSend,
                                               isTurnLive: model.isMidSessionTurnLive) {
        case .newLine: return false
        case .nothing: return true
        case .send: send(); return true
        case .sendOptions:
            isEditorFocused = false
            isReferenceEditorFocused = false
            (referenceEditorSession ?? localReferenceEditorSession).dismissKeyboard()
            BighelpKeyboard.dismiss()
            keyboardSendOptionsRequest += 1
            return true
        }
    }

    private func synchronizeReferenceSource() {
        guard let referenceHub, !isReferenceSourceMode else { return }
        referenceHub.receive(source: model.draft,
            selection: NSRange(location: model.draft.utf16.count, length: 0), hasMarkedText: false)
    }

    private func sendMidSession(_ behavior: MidSessionChatBehavior) {
        guard model.canSend else { return }
        synchronizeReferenceSource()
        isEditorFocused = false
        isReferenceEditorFocused = false
        (referenceEditorSession ?? localReferenceEditorSession).dismissKeyboard()
        BighelpKeyboard.dismiss()
        if referenceHub?.selected.isEmpty == false {
            isReferenceSourceMode = true
            onReferenceMidSessionSend?(behavior)
            return
        }
        isEditorFocused = false
        isReferenceEditorFocused = false
        dismiss()
        if let onReferenceMidSessionSend { onReferenceMidSessionSend(behavior) }
        else { Task { await model.sendMidSession(using: behavior) } }
    }

    private func stop() {
        guard model.canStop else { return }
        Task { await model.stop() }
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
}
