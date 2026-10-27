import Foundation
import SwiftUI

enum NewChatOutcome: Equatable, Sendable {
    case opened(sessionID: String, agentID: String)
    case needsAgentSelection
}

@MainActor
final class NewChatCoordinator {
    private struct InFlightStart {
        let id: UUID
        let task: Task<NewChatOutcome, Error>
    }

    private let appState: AppState
    private let agents: AgentDirectoryStore
    private let catalog: SessionCatalogStore
    private let hermesWorkspaces: HermesWorkspaceStore?
    private let prepare: (AppRoute) -> Bool
    private var inFlightStart: InFlightStart?
    private var pendingPresentationDraft: (id: String, agentID: String)?

    init(
        appState: AppState,
        agents: AgentDirectoryStore,
        catalog: SessionCatalogStore,
        hermesWorkspaces: HermesWorkspaceStore? = nil,
        prepare: @escaping (AppRoute) -> Bool
    ) {
        self.appState = appState
        self.agents = agents
        self.catalog = catalog
        self.hermesWorkspaces = hermesWorkspaces
        self.prepare = prepare
        pendingPresentationDraft = nil
    }

    func start(explicitAgentID: String? = nil,
               beforePresentation: @escaping @MainActor (String, String?) -> Void = { _, _ in }) async throws -> NewChatOutcome {
        if let inFlightStart {
            return try await inFlightStart.task.value
        }

        let startID = UUID()
        let task = Task { @MainActor [self] in
            try await performStart(explicitAgentID: explicitAgentID, beforePresentation: beforePresentation)
        }
        inFlightStart = InFlightStart(id: startID, task: task)
        defer {
            if inFlightStart?.id == startID {
                inFlightStart = nil
            }
        }
        return try await task.value
    }

    private func performStart(explicitAgentID: String?,
                              beforePresentation: @escaping @MainActor (String, String?) -> Void) async throws -> NewChatOutcome {
        // Link may be reconnecting while the shell is already usable. Resolve
        // an active/default agent from the last known directory immediately so
        // a transient refresh failure cannot block a new chat. The native
        // workspace runtime owns the authoritative directory refresh; starting
        // another load here would invalidate that in-flight refresh. A missing
        // cache remains a hard failure: Hermes must always receive an explicit
        // agent ID for a new session.
        if let cachedAgent = agents.resolvedAgent(explicitID: explicitAgentID) {
            return try await openSession(for: cachedAgent, beforePresentation: beforePresentation)
        }

        try await agents.load()
        guard let agent = agents.resolvedAgent(explicitID: explicitAgentID) else {
            return .needsAgentSelection
        }

        return try await openSession(for: agent, beforePresentation: beforePresentation)
    }

    private func openSession(for agent: AgentProfile,
                             beforePresentation: @MainActor (String, String?) -> Void) async throws -> NewChatOutcome {
        let presentation = localPresentationDraft(for: agent)
        let presentationRoute = AppRoute.chat(conversationID: presentation.id)
        guard prepare(presentationRoute) else {
            catalog.discardLocalPresentationDraft(id: presentation.id)
            if pendingPresentationDraft?.id == presentation.id {
                pendingPresentationDraft = nil
            }
            return .needsAgentSelection
        }
        // Show a usable local canvas before any Hermes round trip. This ID is
        // never sent to Hermes; the durable session below remains authoritative.
        present(presentation.id, beforePresentation: beforePresentation)

        let session = try await catalog.createDirect(agentID: agent.id)
        let presentationRecord = catalog.session(id: presentation.id)
        let draft = presentationRecord?.draft ?? ""
        if let referenceState = presentationRecord?.referenceState {
            do {
                try catalog.updateReferenceState(
                    canonicalDraft: draft,
                    state: referenceState,
                    for: session.id
                )
            } catch {
                // Keep the local canvas if reference metadata cannot be
                // rebound to the authoritative session without weakening its
                // owner validation.
                return .needsAgentSelection
            }
            guard catalog.session(id: session.id)?.referenceState == referenceState else {
                return .needsAgentSelection
            }
        } else if !draft.isEmpty {
            catalog.updateDraft(draft, for: session.id)
            guard catalog.session(id: session.id)?.draft == draft else {
                // Keep the local canvas if its draft could not be copied into
                // the authoritative record, so the user can retry safely.
                return .needsAgentSelection
            }
        }
        guard appState.path.last == presentationRoute else {
            // The user navigated away while Hermes allocated the session. Keep
            // that navigation intact instead of hijacking it on completion.
            catalog.discardLocalPresentationDraft(id: presentation.id)
            if pendingPresentationDraft?.id == presentation.id {
                pendingPresentationDraft = nil
            }
            return .opened(sessionID: session.id, agentID: agent.id)
        }
        let route = AppRoute.chat(conversationID: session.id)
        guard prepare(route) else {
            return .needsAgentSelection
        }
        present(session.id, beforePresentation: beforePresentation)
        catalog.discardLocalPresentationDraft(id: presentation.id)
        if pendingPresentationDraft?.id == presentation.id {
            pendingPresentationDraft = nil
        }

        if let hermesWorkspaces {
            if hermesWorkspaces.catalogAgentID != agent.id || hermesWorkspaces.catalog == nil {
                await hermesWorkspaces.load(agentID: agent.id)
            }
            guard hermesWorkspaces.catalogAgentID == agent.id,
                  let workspaceCatalog = hermesWorkspaces.catalog else {
                return .opened(sessionID: session.id, agentID: agent.id)
            }
            if let workspaceID = workspaceCatalog.activeWorkspaceID {
                guard await hermesWorkspaces.select(
                    id: workspaceID,
                    agentID: agent.id,
                    sessionID: session.id
                ) else {
                    return .opened(sessionID: session.id, agentID: agent.id)
                }
                // The workspace client has already confirmed the move with
                // Hermes' session.workspace.move and projects.for_cwd
                // readback. Keep the catalog summary in sync immediately;
                // the next authoritative session list will rehydrate the
                // same association from the session's persisted cwd.
                let workspaceName = HermesWorkspaceSelectionPresentation.selectedName(
                    store: hermesWorkspaces, sessionID: session.id
                )
                catalog.reconcileSessionWorkspace(
                    id: hermesWorkspaces.workspaceID(forSessionID: session.id),
                    name: workspaceName,
                    sessionID: session.id
                )
            }
        }

        return .opened(sessionID: session.id, agentID: agent.id)
    }

    private func present(_ id: String, beforePresentation: @MainActor (String, String?) -> Void) {
        beforePresentation(id, appState.activeConversationID)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { appState.activateConversation(id: id, source: .newChat) }
    }

    private func localPresentationDraft(for agent: AgentProfile) -> SessionRecord {
        if let pendingPresentationDraft,
           pendingPresentationDraft.agentID == agent.id,
           let existing = catalog.session(id: pendingPresentationDraft.id),
           existing.isLocalPresentationDraft {
            return existing
        }
        let draft = catalog.createLocalPresentationDraft(agentID: agent.id)
        pendingPresentationDraft = (id: draft.id, agentID: agent.id)
        return draft
    }
}
