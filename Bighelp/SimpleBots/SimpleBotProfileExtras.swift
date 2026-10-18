import PhotosUI
import SwiftUI

/// Saves what the full avatar studio made for a bot, at once: the picture on the host (what every
/// screen, device and Hermes Desktop shows), and here the character or pet that chats draw over
/// it. The bot's mark goes, so Simple Bot mode shows the new avatar.
@MainActor
enum SimpleBotAvatarSaving {
    enum Failure: Error { case render, photo }

    struct Look {
        let appearance: BighelpAppearanceContext
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
    }

    static func save(_ result: AvatarCreatorResult, for profile: AgentProfile, agents: AgentDirectoryStore,
                     companions: CompanionStore?, scope: String, look: Look) async throws {
        if case .mark(let mark) = result {
            try await SimpleBotMarkSaving.save(mark, for: profile, agents: agents, companions: companions, scope: scope)
            return
        }
        let editor = AgentEditorModel.editing(profile, store: agents, processor: AvatarImageProcessor())
        switch result {
        case .companion(let character):
            let data = try await AgentCompanionAvatarRenderer.renderPNG(
                companion: character, appearance: look.appearance, colorScheme: look.colorScheme,
                colorSchemeContrast: look.contrast)
            try await editor.importCompanionAvatar(data: data, appearance: character)
        case .look(let face):
            guard let data = HermesLookRenderer.png(look: face, name: editor.faceName) else { throw Failure.render }
            try await editor.importLookAvatar(data: data, look: face)
        case .pet(let pet, let data):
            try await editor.importPetAvatar(data: data, pet: pet)
        case .photo(let item):
            guard let data = try await item.loadTransferable(type: Data.self) else { throw Failure.photo }
            try await editor.importAvatar(data: data)
        case .mark:
            return
        }
        _ = try await editor.save()
        SimpleBotMarkStore.shared.set(nil, scope: scope, agentID: profile.id)
        guard let companions, !scope.isEmpty else { return }
        editor.applySavedLook(companions: companions, pets: .shared,
                              key: CompanionStore.agentKey(agentScope: scope, agentID: profile.id))
    }

    /// Where the studio opens: the bot's mark when it has one, else its character, pet or picture.
    static func start(for profile: AgentProfile, agents: AgentDirectoryStore, companions: CompanionStore?,
                      scope: String) -> AvatarCreatorStart {
        if let mark = SimpleBotMarkStore.shared.mark(scope: scope, agentID: profile.id) { return .mark(mark) }
        let key = CompanionStore.agentKey(agentScope: scope, agentID: profile.id)
        let editor = AgentEditorModel.editing(profile, store: agents, processor: AvatarImageProcessor())
        return editor.avatarCreatorStart(
            savedCharacter: scope.isEmpty ? nil : companions?.override(for: key),
            savedPetSlug: scope.isEmpty ? nil : PetAvatarStore.shared.slug(for: key),
            surprise: AvatarCreatorModel.surprise())
    }
}

/// A bot's default model and reasoning, from the same picker chats use. Saving goes straight to
/// the host; a change Hermes wants confirmed asks first.
@MainActor
struct SimpleBotDefaultModelSheet: View {
    let defaults: AgentRuntimeDefaultsEditorModel
    let botName: String
    let onClose: () -> Void

    @State private var isSaving = false

    var body: some View {
        let selection = defaults.draft[.mainChats]
        let reasoningUnavailable = defaults.support.reasoningUnavailableReasons[.mainChats]
        BighelpModelPickerSheet(
            title: "Default Model",
            scopeLabel: botName,
            providers: defaults.providers,
            currentProviderID: selection.modelID.isEmpty ? nil : selection.providerID,
            currentModelID: selection.modelID.isEmpty ? nil : selection.modelID,
            isLoading: defaults.isLoading,
            isApplying: isSaving || defaults.isSaving,
            errorMessage: defaults.errorMessage,
            onClearError: defaults.clearError,
            onRetry: { Task { await defaults.refreshProviders() } },
            onSelect: { _, _ in },
            reasoningOptions: reasoningUnavailable == nil
                ? AgentReasoningOption.all.map {
                    RuntimeReasoningOption(value: $0.value, label: $0.title, detail: $0.detail,
                                           isCurrent: $0.value == selection.reasoningEffort)
                }
                : [],
            currentReasoningValue: selection.reasoningEffort,
            modelUnavailableReason: defaults.support.modelUnavailableReasons[.mainChats],
            reasoningUnavailableReason: reasoningUnavailable,
            applyTitle: "Save",
            defaultModelTitle: "Default model",
            onApply: { draft in save(draft, current: selection) }
        )
        .task { await defaults.loadIfNeeded() }
        .alert("Save this model?", isPresented: Binding(
            get: { defaults.pendingConfirmation != nil },
            set: { if !$0 { defaults.dismissConfirmation() } })) {
            Button("Save") { Task { await confirm() } }
            Button("Cancel", role: .cancel) { defaults.dismissConfirmation() }
        } message: {
            Text(defaults.pendingConfirmation?.message ?? "")
        }
    }

    private func save(_ draft: SessionRuntimeSelectionDraft, current: AgentRuntimeSelection) {
        if let providerID = draft.providerID, let modelID = draft.modelID,
           providerID != current.providerID || modelID != current.modelID {
            defaults.selectModel(providerID: providerID, modelID: modelID, for: .mainChats)
        }
        if let reasoning = draft.reasoningValue, reasoning != current.reasoningEffort {
            defaults.selectReasoning(reasoning, for: .mainChats)
        }
        guard defaults.errorMessage == nil else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await defaults.saveIfNeeded()
                onClose()
            } catch {
                // The picker shows the model's message; a confirmation asks above.
            }
        }
    }

    private func confirm() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await defaults.confirmPendingSave()
            onClose()
        } catch {}
    }
}
