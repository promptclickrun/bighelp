import SwiftUI

struct ChatActionMenuSheet: View {
    let agentName: String
    let agentID: String
    let sessionID: String
    let currentModelName: String
    let isCameraAvailable: Bool
    let agents: AgentDirectoryStore
    let runtimeControls: SessionRuntimeControlModel?
    let slashCommandCatalog: () -> SlashCommandCatalogModel?
    let skillsAndTools: SkillsAndToolsStore
    let workspaces: HermesWorkspaceStore
    let onSelect: (ChatActionMenuAction) -> Void
    let onChooseAgent: (AgentProfile) -> DirectChatAgentSelectionResult
    let onSelectSlashCommand: (SlashCommandDescriptor) -> Void
    var allowsImages = true
    var allowsFiles = true
    var onNativeSessionControls: (() -> Void)? = nil

    @State private var page: ChatActionMenuPage = .main
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @State private var isModelPickerPresented = false
    @State private var agentSelectionErrorMessage: String?
    @State private var capabilitySelectionErrorMessage: String?
    @State private var capabilityQuery = ""
    @State private var selectedAgentID: String?
    @State private var selectedAgentName: String?
    @State private var isCapabilityManagerPresented = false
    @State private var pdfPagesPickerTarget: ChatPDFPagesPickerTarget?

    private var actionScrollContent: some View {
        ScrollView {
            pageContent
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.top, BighelpTokens.space8)
                .padding(.bottom, BighelpTokens.space24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var drawerSurface: some View {
        if page == .main {
            actionList
        } else {
            actionScrollContent.background(Color.clear)
        }
    }

    var body: some View {
        NavigationStack {
            drawerSurface
                .navigationTitle(pageTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if page != .main {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Add to chat", systemImage: "chevron.left") { page = .main }
                                .bighelpToolbarText()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(theme.action)
                            .bighelpToolbarText()
                            .accessibilityIdentifier("chat.action-drawer.done")
                            #if targetEnvironment(macCatalyst)
                            .keyboardShortcut(.cancelAction)
                            #endif
                    }
                }
        }
        .environment(\.bighelpUIV3Enabled, true)
        .environment(\.bighelpUIV2Enabled, true)
        // Warm Ember surfaces in both appearances instead of a gray material.
        .presentationBackground(theme.canvas)
        .tint(theme.primaryText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.action-drawer.surface")
        .task(id: page) {
            guard page == .skillsAndTools else { return }
            await slashCommandCatalog()?.load()
        }
        .task(id: page) {
            switch page {
            case .skillsAndTools:
                await skillsAndTools.load(agentID: effectiveAgentID)
            case .workspaces:
                await workspaces.load(
                    agentID: effectiveAgentID,
                    sessionID: sessionID
                )
            case .modelAndReasoning:
                await runtimeControls?.loadPickersIfNeeded()
            case .main, .agents:
                break
            }
        }
        .bighelpSheet(isPresented: $isCapabilityManagerPresented) {
            NavigationStack {
                SkillsAndToolsCatalogView(store: skillsAndTools, agentID: effectiveAgentID)
                    #if targetEnvironment(macCatalyst)
                    // A Mac sheet can't be swiped away.
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { isCapabilityManagerPresented = false }
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("chat.skills-tools.done")
                                .bighelpToolbarText()
                        }
                    }
                    #endif
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.large)
        }
        .bighelpSheet(item: $pdfPagesPickerTarget) { picker in
            pdfPagesPicker(picker)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.large)
        }
        .bighelpSheet(isPresented: $isModelPickerPresented) {
            if let controls = runtimeControls {
                BighelpModelPickerSheet(
                    title: "Choose model",
                    scopeLabel: "This chat only",
                    providers: controls.modelProviders,
                    currentProviderID: controls.currentProvider,
                    currentModelID: controls.currentModel,
                    isLoading: controls.isLoadingModel,
                    isApplying: controls.isApplyingSelection,
                    errorMessage: controls.errorMessage,
                    onClearError: controls.clearError,
                    onRetry: {
                        Task { await controls.loadPickersIfNeeded() }
                    },
                    onSelect: { _, _ in },
                    reasoningOptions: controls.reasoningOptions,
                    currentReasoningValue: controls.currentReasoningValue,
                    onApply: { draft in applySelection(controls, draft: draft) }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .main:
            actionList
        case .agents:
            agentsPage
        case .skillsAndTools:
            skillsAndPluginsPage
        case .modelAndReasoning:
            // Retained page identity for fixture compatibility; model selection uses its sheet.
            actionList
        case .workspaces:
            HermesWorkspaceManagerContent(
                store: workspaces,
                agentID: effectiveAgentID,
                sessionID: sessionID
            ) {
                page = .main
            }
        }
    }

    /// The shipping attachment sheet uses a native list. Every existing
    /// callback remains direct; rows that open an in-sheet destination retain
    /// their current page owner and all media availability gates.
    private var actionList: some View {
        List {
            if !allowsImages {
                Section {
                    Text(allowsFiles ? DirectHermesFileAttachments.imagesUnavailable
                         : "Attachments are unavailable on this connection.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat.attachments.images-unavailable")
                }
            }

            Section("Add") {
                ForEach(ChatActionMenuLayout.mediaActions + [.voice]) { action in
                    nativeActionRow(action)
                }
                nativeActionRow(.scanDocument)
                nativePDFPagesRow
            }
            .listRowBackground(theme.surface)

            Section("Chat") {
                // Skills and the Hermes project folder are host tools: Nerd Mode only.
                ForEach(nerdModeEnabled
                    ? [ChatActionMenuAction.chooseAgent, .changeModel, .skillsAndTools, .workspace, .startSession]
                    : [ChatActionMenuAction.chooseAgent, .changeModel, .startSession]
                ) { action in
                    nativeActionRow(action)
                }
            }
            .listRowBackground(theme.surface)

            if nerdModeEnabled, let onNativeSessionControls {
                Section("Session") {
                    Button(action: onNativeSessionControls) {
                        Label("Session controls", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    #if targetEnvironment(macCatalyst)
        .bighelpPointerButtonStyle(.borderless)
        #endif
                    .accessibilityIdentifier("chat.composer.menu.native-session-controls")
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .accessibilityIdentifier("chat.action-drawer.v3")
    }

    private func nativeActionRow(_ action: ChatActionMenuAction) -> some View {
        Button { open(action) } label: {
            actionLabel(
                title: action == .voice ? "Voice mode" : rowTitle(for: action).isEmpty
                    ? mediaTitle(for: action) : rowTitle(for: action),
                detail: actionDetail(action),
                symbol: action == .voice ? "waveform" : symbol(for: action),
                tint: action == .voice ? AnyShapeStyle(theme.action) : AnyShapeStyle(.secondary)
            )
        }
        #if targetEnvironment(macCatalyst)
        .bighelpPointerButtonStyle(.borderless)
        #endif
        .disabled(unavailableReason(action) != nil || !ChatActionMenuAvailability.isEnabled(
            action,
            hasRuntimeControls: runtimeControls != nil,
            isTurnActive: runtimeControls?.isTurnActive == true
        ))
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .accessibilityHint(action == .changeModel
            ? ChatRuntimeSelectionLockout.accessibilityHint(isTurnActive: runtimeControls?.isTurnActive == true)
            : unavailableReason(action) ?? "")
    }

    private var nativePDFPagesRow: some View {
        Button(action: openPDFPages) {
            actionLabel(
                title: "PDF as pages",
                detail: pdfPagesAvailability.unavailableReason
                    ?? "Render up to 25 selected pages for image understanding",
                symbol: "doc.richtext"
            )
        }
        #if targetEnvironment(macCatalyst)
        .bighelpPointerButtonStyle(.borderless)
        #endif
        .disabled(pdfPagesAvailability.unavailableReason != nil)
        .accessibilityIdentifier("chat.action.pdf-pages")
        .accessibilityHint(pdfPagesAvailability.unavailableReason ?? "")
    }

    private func actionLabel(
        title: String,
        detail: String,
        symbol: String,
        tint: AnyShapeStyle = AnyShapeStyle(.secondary)
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(title).foregroundStyle(.primary)
                Text(detail)
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
    }

    private func actionDetail(_ action: ChatActionMenuAction) -> String {
        switch action {
        case .camera, .photo, .file:
            return unavailableReason(action) ?? "Add from \(mediaTitle(for: action).lowercased())"
        case .voice:
            return "Talk with \(agentName)"
        case .changeModel:
            return runtimeControls?.modelDisplayName
                ?? ModelNameCatalogStore.shared.displayName(for: currentModelName)
        default:
            return rowSubtitle(for: action)
        }
    }

    private func unavailableReason(_ action: ChatActionMenuAction) -> String? {
        switch action {
        case .camera, .photo, .file:
            return mediaUnavailableReason(action)
        default:
            return rowUnavailableReason(action)
        }
    }

    private var pageTitle: String {
        switch page {
        case .main: "Add to chat"
        case .agents: "Choose agent"
        case .skillsAndTools: "Skills & Plugins"
        case .modelAndReasoning: "Model & reasoning"
        case .workspaces: "Workspace"
        }
    }

    private func mediaTitle(for action: ChatActionMenuAction) -> String {
        switch action {
        case .camera: "Camera"
        case .photo: "Photo"
        case .file: "File"
        default: ""
        }
    }

    private func mediaUnavailableReason(_ action: ChatActionMenuAction) -> String? {
        if action == .file, !allowsFiles { return "Attachments are unavailable on this connection." }
        if !allowsImages, action == .camera || action == .photo { return DirectHermesFileAttachments.imagesUnavailable }
        if action == .camera, !isCameraAvailable { return "Camera capture is unavailable on this device." }
        return nil
    }

    private func rowTitle(for action: ChatActionMenuAction) -> String {
        switch action {
        case .scanDocument: "Scan document"
        case .voice: "Voice mode"
        case .startSession: "New chat"
        case .chooseAgent: "Choose agent"
        case .skillsAndTools: "Skills & Plugins"
        case .workspace: "Workspace"
        case .changeModel: "Change model"
        default: ""
        }
    }

    private func rowSubtitle(for action: ChatActionMenuAction) -> String {
        switch action {
        case .scanDocument: scannerUnavailableReason ?? "Scan paper pages into a PDF attachment"
        case .voice: "Talk with \(agentName)"
        case .startSession: "Start fresh with \(effectiveAgentName)"
        case .chooseAgent: "\(effectiveAgentName) is active for this chat"
        case .skillsAndTools: "Capabilities on this Hermes host"
        case .workspace: activeWorkspaceName
        case .changeModel: currentModelName
        default: ""
        }
    }

    private func symbol(for action: ChatActionMenuAction) -> String {
        switch action {
        case .camera: "camera"
        case .photo: "photo"
        case .file: "doc"
        case .scanDocument: "doc.viewfinder"
        case .voice: "waveform"
        case .startSession: "square.and.pencil"
        case .chooseAgent: "person.crop.circle.badge.checkmark"
        case .skillsAndTools: "briefcase"
        case .changeModel: "cpu"
        case .workspace: "square.stack.3d.up"
        }
    }

    private var pdfPagesAvailability: ChatPDFPagesAttachmentAvailability {
        guard let model = ChatPDFPagesDraftRegistry.model(for: sessionID),
              ChatPDFPagesDraftRegistry.owns(model, sessionID: sessionID) else {
            return .unavailable(reason: "Open this action from the current native conversation.")
        }
        return model.pdfPagesAvailability
    }

    private func openPDFPages() {
        guard pdfPagesAvailability == .available,
              let model = ChatPDFPagesDraftRegistry.model(for: sessionID),
              ChatPDFPagesDraftRegistry.owns(model, sessionID: sessionID),
              let target = model.pdfAttachmentTarget else { return }
        pdfPagesPickerTarget = ChatPDFPagesPickerTarget(
            sessionID: sessionID,
            target: target
        )
    }

    @ViewBuilder
    private func pdfPagesPicker(_ picker: ChatPDFPagesPickerTarget) -> some View {
        if let model = ChatPDFPagesDraftRegistry.model(for: picker.sessionID),
           ChatPDFPagesDraftRegistry.owns(model, sessionID: picker.sessionID),
           model.pdfAttachmentTarget == picker.target {
            ChatPDFPagesAttachmentView(
                target: picker.target,
                isCurrent: { candidate in
                    ChatPDFPagesDraftRegistry.owns(model, sessionID: picker.sessionID)
                        && model.pdfAttachmentTarget == candidate
                },
                onAddToDraft: { selection in
                    guard ChatPDFPagesDraftRegistry.owns(model, sessionID: picker.sessionID),
                          model.pdfAttachmentTarget == selection.target,
                          selection.target == picker.target else {
                        throw DirectHermesPDFAttachmentError.targetChanged
                    }
                    try model.addPDFPageSelection(selection)
                }
            )
        } else {
            NavigationStack {
                ContentUnavailableView(
                    "Conversation changed",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Close this picker and reopen PDF pages from the current native conversation.")
                )
                .navigationTitle("PDF as pages")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var scannerUnavailableReason: String? {
        if !allowsFiles { return "Attachments are unavailable on this connection." }
        return ChatDocumentScanner.isSupported ? nil : "Document scanning requires a supported camera device."
    }

    private func rowUnavailableReason(_ action: ChatActionMenuAction) -> String? {
        switch action {
        case .scanDocument:
            scannerUnavailableReason
        default:
            nil
        }
    }

    private func open(_ action: ChatActionMenuAction) {
        if rowUnavailableReason(action) != nil { return }
        if action == .changeModel {
            guard let controls = runtimeControls else { return }
            guard !ChatRuntimeSelectionLockout.isLocked(
                isTurnActive: controls.isTurnActive
            ) else { return }
            Task {
                await controls.loadPickersIfNeeded()
                isModelPickerPresented = true
            }
            return
        }
        if let submenu = action.submenu {
            page = submenu
        } else {
            onSelect(action)
        }
    }

    private func applySelection(
        _ controls: SessionRuntimeControlModel,
        draft: SessionRuntimeSelectionDraft
    ) {
        Task {
            await controls.apply(draft)
            guard controls.errorMessage == nil else { return }
            await controls.loadModelPicker()
            guard controls.errorMessage == nil else { return }
            await controls.loadReasoningPicker()
            guard controls.errorMessage == nil else { return }
            isModelPickerPresented = false
            page = .main
        }
    }

    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            LazyVStack(spacing: BighelpTokens.space4) {
                ForEach(agents.profiles) { agent in
                    Button {
                        let transition = ChatActionMenuAgentSelectionTransition.resolve(
                            onChooseAgent(agent)
                        )
                        if transition.errorMessage == nil {
                            selectedAgentID = agent.id
                            selectedAgentName = agent.name
                        }
                        agentSelectionErrorMessage = transition.errorMessage
                        page = transition.page
                    } label: {
                        HStack(spacing: BighelpTokens.space12) {
                            AvatarView(
                                stableID: agent.id,
                                displayName: agent.name,
                                imageURL: agents.avatarURL(for: agent),
                                size: 38
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .bighelpFont(.label, weight: .semibold)
                                Text(agent.id == effectiveAgentID
                                    ? "Current chat agent"
                                    : "Use for this chat")
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            if agent.id == effectiveAgentID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.action)
                            }
                        }
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                }
            }
            if let agentSelectionErrorMessage {
                Label(agentSelectionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var skillsAndPluginsPage: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Button {
                isCapabilityManagerPresented = true
            } label: {
                Label("Manage skills & tools", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpActionStyle()
            .tint(theme.action)
            .accessibilityIdentifier("chat.skills-tools.manage")
            BighelpSearchField(
                text: $capabilityQuery,
                prompt: "Search skills & plugins",
                accessibilityLabel: "Search skills and plugins"
            )

            if skillsAndTools.isLoading, skillsAndTools.catalog == nil {
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading skills and plugins"
                )
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if let catalog = skillsAndTools.catalog, catalog.agentID == effectiveAgentID {
                let entries = ChatSkillsAndPluginsIndex(catalog: catalog).entries(query: capabilityQuery)
                if entries.isEmpty {
                    ContentUnavailableView.search(text: capabilityQuery)
                } else {
                    LazyVStack(spacing: BighelpTokens.space4) {
                        ForEach(entries) { entry in
                            Button {
                                selectCapability(entry)
                            } label: {
                                catalogRow(
                                    title: entry.name,
                                    detail: entry.detail,
                                    symbol: entry.kind == .skill ? "sparkles" : "puzzlepiece.extension"
                                )
                            }
                            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                            .disabled(!entry.isEnabled || slashCommandCatalog()?.isLoading == true)
                            .accessibilityIdentifier("chat.skills-plugins.\(entry.kind == .skill ? "skill" : "plugin").\(entry.id)")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Skills and plugins unavailable",
                    systemImage: "shippingbox",
                    description: Text(skillsAndTools.errorMessage ?? "Connect to the selected Hermes host and try again.")
                )
            }

            if let capabilitySelectionErrorMessage {
                Label(capabilitySelectionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func selectCapability(_ entry: ChatSkillsAndPluginsEntry) {
        guard let command = ChatCapabilitySlashCommandResolver.command(
            for: entry,
            commands: slashCommandCatalog()?.commands ?? []
        ) else {
            capabilitySelectionErrorMessage = "This capability does not expose a matching chat command."
            return
        }
        onSelectSlashCommand(command)
        capabilitySelectionErrorMessage = nil
        page = .main
    }

    private func catalogRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bighelpFont(.label, weight: .semibold)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.bighelp(.caption).weight(.bold))
                .foregroundStyle(theme.tertiaryText)
        }
        .foregroundStyle(theme.primaryText)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(.rect)
    }

    private var activeWorkspaceName: String {
        HermesWorkspaceSelectionPresentation.selectedName(
            store: workspaces,
            sessionID: sessionID
        ) ?? "Choose a Hermes Workspace"
    }

    private var effectiveAgentID: String {
        selectedAgentID ?? agentID
    }

    private var effectiveAgentName: String {
        selectedAgentName ?? agentName
    }

    @BighelpThemeReader private var theme: BighelpTheme
}
