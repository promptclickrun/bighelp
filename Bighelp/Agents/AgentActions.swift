import SwiftUI

/// What an agent's actions need from the screen showing them.
struct AgentActionsConfig {
    let store: AgentDirectoryStore
    let runtimeDefaultsClient: any AgentRuntimeDefaultsClient
    let owner: WorkspaceOwner?
    let capabilities: WorkspaceCapabilities
    let cloneClient: (any AgentProfileCloneClient)?
    let shortcutsAvailable: Bool
    let onAction: (@MainActor (AgentWorkspaceActionRequest) -> Void)?
    let agentDeletion: AgentDeletionAction?

    func supports(_ capability: WorkspaceCapability, profileID: String? = nil) -> Bool {
        guard let owner else { return false }
        return capabilities.supports(capability, owner: owner, profileID: profileID)
    }

    func capabilityReason(_ capability: WorkspaceCapability, profileID: String?) -> String {
        guard let owner else { return WorkspaceUnavailableReason.notConnected.message }
        return AgentActionsPresentation.unavailableMessage(
            capabilities.availability(for: capability, owner: owner, profileID: profileID)
        ) ?? WorkspaceUnavailableReason.unsupportedOperation.message
    }
}

/// An agent's hold-menu actions and the sheets they open, shared by the Agents
/// list and the Chats "Your agents" rail so both offer the same options.
@MainActor @Observable
final class AgentActions {
    var editor: AgentEditorModel?
    var shortcutsAgent: AgentProfile?
    var duplicateModel: AgentDuplicateModel?
    var pendingDeletion: AgentProfile?
    private(set) var deletingAgent: AgentProfile?
    var templateNotice: String?
    var actionError: String?
    /// The connection the actions run on.
    private(set) var activeOwner: WorkspaceOwner?
    /// The computer and sign-in the sheets belong to; they close when it changes.
    private var signIn: WorkspaceSignIn?

    func items(_ agent: AgentProfile, _ config: AgentActionsConfig) -> [AgentActionItem] {
        AgentActionsPresentation.items(
            profileID: agent.id, owner: config.owner, capabilities: config.capabilities,
            isPrimary: config.store.isPrimary(agent.id), isPinned: config.store.isPinned(agent.id),
            canPin: config.store.canPin(agent.id), canClone: config.cloneClient != nil,
            shortcutsAvailable: config.shortcutsAvailable, hasNavigation: config.onAction != nil,
            canDelete: config.agentDeletion != nil && deletingAgent == nil && AgentDeletionPresentation.canDelete(agent),
            canSaveTemplate: true
        )
    }

    /// Runs one action. `.groups` belongs to the Agents list, which handles it itself.
    func perform(_ action: AgentRowMenuAction, agent: AgentProfile, config: AgentActionsConfig) {
        guard let owner = config.owner, owner == activeOwner,
              items(agent, config).first(where: { $0.action == action })?.isEnabled == true else {
            actionError = "This action is no longer available. Reopen the agent's actions to see its current status."
            return
        }
        switch action {
        case .openChat: dispatch(.openAgentChat(profileID: agent.id), config)
        case .viewSessions: dispatch(.openAgentSessions(profileID: agent.id), config)
        case .scheduledTasks: dispatch(.openAgentScheduledTasks(profileID: agent.id), config)
        case .setPrimary: config.store.setPrimaryAgent(agent.id)
        case .togglePin:
            if config.store.isPinned(agent.id) { config.store.unpinAgent(agent.id) }
            else { config.store.pinAgent(agent.id) }
        case .groups: break
        case .edit:
            editor = .editing(agent, store: config.store, processor: AvatarImageProcessor(),
                              isCurrent: { [weak self] in self?.activeOwner?.signIn == owner.signIn })
        case .duplicate:
            guard let cloneClient = config.cloneClient else { return }
            duplicateModel = AgentDuplicateModel(source: agent, owner: owner, client: cloneClient,
                                                 isCurrent: { [weak self] in self?.activeOwner == owner })
        case .shortcuts: shortcutsAgent = agent
        case .saveTemplate:
            let template = AgentTemplateLibrary.shared.save(from: agent)
            templateNotice = "“\(template.title)” is saved on this device. To use it, create an agent and choose My templates."
        case .delete: pendingDeletion = agent
        }
    }

    /// Runs after the confirmation. The list refreshes once Hermes confirms the agent is gone.
    func delete(_ agent: AgentProfile, config: AgentActionsConfig) {
        guard let deletion = config.agentDeletion, let owner = config.owner, owner == activeOwner else {
            actionError = "Deleting agents isn't available on this connection."
            return
        }
        deletingAgent = agent
        Task { @MainActor in
            defer { deletingAgent = nil }
            do {
                try await deletion.run(agent.id)
            } catch {
                guard activeOwner == owner else { return }
                actionError = AgentDeletionPresentation.errorMessage(error)
            }
        }
    }

    func adopt(owner: WorkspaceOwner?) {
        guard owner != activeOwner else { return }
        activeOwner = owner
        // A copy in progress can't carry over to another connection.
        duplicateModel?.cancel()
        duplicateModel = nil
        // Disconnected, or back on the same computer and sign-in (bighelp
        // reconnects after you've been away): open sheets and dialogs stay.
        guard let owner, owner.signIn != signIn else { return }
        let previousScope = signIn?.authority.cacheScopeID
        signIn = owner.signIn
        shortcutsAgent = nil
        pendingDeletion = nil
        if previousScope != owner.cacheScopeID { editor = nil }
    }

    private func dispatch(_ action: AgentWorkspaceAction, _ config: AgentActionsConfig) {
        guard let owner = config.owner, owner == activeOwner, let onAction = config.onAction else {
            actionError = "The host connection changed. Try opening this action again."
            return
        }
        onAction(AgentWorkspaceActionRequest(owner: owner, action: action))
    }
}

/// The hold menu's buttons for one agent.
struct AgentActionMenuItems: View {
    let actions: AgentActions
    let agent: AgentProfile
    let config: AgentActionsConfig
    var hidden: Set<AgentRowMenuAction> = []
    var perform: ((AgentRowMenuAction) -> Void)? = nil

    var body: some View {
        ForEach(actions.items(agent, config).filter { !$0.isUnsupported && !hidden.contains($0.action) }) { item in
            if item.action.isDestructive { Divider() }
            Button(item.title, systemImage: item.systemImage, role: item.action.isDestructive ? .destructive : nil) {
                if let perform { perform(item.action) } else { actions.perform(item.action, agent: agent, config: config) }
            }
            .disabled(!item.isEnabled)
        }
    }
}

extension View {
    /// Presents what the agent actions open: edit, duplicate, Siri, delete confirmation and notices.
    func agentActionsPresentation(_ actions: AgentActions, config: AgentActionsConfig) -> some View {
        modifier(AgentActionsSheets(actions: actions, config: config))
    }

    @ViewBuilder
    func agentActionsPresentation(_ actions: AgentActions, config: AgentActionsConfig?) -> some View {
        if let config { modifier(AgentActionsSheets(actions: actions, config: config)) } else { self }
    }
}

private struct AgentActionsSheets: ViewModifier {
    @Bindable var actions: AgentActions
    let config: AgentActionsConfig

    func body(content: Content) -> some View {
        content
            .onAppear { actions.adopt(owner: config.owner) }
            .onChange(of: config.owner) { _, owner in actions.adopt(owner: owner) }
            .bighelpSheet(item: $actions.editor) { model in
                let canReadDefaults = config.supports(.modelsRead, profileID: model.editingAgentID)
                let canEditDefaults = config.supports(.agentDefaultsEdit, profileID: model.editingAgentID)
                AgentEditorView(
                    model: model,
                    runtimeDefaultsClient: canReadDefaults ? config.runtimeDefaultsClient : nil,
                    runtimeDefaultsReadOnlyReason: model.isEditing && (!canReadDefaults || !canEditDefaults)
                        ? config.capabilityReason(canReadDefaults ? .agentDefaultsEdit : .modelsRead,
                                                  profileID: model.editingAgentID)
                        : nil
                ) { _ in actions.editor = nil }
            }
            .bighelpSheet(item: $actions.shortcutsAgent) { agent in
                AgentShortcutsView(agent: agent)
                    .bighelpSheetSize(.standard)
            }
            .bighelpSheet(item: $actions.duplicateModel) { model in
                AgentDuplicateView(model: model) {
                    actions.duplicateModel = nil
                    Task { await config.store.loadReportingErrors() }
                }
                .bighelpSheetSize(.standard)
            }
            .confirmationDialog(actions.pendingDeletion.map(AgentDeletionPresentation.title) ?? "Delete agent?",
                                isPresented: Binding(get: { actions.pendingDeletion != nil },
                                                     set: { if !$0 { actions.pendingDeletion = nil } }),
                                titleVisibility: .visible, presenting: actions.pendingDeletion) { agent in
                Button("Delete Agent", role: .destructive) { actions.delete(agent, config: config) }
                    .accessibilityIdentifier("agents.delete.confirm")
            } message: { agent in
                Text(AgentDeletionPresentation.message(agent))
            }
            .overlay(alignment: .bottom) {
                if let deleting = actions.deletingAgent {
                    Label {
                        Text(AgentDeletionPresentation.progress(deleting))
                    } icon: {
                        ProgressView()
                    }
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, BighelpTokens.space24)
                    .accessibilityIdentifier("agents.deleting")
                }
            }
            .alert("Template saved", isPresented: Binding(get: { actions.templateNotice != nil },
                                                          set: { if !$0 { actions.templateNotice = nil } })) {
            } message: {
                Text(actions.templateNotice ?? "")
            }
            .alert("Agent action unavailable", isPresented: Binding(
                get: { actions.actionError != nil },
                set: { if !$0 { actions.actionError = nil } }
            )) {} message: {
                Text(actions.actionError ?? "")
            }
    }
}
