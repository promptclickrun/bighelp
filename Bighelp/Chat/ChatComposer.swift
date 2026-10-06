import Combine
import SwiftUI
import UIKit

struct ChatComposer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @Environment(\.providerUsage) private var providerUsage
    @ScaledMetric(relativeTo: .body) private var compactDraftLineHeight: CGFloat = 22
    @Bindable var model: ChatModel
    let agentName: String
    let sessionCatalog: SessionCatalogStore?
    let onAttachmentTap: (() -> Void)?
    let onVoiceTap: () -> Void
    let onFittingRailVerticalDrag: (ChatRailScrollDirection) -> Void
    let draftFocus: Binding<Bool>
    let onDismissKeyboard: () -> Void
    let onWillSend: () -> Void
    let companionAppearance: CompanionAppearance?
    let companionReaction: CompanionReaction
    let companionSizeScale: Double
    let companionIsAdventurous: Bool
    let referenceHub: ReferenceHubStore
    let referenceSkills: SkillsAndToolsStore?
    let onReferenceSend: ((ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void)?
    @State private var referenceEditorSession = ReferenceComposerEditorSession()
    @AppStorage(ChatLayoutPreferences.returnSendsKey) private var returnSends = true
    @State private var keyboardSendOptionsRequest = 0
    @State private var referenceSubmissionID: UUID?
    @State private var isDraftOverflowing = false
    @State private var presentedSheet: ChatComposerSheet?
    @State private var restoresFocusAfterExpansion = false
    @State private var presentedStatus: SessionStatusRailDestination?
    @State private var companionAdventureResetToken = 0
    @State private var clipboardImportSession = ClipboardImageImportSession()
    @State private var clipboardImportTask: Task<Void, Never>?
    @State private var clipboardErrorMessage: String?

    var body: some View {
        VStack(spacing: BighelpTokens.space4) {
            if let context = model.sessionContext, context.isCompacting {
                SessionCompactionCard(context: context)
                    .padding(.horizontal, BighelpTokens.space4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if referenceHub.isPresented, presentedSheet == nil {
                ReferenceHubDrawer(hub: referenceHub, commands: model.slashCommandCatalog,
                    skills: referenceSkills, agentID: referenceHub.owner?.agentID,
                    reservesResultsSpace: true)
                    .padding(.horizontal, BighelpTokens.space4)
            } else if !model.mentionSuggestions.isEmpty {
                MentionSuggestionsView(suggestions: model.mentionSuggestions,
                                       agents: model.agentDirectory, onSelect: selectMention)
                    .padding(.horizontal, BighelpTokens.space4)
            }

            if !referenceHub.selected.isEmpty || referenceHub.message != nil {
                ReferenceDraftStrip(hub: referenceHub)
            }

            if let reply = model.replyDraft {
                ChatReplyDraftBar(quote: reply, agentName: agentName) { model.replyDraft = nil }
                    .padding(.horizontal, BighelpTokens.space4)
                    .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            DraftAttachmentRail(model: model)
                .padding(.horizontal, BighelpTokens.space4)
                .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)

            composerFooterLayout {
                composerStatusRail
                    .fixedSize(horizontal: usesCompactEditingLayout, vertical: usesCompactEditingLayout)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                composerControlRow
                    .frame(maxWidth: horizontalSizeClass == .regular ? ChatCanvasLayout.regularLaneMaximumWidth : .infinity)
                    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
                    // On the row, not the tag: an empty tag draws nothing, so its tasks never run.
                    .task(id: model.conversationID) { await DraftAttachmentRailFixture.seed(model) }
                    #endif
                    .companionComposerAnchor(.input)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat.composer-shell")
                    .simultaneousGesture(
                        MagnifyGesture().onEnded { value in
                            if value.magnification > 1.12 { openExpandedEditor() }
                        }
                    )
            }
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(CompanionComposerAnchorPreferenceKey.self) { anchors in
            if let companionAppearance {
                CompanionComposerAdventureLayer(
                    appearance: companionAppearance,
                    reaction: companionReaction,
                    sizeScale: companionSizeScale,
                    isAdventurous: companionIsAdventurous,
                    anchors: anchors,
                    resetToken: companionAdventureResetToken
                )
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.taskDrawer)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.sessionSubagents)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.nativeSubagents)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.goalRailState)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.sessionContext)
        .animation(reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration), value: model.replyDraft)
        .onChange(of: model.taskDrawer) { _, tasks in
            if tasks == nil, presentedStatus == .tasks {
                presentedStatus = nil
            }
        }
        .onChange(of: model.sessionSubagents) { _, subagents in
            if subagents.isEmpty, model.nativeSubagents.isEmpty, model.subagentCanvases.isEmpty,
               presentedStatus == .subagents {
                presentedStatus = nil
            }
        }
        .onChange(of: model.nativeSubagents) { _, nativeSubagents in
            // A finished helper keeps its canvas; the sheet stays open to show how it ended.
            if nativeSubagents.isEmpty, model.sessionSubagents.isEmpty, model.subagentCanvases.isEmpty,
               presentedStatus == .subagents {
                presentedStatus = nil
            }
        }
        .onChange(of: model.goalRailState) { _, goal in
            if goal == nil, presentedStatus == .goal {
                presentedStatus = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
            companionAdventureResetToken &+= 1
        }
        .bighelpSheet(item: $presentedSheet, onDismiss: restoreDraftFocus) { _ in
            ExpandedDraftEditor(
                model: model,
                agentName: agentName,
                onAttachmentTap: onAttachmentTap,
                onSend: send,
                referenceHub: referenceHub,
                referenceSkills: referenceSkills,
                referenceEditorSession: referenceEditorSession,
                onReferenceMidSessionSend: sendMidSession
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(item: $presentedStatus) { destination in
            Group {
                switch destination {
                case .goal:
                    if let goal = model.goalRailState {
                        SessionGoalSheet(
                            state: goal,
                            onCommand: { command in
                                Task { await model.submitGoalCommand(command) }
                            }
                        )
                    }
                case .subagents:
                    SessionSubagentRosterSheet(model: model, sessionCatalog: sessionCatalog)
                case .tasks:
                    if let tasks = model.taskDrawer {
                        SessionTasksSheet(state: tasks)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.standard)
        }
        .alert("Couldn’t Paste Image", isPresented: clipboardErrorIsPresented) {
            Button("OK", role: .cancel) { clipboardErrorMessage = nil }
        } message: {
            Text(clipboardErrorMessage ?? "Copy the image again and try pasting.")
        }
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            cancelClipboardImport()
            referenceSubmissionID = nil
            referenceHub.resetDraft(source: model.draft, selections: model.referenceSelections)
        }
        .onChange(of: referenceHub.selected) { _, _ in publishReferenceDraft() }
        .onDisappear {
            cancelClipboardImport()
            restoresFocusAfterExpansion = false
            draftFocus.wrappedValue = false
            referenceEditorSession.dismissKeyboard()
            publishReferenceDraft()
            model.flushPersistence()
            referenceHub.suspend()
        }
    }

    /// Goal, tasks and helpers share one adaptive glass surface. The context
    /// window lives in the chat's ⋯ menu. Keep the companion's reserved landing
    /// space outside that surface.
    @ViewBuilder
    private var composerStatusRail: some View {
        // Keep the menu mounted when its action dismisses the keyboard.
        if verticalSizeClass == .compact {
            compactSessionActions
        } else {
            SessionStatusRailView(
                goal: model.goalRailState,
                subagents: nerdModeEnabled ? model.sessionSubagents : [],
                nativeSubagents: nerdModeEnabled ? model.nativeSubagents : [],
                tasks: model.taskDrawer,
                onSelect: presentStatus,
                onFittingVerticalDrag: onFittingRailVerticalDrag
            )
            .padding(.leading, horizontalSizeClass == .regular ? companionRailReservation : 0)
            .padding(.trailing, companionRailReservation)
            .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var compactSessionActions: some View {
        let items = SessionStatusRailPresentation.items(
            goal: model.goalRailState,
            subagents: nerdModeEnabled ? model.sessionSubagents : [],
            nativeSubagents: nerdModeEnabled ? model.nativeSubagents : [],
            tasks: model.taskDrawer
        )
        if !items.isEmpty || model.runtimeControls != nil {
            Menu {
                ForEach(items) { item in
                    Button {
                        presentStatus(item.kind)
                    } label: {
                        switch item.kind {
                        case .goal: Label("Goal", systemImage: "target")
                        case .subagents: Label("Subagents", systemImage: "person.2")
                        case .tasks: Label("Tasks", systemImage: "checklist")
                        }
                    }
                    .accessibilityIdentifier("chat.composer.menu.\(item.kind.rawValue)")
                }
                if let controls = model.runtimeControls {
                    let summary = ChatModelSummaryPresentation(controls: controls)
                    Button { model.requestSessionControls() } label: {
                        Label { Text(summary.modelName); Text(summary.reasoning) } icon: { Image(systemName: "cpu") }
                    }
                    .disabled(ChatRuntimeSelectionLockout.isLocked(isTurnActive: controls.isTurnActive))
                    .accessibilityIdentifier("chat.composer.menu.model")
                }
                if providerUsage?.isAvailable == true {
                    Button("Usage", systemImage: "gauge.with.dots.needle.50percent") { showProviderUsage() }
                        .accessibilityIdentifier("chat.composer.menu.provider-usage")
                }
            } label: {
                Label("Session actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(theme.incomingMessageBackground, in: .circle)
            .accessibilityIdentifier("chat.composer.session-actions")
        }
    }

    private func showProviderUsage() {
        onDismissKeyboard()
        providerUsage?.show(agentID: model.memberIDs.first ?? "default")
    }

    private var companionRailReservation: CGFloat {
        guard companionAppearance != nil else { return 0 }
        let scale = companionSizeScale.isFinite ? min(max(companionSizeScale, 0.6), 1.5) : 1
        return min(72 * CGFloat(scale), 116) + CompanionComposerPathSampler.restGap
    }

    private var showsExpandButton: Bool {
        // Keep rich editing discoverable before the draft reaches its height cap.
        !model.draft.isEmpty || isDraftOverflowing
    }

    private var usesCompactEditingLayout: Bool {
        verticalSizeClass == .compact && draftFocus.wrappedValue
    }

    private var composerFooterLayout: AnyLayout {
        usesCompactEditingLayout
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: BighelpTokens.space4))
            : AnyLayout(VStackLayout(spacing: BighelpTokens.space4))
    }

    private var composerControlRow: some View {
        // Keep one restrained row through focus changes. The UIKit editor stays
        // in the same structural position, preserving selection, marked text,
        // undo state, keyboard ownership, and the exact draft owner.
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            attachmentButton
            ZStack(alignment: .topTrailing) {
                composerInput
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: usesCompactEditingLayout ? max(44, compactDraftLineHeight) : nil)
                    .padding(.trailing, showsExpandButton ? 44 : 0)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .submitLabel(.send)
                    .disabled(model.isComposerInputDisabled)
                    .onSubmit { send() }
                if showsExpandButton {
                    Button(action: openExpandedEditor) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.bighelp(.footnote).weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand message editor")
                    .accessibilityIdentifier("chat.composer.expand")
                }
            }
            // iMessage-style field: a fixed-radius continuous shape reads as a
            // pill on one line and keeps square-ish corners as the draft grows,
            // so wrapped lines are never cut by a widening end cap. Glyphs, caret
            // and placeholder sit clear of the leading curve, and the editor is
            // clipped to the same shape so scrolled text never paints outside it.
            .padding(.leading, ComposerFieldMetrics.leadingInset)
            .padding(.trailing, ComposerFieldMetrics.trailingInset)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .background { composerInputFocusSurface }
            .clipShape(ComposerFieldMetrics.shape)
            .contentShape(ComposerFieldMetrics.shape)
            .composerGlass(ComposerFieldMetrics.shape, fill: theme.surface)
            .overlay {
                ComposerFieldMetrics.shape
                    .strokeBorder(
                        colorSchemeContrast == .increased ? theme.primaryText : theme.border,
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .background {
                // Geometry marker for the visible field; not an accessibility container.
                Color.clear.accessibilityElement().accessibilityIdentifier("chat.composer.field")
            }
            primaryAction
        }
        .padding(.vertical, 4)
        .background {
            // Geometry marker for the whole control row. A marker survives the
            // glass container flattening that drops identifiers on the HStack.
            Color.clear.accessibilityElement().accessibilityIdentifier("chat.composer.editing-controls")
        }
    }

    @ViewBuilder
    private var attachmentButton: some View {
        if let onAttachmentTap {
            Button(action: onAttachmentTap) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: ComposerFieldMetrics.controlDiameter, height: ComposerFieldMetrics.controlDiameter)
                    .composerGlass(Circle(), fill: theme.incomingMessageBackground)
                    // Match the primary action's outer hit area as well as its
                    // painted circle, so both ends share the same center line.
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.bighelpPress)
            .accessibilityLabel("Attachments and actions")
            .accessibilityHint("Choose camera, photo, file, voice, or chat actions.")
            .accessibilityIdentifier("chat.attachment")
            .bighelpChatPanelAnchor(.attachments)
            .disabled(model.isComposerAttachmentInputDisabled)
        }
    }

    private var primaryAction: some View {
        AdaptiveComposerActionButton(
            action: ChatComposerPrimaryAction.resolve(draft: model.draft, isTurnActive: model.isSending, hasAttachments: model.hasDraftAttachmentActivity),
            isBusy: model.isStopping || model.hasExclusiveMidSessionSubmission,
            canSend: model.canSend, canStop: model.canStop,
            onVoice: onVoiceTap, onSend: send, onStop: stop,
            defaultMidSessionBehavior: model.isMidSessionTurnLive ? model.defaultMidSessionBehavior : nil,
            onMidSessionSend: sendMidSession,
            allowedMidSessionBehaviors: model.allowedMidSessionBehaviors,
            unavailableReason: model.sendUnavailableReason,
            keyboardSendOptionsRequest: keyboardSendOptionsRequest,
            onKeyboardSendOptionsClosed: { draftFocus.wrappedValue = true }
        )
        .disabled(model.isAwaitingAuthoritativeSessionAllocation)
    }

    private var composerInputFocusSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                guard !model.isComposerInputDisabled else { return }
                draftFocus.wrappedValue = true
            }
            .accessibilityHidden(true)
    }

    private var composerInput: some View {
        regularDraftInput
            .id("chat.composer.editor")
    }

    @ViewBuilder
    private var regularDraftInput: some View {
        // UIKit provides the same native selection surface on every supported
        // OS version, and avoids maintaining two divergent composer layouts.
        ReferenceComposerTextView(
            text: composerText,
            hub: referenceHub,
            session: referenceEditorSession,
            focus: draftFocus,
            isEnabled: !model.isComposerInputDisabled,
            isSurfaceActive: presentedSheet == nil,
            viewportHeight: usesCompactEditingLayout ? max(44, compactDraftLineHeight) : nil,
            onPasteImageProviders: importClipboardImages,
            onReturnKey: handleReturnKey,
            onSelectionChange: reportComposerSelection,
            onExpansionAvailabilityChange: { isDraftOverflowing = $0 }
        )
        .overlay(alignment: .topLeading) {
            if composerText.wrappedValue.isEmpty {
                Text("Message \(placeholderName)")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Message")
        .accessibilityValue(composerText.wrappedValue.isEmpty ? "Empty" : composerText.wrappedValue)
    }

    private var placeholderName: String {
        guard model.isBotMode else { return agentName }
        let title = model.botModeRoomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "group" : title
    }

    private var composerText: Binding<String> {
        Binding(
            get: { model.draft },
            set: { model.draft = $0 }
        )
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

    private func reportComposerSelection(_ offset: Int?) {
        model.setMentionCursor(offset: offset)
        publishReferenceDraft()
    }

    private func publishReferenceDraft() {
        guard Data(model.draft.utf8) == Data(referenceHub.source.utf8) else { return }
        do { try model.updateReferenceDraft(source: referenceHub.source, selections: referenceHub.selected) }
        catch { referenceHub.showMessage("The reference draft could not be saved. Keep this chat open and retry.") }
    }

    private func restoreDraftFocus() {
        guard restoresFocusAfterExpansion else { return }
        restoresFocusAfterExpansion = false
        draftFocus.wrappedValue = true
    }

    private func send() {
        submit(behavior: nil)
    }

    /// A hardware keyboard's Return (`ComposerReturnKeyAction`). True means handled.
    private func handleReturnKey(_ key: ComposerReturnKey) -> Bool {
        #if targetEnvironment(macCatalyst)
        // Return picks the Skills & commands row chosen with ↑ ↓.
        if key == .plain, referenceHub.isPresented, presentedSheet == nil,
           referenceHub.keyboard.pickHighlighted() { return true }
        #endif
        switch ComposerReturnKeyAction.resolve(key, returnSends: returnSends, canSend: model.canSend,
                                               isTurnLive: model.isMidSessionTurnLive) {
        case .newLine: return false
        case .nothing: return true
        case .send: submit(behavior: nil, keepsFocus: true); return true
        case .sendOptions:
            // The choices take the keys next (1–3, Return), not the message box.
            dismissComposerKeyboard()
            keyboardSendOptionsRequest += 1
            return true
        }
    }

    private func sendMidSession(_ behavior: MidSessionChatBehavior) {
        submit(behavior: behavior)
    }

    /// `keepsFocus`: sent with a keyboard's Return, so the message box stays
    /// ready for the next message (Mac, iPad with a keyboard).
    private func submit(behavior: MidSessionChatBehavior?, keepsFocus: Bool = false) {
        guard model.canSend else { return }
        if !keepsFocus { dismissComposerKeyboard() }
        if !referenceHub.selected.isEmpty {
            // A reference send keeps its exact reviewed bytes, so a quote line can't ride along.
            guard model.replyDraft == nil else {
                referenceHub.showMessage("A reply can't include references yet. Cancel the reply or remove the references.")
                return
            }
            prepareReferenceSend(behavior: behavior)
            return
        }
        onWillSend()
        Task {
            if let behavior { await model.sendMidSession(using: behavior) }
            else { await model.send() }
        }
    }

    private func stop() {
        guard model.canStop else { return }
        Task { await model.stop() }
    }

    private func prepareReferenceSend(behavior: MidSessionChatBehavior?) {
        guard !referenceHub.isPreparingSend, referenceSubmissionID == nil else { return }
        guard let onReferenceSend else {
            referenceHub.showMessage("Reference sending is not connected for this chat. Remove references to send ordinary text.")
            return
        }
        let target = model
        Task { @MainActor in
            let preparation = await referenceHub.prepareSend()
            guard case .ready(let frozen) = preparation,
                  referenceHub.owns(frozen), model === target,
                  Data(target.draft.utf8) == Data(frozen.routingSource.utf8) else { return }
            guard referenceSubmissionID == nil else { return }
            referenceSubmissionID = frozen.submissionID
            defer {
                if referenceSubmissionID == frozen.submissionID { referenceSubmissionID = nil }
            }
            // Parent owns the actual submission, envelope bounds, acceptance and
            // ambiguous receipt reconciliation. This never calls model.send().
            onWillSend()
            await onReferenceSend(frozen, behavior)
        }
    }

    private func openExpandedEditor() {
        referenceEditorSession.prepareForSurfaceTransfer()
        restoresFocusAfterExpansion = true
        draftFocus.wrappedValue = false
        BighelpKeyboard.dismiss()
        presentedSheet = .expandedDraft
    }

    private func dismissComposerKeyboard() {
        onDismissKeyboard()
        restoresFocusAfterExpansion = false
        draftFocus.wrappedValue = false
        referenceEditorSession.dismissKeyboard()
        BighelpKeyboard.dismiss()
    }

    private func presentStatus(_ kind: SessionStatusRailKind) {
        draftFocus.wrappedValue = false
        BighelpKeyboard.dismiss()
        switch kind {
        case .goal:
            presentedStatus = .goal
        case .subagents:
            presentedStatus = .subagents
        case .tasks:
            presentedStatus = .tasks
        }
    }

    private func selectMention(_ suggestion: MentionSuggestion) {
        let token = model.mentionToken ?? "@"
        do {
            switch suggestion.kind {
            case .everyone:
                model.insertMention(handle: suggestion.handle, replacing: token)
            case .member, .outsideAgent:
                guard let agentID = suggestion.agentID else { return }
                try model.selectMention(agentID: agentID, replacing: token)
            }
        } catch {
            // The suggestion list is derived from the current roster. If a concurrent
            // roster mutation wins first, the next draft edit refreshes it.
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
}

private struct SessionCompactionCard: View {
    let context: SessionContextSnapshot

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            BighelpThinkingOrb(scenario: .shaping, scale: .inline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Compacting context")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                Text(SessionContextPresentation.summary(for: context))
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: horizontalSizeClass == .regular ? 420 : .infinity, alignment: .center)
        .bighelpSurface(.capsuleControl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compacting chat context")
        .accessibilityValue(SessionContextPresentation.summary(for: context))
        .accessibilityIdentifier("chat.session-context-compacting")
    }

    @BighelpThemeReader private var theme: BighelpTheme

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
}

private enum ChatComposerSheet: String, Identifiable {
    case expandedDraft

    var id: String { rawValue }
}

/// Geometry for the composer's text field. The leading inset equals the
/// continuous corner's visual footprint at single-line height so the first
/// glyph and the placeholder never touch the curve.
enum ComposerFieldMetrics {
    static var cornerRadius: CGFloat { BighelpTokens.scaled(24) }
    /// Painted diameter of the attach and send circles; hit areas stay at the hit target.
    static var controlDiameter: CGFloat { BighelpTokens.scaled(36) }
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
}

/// The message box, + and the voice button: Liquid Glass tinted with their usual fill, so the chat
/// behind shows through faintly but text stays easy to read. Reduce Transparency, systems before
/// iOS 26 and visionOS (no glassEffect) keep the solid fill.
private struct ComposerGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        #if compiler(>=6.2) && !os(visionOS)
        if #available(iOS 26, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular.tint(fill.opacity(0.72)), in: shape)
        } else {
            content.background(shape.fill(fill))
        }
        #else
        content.background(shape.fill(fill))
        #endif
    }
}

extension View {
    func composerGlass<S: InsettableShape>(_ shape: S, fill: Color) -> some View {
        modifier(ComposerGlass(shape: shape, fill: fill))
    }
}
