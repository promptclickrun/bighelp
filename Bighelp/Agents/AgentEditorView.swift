import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct AgentEditorView: View {
    private enum Destination: Hashable {
        case advanced
    }

    @State private var model: AgentEditorModel
    @State private var navigationPath: [Destination]
    @State private var runtimeDefaultsModel: AgentRuntimeDefaultsEditorModel?
    @State private var modelPickerScope: AgentRuntimeScope?
    @State private var photoSelection: PhotosPickerItem?
    @State private var avatarPreparationTask: Task<Void, Never>?
    @State private var avatarPreparationID: UUID?
    @State private var expandsInstructions = false
    @State private var avatarPreparationLabel: String?
    @State private var isDiscardConfirmationPresented = false
    @State private var isModelConfirmationPresented = false
    @State private var pendingCompletedProfile: AgentProfile?
    @State private var isAvatarCreatorPresented = false
    /// A new agent's first look in the creator, picked once per editor.
    @State private var surpriseLook = AvatarCreatorModel.surprise()
    @FocusState private var focusedField: AgentEditorModel.Field?
    @Environment(\.dismiss) private var dismiss

    let onCompleted: (AgentProfile) -> Void
    let runtimeDefaultsReadOnlyReason: String?

    init(
        model: AgentEditorModel,
        runtimeDefaultsClient: (any AgentRuntimeDefaultsClient)? = nil,
        runtimeDefaultsReadOnlyReason: String? = nil,
        initiallyShowsAdvanced: Bool = false,
        onCompleted: @escaping (AgentProfile) -> Void
    ) {
        _model = State(initialValue: model)
        _navigationPath = State(initialValue: initiallyShowsAdvanced ? [.advanced] : [])
        if let agentID = model.editingAgentID, let runtimeDefaultsClient {
            _runtimeDefaultsModel = State(initialValue: AgentRuntimeDefaultsEditorModel(
                agentID: agentID,
                client: runtimeDefaultsClient
            ))
        } else {
            _runtimeDefaultsModel = State(initialValue: nil)
        }
        self.onCompleted = onCompleted
        self.runtimeDefaultsReadOnlyReason = runtimeDefaultsReadOnlyReason
    }

    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    private var templateLibrary: AgentTemplateLibrary { .shared }
    @Environment(\.agentDeletion) private var agentDeletion
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var templateNotice: String?

    /// Asked for after the confirmation; the editor closes once Hermes confirms.
    private func delete(_ agent: AgentProfile) {
        guard let agentDeletion else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                try await agentDeletion.run(agent.id)
                dismiss()
            } catch {
                deleteError = AgentDeletionPresentation.errorMessage(error)
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $navigationPath) {
            Form {
                identitySection(
                    model: model,
                    name: $model.draft.name,
                    role: $model.draft.role,
                    summary: $model.draft.summary
                )
                instructionsSection(model: model, instructions: $model.draft.instructions)
                    .onChange(of: model.draft.name) { _, _ in model.nameDidChange() }
                if let defaults = runtimeDefaultsModel {
                    AgentRuntimeDefaultsSection(
                        model: defaults,
                        allowsEdits: runtimeDefaultsReadOnlyReason == nil,
                        scopes: [.mainChats],
                        modelPickerScope: $modelPickerScope
                    )
                }
                if let reason = runtimeDefaultsReadOnlyReason {
                    Section {
                        Label(reason, systemImage: "lock")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    } header: {
                        if runtimeDefaultsModel == nil { AgentStudioCaption("Model") }
                    }
                    .listRowBackground(theme.surface)
                }
                // Handles, subagent models, clone sources and bundled skills are
                // host details: the Advanced route appears only with Nerd Mode on.
                if nerdModeEnabled || model.fieldErrors[.cloning] != nil {
                Section {
                    if nerdModeEnabled {
                    NavigationLink(value: Destination.advanced) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced")
                                    .foregroundStyle(theme.primaryText)
                                Text(!model.isEditing
                                     ? "Setup to copy, bundled skills, mention handle"
                                     : runtimeDefaultsModel == nil
                                        ? "Mention handle"
                                        : "Subagent and task models, mention handle")
                                    .font(.bighelp(.footnote))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .accessibilityIdentifier("agent.editor.advanced")
                    }
                    if let error = model.fieldErrors[.cloning] { recoveryMessage(error) }
                }
                .listRowBackground(theme.surface)
                }
                if let saveError = model.saveError {
                    Section { recoveryMessage(saveError) }
                        .listRowBackground(theme.surface)
                }
                if let agent = model.editedProfile {
                    Section {
                        Button {
                            let template = templateLibrary.save(from: AgentProfile(
                                id: agent.id, name: model.draft.name, role: model.draft.role,
                                summary: model.draft.summary, instructions: model.draft.instructions,
                                avatarFileName: model.draft.avatarFileName, avatar: model.draft.avatar,
                                isDefault: agent.isDefault))
                            templateNotice = "“\(template.title)” is saved on this device. To use it, create an agent and choose My templates."
                        } label: {
                            Label("Save as Template", systemImage: "square.and.arrow.down.on.square")
                                .frame(minHeight: BighelpTokens.hitTarget)
                        }
                        .accessibilityIdentifier("agent.editor.save-template")
                        if agentDeletion != nil, AgentDeletionPresentation.canDelete(agent) {
                            Button(role: .destructive) {
                                isDeleteConfirmationPresented = true
                            } label: {
                                HStack {
                                    Label("Delete Agent", systemImage: "trash")
                                    Spacer()
                                    if isDeleting { ProgressView() }
                                }
                                .frame(minHeight: BighelpTokens.hitTarget)
                            }
                            .disabled(isDeleting)
                            .accessibilityIdentifier("agent.editor.delete")
                        }
                    }
                    .listRowBackground(theme.surface)
                    .confirmationDialog(AgentDeletionPresentation.title(agent), isPresented: $isDeleteConfirmationPresented,
                                        titleVisibility: .visible) {
                        Button("Delete Agent", role: .destructive) { delete(agent) }
                            .accessibilityIdentifier("agent.editor.delete.confirm")
                    } message: {
                        Text(AgentDeletionPresentation.message(agent))
                    }
                }
            }
            .disabled(isSaving || isDeleting)
            .alert("Template saved", isPresented: Binding(get: { templateNotice != nil }, set: { if !$0 { templateNotice = nil } })) {
            } message: {
                Text(templateNotice ?? "")
            }
            .alert("Couldn't delete this agent", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            } message: {
                Text(deleteError ?? "")
            }
            .scrollContentBackground(.hidden)
            .dismissesKeyboardOnScroll(true)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(model.isEditing ? "Edit Agent" : "Agent Studio")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .advanced:
                    advancedForm(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestDismissal)
                        .frame(minHeight: BighelpTokens.toolbarHitTarget)
                        .disabled(isSaving)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("agent.editor.cancel")
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isEditing ? "Save" : "Create", action: saveAgent)
                    .fontWeight(.semibold)
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .disabled(isSaving || model.hasUnconfirmedSave || avatarPreparationID != nil)
                    .accessibilityLabel(model.isEditing ? "Save agent" : "Create agent")
                    .accessibilityIdentifier("agent.editor.save")
                }
                #if !os(visionOS) // Vision Pro's keyboard has its own dismiss key.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityLabel("Dismiss keyboard")
                }
                #endif
            }
        }
        // Always a sheet (Agents, chat, home), so every opening gets the studio's size on the Mac.
        .bighelpSheetSize(.large)
        // Starts once for the whole editor, including Advanced. See loadIfNeeded().
        .task { await runtimeDefaultsModel?.loadIfNeeded() }
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .focusedTextEditor(
            isPresented: $expandsInstructions,
            title: "Instructions",
            text: $model.draft.instructions,
            placeholder: instructionsPlaceholder,
            identifier: "agent.editor.instructions.expand",
            onSave: canSaveAgent ? { saveAgent() } : nil
        )
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            preparePhotoAvatar(selection)
        }
        .sheet(isPresented: $isAvatarCreatorPresented) {
            AvatarCreatorView(
                appearance: creatorStartLook, look: creatorStartHermesLook, agentName: heroTitle,
                faceName: model.faceName,
                petSource: PetdexSource(store: model.store, cacheScope: "\(ObjectIdentifier(model.store))")
            ) { result in
                switch result {
                case .companion(let look): prepareCompanionAvatar(look)
                case .look(let look): prepareLookAvatar(look)
                case .pet(let pet, let avatar): preparePetAvatar(pet, data: avatar)
                case .photo(let item): photoSelection = item
                }
            }
            .presentationDragIndicator(.visible)
            #if os(visionOS)
            // Wide enough for the 3D character beside the choices.
            .presentationSizing(.page)
            #endif
            // The Mac: wide enough for the character beside the choices.
            .bighelpSheetSize(.large)
        }
        .agentTemplateForm(model)
        // Modal ownership must outlive the lazy sections while a picker is presented.
        .sheet(item: $modelPickerScope) { scope in
            if let defaults = runtimeDefaultsModel {
                agentModelPicker(defaults: defaults, scope: scope)
            }
        }
        .alert(
            "Discard agent changes?",
            isPresented: $isDiscardConfirmationPresented
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        .onDisappear {
            cancelAvatarPreparation()
            runtimeDefaultsModel?.dismissConfirmation()
        }
        .onChange(of: runtimeDefaultsModel?.pendingConfirmation) { _, confirmation in
            isModelConfirmationPresented = confirmation != nil
        }
        .confirmationDialog(
            "Confirm model defaults",
            isPresented: $isModelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Apply model defaults") {
                Task {
                    do {
                        try await runtimeDefaultsModel?.confirmPendingSave()
                        if model.isCurrentContext, !model.hasUnsavedChanges,
                           runtimeDefaultsModel?.isDirty != true, let profile = pendingCompletedProfile {
                            onCompleted(profile)
                            pendingCompletedProfile = nil
                            dismiss()
                        }
                    } catch {
                        // The defaults model retains the choices and reports the failed confirmation.
                    }
                }
            }
            Button("Cancel", role: .cancel) { runtimeDefaultsModel?.dismissConfirmation() }
        } message: {
            Text(runtimeDefaultsModel?.pendingConfirmation?.message ?? "")
        }
        .accessibilityIdentifier(model.isEditing ? "agent.editor.edit" : "agent.editor.create")
    }

    /// The chat's model picker: choose a model and reasoning level, then apply them
    /// to this agent's draft. Save still commits them with the rest of the agent.
    private func agentModelPicker(defaults: AgentRuntimeDefaultsEditorModel, scope: AgentRuntimeScope) -> some View {
        let selection = defaults.draft[scope]
        let reasoningUnavailable = defaults.support.reasoningUnavailableReasons[scope]
        return BighelpModelPickerSheet(
            title: "Choose model",
            scopeLabel: scope.title,
            providers: defaults.providers,
            currentProviderID: selection.modelID.isEmpty ? nil : selection.providerID,
            currentModelID: selection.modelID.isEmpty ? nil : selection.modelID,
            isLoading: false,
            isApplying: false,
            errorMessage: defaults.errorMessage,
            onClearError: defaults.clearError,
            onRetry: {
                Task { await defaults.refreshProviders() }
            },
            onSelect: { _, _ in },
            reasoningOptions: reasoningUnavailable == nil
                ? AgentReasoningOption.all.map {
                    RuntimeReasoningOption(value: $0.value, label: $0.title, detail: $0.detail,
                                           isCurrent: $0.value == selection.reasoningEffort)
                }
                : [],
            currentReasoningValue: selection.reasoningEffort,
            modelUnavailableReason: defaults.support.modelUnavailableReasons[scope],
            reasoningUnavailableReason: reasoningUnavailable,
            applyTitle: "Use for this agent",
            defaultModelTitle: "Default model",
            onApply: { draft in
                if let providerID = draft.providerID, let modelID = draft.modelID,
                   providerID != selection.providerID || modelID != selection.modelID {
                    defaults.selectModel(providerID: providerID, modelID: modelID, for: scope)
                }
                if let reasoning = draft.reasoningValue, reasoning != selection.reasoningEffort {
                    defaults.selectReasoning(reasoning, for: scope)
                }
                if defaults.errorMessage == nil { modelPickerScope = nil }
            }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .bighelpSheetSize(.standard)
    }

    private var isSaving: Bool {
        model.isSaving || runtimeDefaultsModel?.isSaving == true
    }

    private var hasUnsavedChanges: Bool {
        model.hasUnsavedChanges || runtimeDefaultsModel?.isDirty == true
    }

    private func advancedForm(model: AgentEditorModel) -> some View {
        Form {
            if let defaults = runtimeDefaultsModel {
                AgentRuntimeDefaultsSection(
                    model: defaults,
                    allowsEdits: runtimeDefaultsReadOnlyReason == nil,
                    scopes: [.subagents, .scheduledTasks],
                    modelPickerScope: $modelPickerScope
                )
            }
            if !model.isEditing { cloningSection(model: model) }
            handleSection(model: model)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestDismissal() {
        if hasUnsavedChanges {
            isDiscardConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func cancelAvatarPreparation() {
        avatarPreparationTask?.cancel()
        avatarPreparationTask = nil
        avatarPreparationID = nil
        avatarPreparationLabel = nil
    }

    private func beginAvatarPreparation(label: String) -> UUID {
        cancelAvatarPreparation()
        let requestID = UUID()
        avatarPreparationID = requestID
        avatarPreparationLabel = label
        return requestID
    }

    private func finishAvatarPreparation(_ requestID: UUID) {
        guard avatarPreparationID == requestID else { return }
        avatarPreparationTask = nil
        avatarPreparationID = nil
        avatarPreparationLabel = nil
        photoSelection = nil
    }

    private func ownsAvatarPreparation(_ requestID: UUID) -> Bool {
        avatarPreparationID == requestID && model.isCurrentContext && !Task.isCancelled
    }

    @ViewBuilder
    private func heroAvatar(model: AgentEditorModel) -> some View {
        #if os(visionOS)
        if let look = heroLook, let spatial = SpatialAvatarLook(appearance: look, themeHex: theme.actionHex) {
            // The same 3D character as in the room, playing its moves.
            SpatialAvatarPreview(look: spatial, mood: look.vibe?.moodID, height: 170, isInteractive: false)
        } else {
            avatarPreview(model: model, size: 120)
        }
        #else
        avatarPreview(model: model, size: 120)
        #endif
    }

    #if os(visionOS)
    /// A designed look to show in 3D: this session's pick, or the agent's saved one.
    private var heroLook: CompanionAppearance? {
        if model.pendingAvatar != nil { return model.selectedCompanionAppearance }
        guard !model.draft.removesAvatar, let agentID = model.editingAgentID, let store = companionStore,
              !companionAgentScope.isEmpty else { return nil }
        return store.override(for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID))
    }
    #endif

    private var heroState: AgentLiveState {
        // A preview, not live status: a new agent perks up once it has a name.
        !model.isEditing && !model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .happy : .idle
    }

    private var heroTitle: String {
        let name = model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return model.isEditing ? "Agent" : "New agent"
    }

    private var hasAvatar: Bool {
        model.pendingAvatar != nil || model.draft.avatarFileName != nil || model.draft.avatar != nil
    }

    private func hero(model: AgentEditorModel) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            heroAvatar(model: model)
                .contentShape(.circle)
                .onTapGesture { isAvatarCreatorPresented = true }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.selectedCompanionCharacter.map {
                    "\($0.displayName) agent avatar preview"
                } ?? "Agent avatar preview")
                .accessibilityHint("Opens the avatar creator.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("agent.editor.avatar-preview")
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.actionForeground)
                            .frame(width: 34, height: 34)
                            .background(theme.action, in: .circle)
                            .overlay(Circle().strokeBorder(theme.canvas, lineWidth: 3))
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.circle)
                    }
                    #if os(visionOS)
                    // Otherwise it becomes the whole row's button, a glass slab over the
                    // avatar that takes every pinch meant for Design avatar.
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    #endif
                    .offset(x: 6, y: 6)
                    .accessibilityLabel("Choose custom agent avatar photo")
                    .accessibilityIdentifier("agent.editor.avatar-picker")
                }
                .padding(.bottom, BighelpTokens.space4)
            Text(heroTitle)
                .font(.bighelp(.title2).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityIdentifier("agent.editor.hero-title")
            let role = model.draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty {
                Text(role)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: BighelpTokens.space8) {
                Button {
                    isAvatarCreatorPresented = true
                } label: {
                    Label(hasAvatar ? "Edit avatar" : "Design avatar", systemImage: "wand.and.stars")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .padding(.horizontal, BighelpTokens.space16)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(theme.incomingMessageBackground))
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Pick a character, color, eyes, extras and moves.")
                .accessibilityIdentifier("agent.editor.design-avatar")
                if hasAvatar {
                    Button {
                        cancelAvatarPreparation()
                        model.removeAvatar()
                        photoSelection = nil
                    } label: {
                        Text("Remove")
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, BighelpTokens.space12)
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove avatar")
                    .accessibilityIdentifier("agent.editor.avatar-remove")
                }
            }
            // In a Vision Pro form this row was laid out zero points tall, so
            // Design avatar hung over the name and missed every pinch.
            .frame(minHeight: BighelpTokens.hitTarget)
            .fixedSize(horizontal: false, vertical: true)
            if let avatarPreparationLabel {
                ProgressView(avatarPreparationLabel)
                    .font(.bighelp(.footnote))
                    .accessibilityIdentifier("agent.editor.avatar.loading")
            }
            if let avatarError = model.avatarError {
                recoveryMessage(avatarError)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BighelpTokens.space8)
    }

    private func preparePhotoAvatar(_ selection: PhotosPickerItem) {
        let requestID = beginAvatarPreparation(label: "Preparing photo avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                let data = try await selection.loadTransferable(type: Data.self)
                try Task.checkCancellation()
                guard ownsAvatarPreparation(requestID) else { return }
                guard let data else {
                    model.reportAvatarLoadFailure()
                    return
                }
                try await model.importAvatar(data: data)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportAvatarLoadFailure()
            }
        }
    }

    /// Where the creator opens: this session's look, the agent's saved chat
    /// companion, or a fresh surprise for a new agent.
    private var creatorStartLook: CompanionAppearance {
        if let look = model.selectedCompanionAppearance { return look }
        if let agentID = model.editingAgentID, let store = companionStore, !companionAgentScope.isEmpty,
           let saved = store.override(for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID)) {
            return saved
        }
        return surpriseLook
    }

    /// The Hermes face or shape the creator opens on, if that's the current look.
    private var creatorStartHermesLook: AgentAvatarLook? {
        if let look = model.pendingLook { return look }
        guard !model.draft.removesAvatar, model.pendingAvatar == nil else { return nil }
        return model.editedProfile?.look
    }

    private func prepareLookAvatar(_ look: AgentAvatarLook) {
        photoSelection = nil
        let requestID = beginAvatarPreparation(label: "Preparing avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                guard let data = HermesLookRenderer.png(look: look, name: model.faceName) else {
                    throw AgentCompanionAvatarRenderer.RenderError.emptyImage
                }
                try Task.checkCancellation()
                guard ownsAvatarPreparation(requestID) else { return }
                try await model.importLookAvatar(data: data, look: look)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportCompanionAvatarRenderFailure()
            }
        }
    }

    private func preparePetAvatar(_ pet: PetdexPet, data: Data) {
        photoSelection = nil
        let requestID = beginAvatarPreparation(label: "Preparing \(pet.displayName) avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                guard ownsAvatarPreparation(requestID) else { return }
                try await model.importPetAvatar(data: data, pet: pet)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportCompanionAvatarRenderFailure()
            }
        }
    }

    private func companionBackdrop(_ look: CompanionAppearance) -> Color {
        let hex = look.matchesTheme
            ? CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
            : look.colorHex
        return Color(hex: String(hex.dropFirst()))
    }

    /// The creator's look also becomes this agent's animated chat companion.
    private func applyCompanionLook(to profile: AgentProfile) {
        guard let store = companionStore, !companionAgentScope.isEmpty else { return }
        model.applySavedLook(companions: store, pets: .shared,
            key: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: profile.id))
    }

    private func prepareCompanionAvatar(_ look: CompanionAppearance) {
        photoSelection = nil
        let appearance = appAppearance
        let scheme = colorScheme
        let contrast = colorSchemeContrast
        let requestID = beginAvatarPreparation(label: "Preparing \(look.character.displayName) avatar")
        avatarPreparationTask = Task { @MainActor in
            defer { finishAvatarPreparation(requestID) }
            do {
                let data = try await AgentCompanionAvatarRenderer.renderPNG(
                    companion: look,
                    appearance: appearance,
                    colorScheme: scheme,
                    colorSchemeContrast: contrast
                )
                try Task.checkCancellation()
                guard ownsAvatarPreparation(requestID) else { return }
                try await model.importCompanionAvatar(data: data, appearance: look)
            } catch is CancellationError {
                return
            } catch is AvatarImageProcessor.Error {
                // The model already exposed a format or size-specific recovery message.
            } catch {
                guard ownsAvatarPreparation(requestID) else { return }
                model.reportCompanionAvatarRenderFailure()
            }
        }
    }

    @ViewBuilder
    private func avatarPreview(model: AgentEditorModel, size: CGFloat = 72) -> some View {
        if model.pendingAvatar != nil, let look = model.selectedCompanionAppearance {
            // A creator look plays its chosen moves right here.
            Circle()
                .fill(companionBackdrop(look).opacity(0.18))
                .overlay(Circle().strokeBorder(companionBackdrop(look).opacity(0.25), lineWidth: 1))
                .overlay {
                    CompanionAvatar(appearance: look, reaction: .idle, isAnimating: true)
                        .frame(width: size * 0.8, height: size * 0.8)
                }
                .frame(width: size, height: size)
        } else if model.pendingAvatar != nil, let look = model.pendingLook, look.style != .photo {
            // A Hermes face stays sharp at any size, as Hermes Desktop draws it.
            HermesLookView(look: look, name: model.faceName)
                .frame(width: size, height: size)
        } else if let pending = model.pendingAvatar, let image = UIImage(data: pending.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else {
            AvatarView(
                stableID: model.editingAgentID ?? "agent-editor-new",
                displayName: model.draft.name.isEmpty ? "New agent" : model.draft.name,
                imageURL: model.draft.removesAvatar ? nil : model.avatarURL,
                size: size,
                state: heroState
            )
        }
    }

    @ViewBuilder
    private func identitySection(
        model: AgentEditorModel,
        name: Binding<String>,
        role: Binding<String>,
        summary: Binding<String>
    ) -> some View {
        #if os(visionOS)
        // Section headers don't grow to fit on Vision Pro: the avatar, name and
        // Design avatar piled up and the button ended up zero points tall. A row
        // sizes itself.
        Section {
            heroAndStarters(model: model)
                .padding(.vertical, BighelpTokens.space8)
        }
        .listRowBackground(Color.clear)
        #endif
        Section {
            field("Name", prompt: "Give your agent a name", text: name, focus: .name,
                  error: model.fieldErrors[.name], identifier: "agent.editor.name")
            field("Role", prompt: "e.g. Travel planner", text: role, focus: .role,
                  error: model.fieldErrors[.role], identifier: "agent.editor.role")
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                fieldCaption("Vibe")
                TextField("Vibe", text: summary, prompt: Text("One line about what it does").bighelpFieldHint(theme),
                          axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .summary)
                    .accessibilityLabel("Vibe")
                    .accessibilityIdentifier("agent.editor.summary")
                if let error = model.fieldErrors[.summary] { recoveryMessage(error) }
            }
            .padding(.vertical, BighelpTokens.space4)
        } header: {
            VStack(spacing: BighelpTokens.space20) {
                #if !os(visionOS)
                heroAndStarters(model: model)
                #endif
                AgentStudioCaption("Identity")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent.editor.identity-header")
            }
            .textCase(nil)
            .padding(.bottom, BighelpTokens.space4)
        }
        .listRowBackground(theme.surface)
    }

    private func heroAndStarters(model: AgentEditorModel) -> some View {
        VStack(spacing: BighelpTokens.space20) {
            hero(model: model)
            if !model.isEditing {
                AgentStartPicker(model: model, library: templateLibrary)
            }
        }
    }

    private func cloningSection(model: AgentEditorModel) -> some View {
        Section {
            if let reason = model.profileCloneSupport.unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Clone from existing profile", selection: cloneSourceBinding(model)) {
                    Text("None, create fresh").tag(String?.none)
                    ForEach(model.cloneSources) { profile in
                        Text(profile.name).tag(String?.some(profile.id))
                    }
                }
                .accessibilityIdentifier("agent.editor.clone.source")

                Toggle("Skip bundled skills", isOn: Binding(
                    get: { model.draft.skipBundledSkills },
                    set: { model.setSkipBundledSkills($0) }
                ))
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("agent.editor.clone.skip-bundled-skills")
                .disabled(model.draft.cloneSourceProfileID != nil)

                if model.draft.cloneSourceProfileID != nil {
                    Label(
                        "The source’s skills are included. Chat history, scheduled tasks, and local pins are not copied.",
                        systemImage: "doc.on.doc"
                    )
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(
                "Use a new name and avatar, then review SOUL so this agent keeps a distinct purpose.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("agent.editor.clone.soul-reminder")

            if let error = model.fieldErrors[.cloning] { recoveryMessage(error) }
        } header: {
            AgentStudioCaption("Copy setup from an agent")
        } footer: {
            Text(model.draft.cloneSourceProfileID == nil
                 ? "Start fresh can omit Hermes’ bundled skills."
                 : "Hermes copies configuration, saved credentials, skills, built-in memories, and SOUL on this host. bighelp never displays credential contents.")
        }
        .listRowBackground(theme.surface)
    }

    private func cloneSourceBinding(_ model: AgentEditorModel) -> Binding<String?> {
        Binding(
            get: { model.draft.cloneSourceProfileID },
            set: { model.selectCloneSource($0) }
        )
    }

    private func saveAgent() {
        Task {
            do {
                let profile = try await model.save()
                applyCompanionLook(to: profile)
                pendingCompletedProfile = profile
                try await runtimeDefaultsModel?.saveIfNeeded()
                guard model.isCurrentContext else { return }
                onCompleted(profile)
                pendingCompletedProfile = nil
                dismiss()
            } catch {
                // Each model owns precise, recoverable inline error copy.
            }
        }
    }

    private var instructionsPlaceholder: String {
        let name = model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "What should \(name.isEmpty ? "your agent" : name) help you with? How should it talk?"
    }

    private var canSaveAgent: Bool {
        !isSaving && !model.hasUnconfirmedSave && avatarPreparationID == nil
    }

    private func instructionsSection(model: AgentEditorModel, instructions: Binding<String>) -> some View {
        Section {
            textEditor(
                "Instructions",
                placeholder: instructionsPlaceholder,
                text: instructions,
                focus: .instructions,
                error: model.fieldErrors[.instructions],
                identifier: "agent.editor.instructions"
            )
        } header: {
            HStack {
                AgentStudioCaption("Instructions")
                    .accessibilityIdentifier("agent.editor.behavior-header")
                Spacer()
                FocusedTextEditorButton(title: "Instructions", identifier: "agent.editor.instructions.expand") {
                    expandsInstructions = true
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                if !model.isEditing && runtimeDefaultsModel == nil && runtimeDefaultsReadOnlyReason == nil {
                    Label("Uses your default model. You can pick another after creating.", systemImage: "cpu")
                        .accessibilityIdentifier("agent.editor.model-default-note")
                }
                if !model.isEditing, let source = model.cloneSourceName {
                    Label(nerdModeEnabled
                          ? "Starts with \(source)’s skills, memories and settings. Change this in Advanced."
                          : "Starts with \(source)’s skills, memories and settings.",
                          systemImage: "doc.on.doc")
                        .accessibilityIdentifier("agent.editor.clone-note")
                }
            }
        }
        .listRowBackground(theme.surface)
    }

    private func handleSection(model: AgentEditorModel) -> some View {
        Section {
            LabeledContent("Mention handle") {
                Text("@\(model.handlePreview)")
                    .font(.bighelp(.body).monospaced())
                    .foregroundStyle(theme.action)
            }
        } header: {
            AgentStudioCaption("Mention handle")
        } footer: {
            Text("Suggested for new groups. Existing handles stay unchanged.")
        }
        .listRowBackground(theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested mention handle @\(model.handlePreview)")
    }

    private func fieldCaption(_ title: String) -> some View {
        Text(title)
            .font(.bighelp(.caption).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .accessibilityHidden(true)
    }

    private func field(
        _ title: String,
        prompt: String,
        text: Binding<String>,
        focus: AgentEditorModel.Field,
        error: String?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            fieldCaption(title)
            TextField(title, text: text, prompt: Text(prompt).bighelpFieldHint(theme))
                .focused($focusedField, equals: focus)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
            if let error { recoveryMessage(error) }
        }
        .padding(.vertical, BighelpTokens.space4)
    }

    private func textEditor(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        focus: AgentEditorModel.Field,
        error: String?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            // A long SOUL scrolls inside its own box instead of stretching the form,
            // so the sections below it (the agent's model) stay within easy reach.
            TextEditor(text: text)
                .focused($focusedField, equals: focus)
                .font(.bighelp(.body))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140, maxHeight: 260)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityHint(text.wrappedValue.isEmpty ? placeholder : "")
                .accessibilityIdentifier(identifier)
            if let error { recoveryMessage(error) }
        }
    }

    private func recoveryMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .bighelpFont(.metadata)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @BighelpThemeReader private var theme

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appAppearance) private var appAppearance
    @Environment(\.companionStore) private var companionStore
    @Environment(\.companionAgentScope) private var companionAgentScope
}
