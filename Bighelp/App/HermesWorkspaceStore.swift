import Foundation
import Observation

@MainActor
enum HermesWorkspaceSelectionPresentation {
    static func isSelected(
        _ workspace: HermesWorkspaceSummary,
        store: HermesWorkspaceStore,
        sessionID: String?
    ) -> Bool {
        if let sessionID {
            return store.workspaceID(forSessionID: sessionID) == workspace.id
        }
        return workspace.isActive
    }

    static func selectedName(
        store: HermesWorkspaceStore,
        sessionID: String?
    ) -> String? {
        if let sessionID {
            guard let workspaceID = store.workspaceID(forSessionID: sessionID) else {
                return nil
            }
            return store.catalog?.workspaces.first { $0.id == workspaceID }?.name
        }
        return store.catalog?.workspaces.first(where: \.isActive)?.name
    }
}

@MainActor
@Observable
final class HermesWorkspaceStore {
    private let client: any HermesWorkspaceCatalogClient
    private(set) var catalog: HermesWorkspaceCatalog?
    private(set) var catalogAgentID: String?
    private(set) var isLoading = false
    private(set) var selectingID: String?
    private(set) var isCreating = false
    private(set) var archivingID: String?
    private(set) var folderSuggestions: HermesWorkspaceFolderPage?
    private(set) var isLoadingFolderSuggestions = false
    private(set) var folderSuggestionErrorMessage: String?
    /// The Hermes computer's home folder, learned from listing a "~" path.
    private(set) var homePath: String?
    private(set) var errorMessage: String?
    private var loadGeneration = 0
    private var folderSuggestionGeneration = 0
    private var loadingAgentID: String?
    private var loadingSessionID: String?
    private var selectedWorkspaceIDsBySession: [String: String] = [:]

    init(client: any HermesWorkspaceCatalogClient) {
        self.client = client
    }

    func load(agentID: String, sessionID: String? = nil) async {
        guard !(isLoading && loadingAgentID == agentID && loadingSessionID == sessionID) else {
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        if catalogAgentID != agentID {
            catalog = nil
            catalogAgentID = nil
        }
        isLoading = true
        loadingAgentID = agentID
        loadingSessionID = sessionID
        defer {
            if generation == loadGeneration {
                isLoading = false
                loadingAgentID = nil
                loadingSessionID = nil
            }
        }
        do {
            let loaded = try await client.load(agentID: agentID, sessionID: sessionID)
            guard generation == loadGeneration else { return }
            catalog = loaded
            if let sessionID {
                if let workspaceID = loaded.sessionWorkspaceID {
                    selectedWorkspaceIDsBySession[sessionID] = workspaceID
                } else {
                    selectedWorkspaceIDsBySession.removeValue(forKey: sessionID)
                }
            }
            catalogAgentID = agentID
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = "Workspaces could not be loaded from Hermes."
        }
    }

    @discardableResult
    func select(
        id: String,
        agentID: String,
        sessionID: String? = nil
    ) async -> Bool {
        guard selectingID == nil, archivingID == nil, !isCreating else { return false }
        loadGeneration += 1
        let generation = loadGeneration
        selectingID = id
        defer {
            if selectingID == id { selectingID = nil }
        }
        do {
            let selectedCatalog = try await client.select(
                id: id,
                agentID: agentID,
                sessionID: sessionID
            )
            guard generation == loadGeneration else { return false }
            if let sessionID {
                let verifiedCatalog: HermesWorkspaceCatalog
                if selectedCatalog.sessionWorkspaceID == id {
                    // Direct Hermes has already moved the exact session and
                    // verified projects.for_cwd before returning this catalog.
                    // A second scoped load would re-enter legacy session
                    // detail/cwd recovery and can reject an otherwise
                    // authoritative selection.
                    verifiedCatalog = selectedCatalog
                } else {
                    // Link-era clients may acknowledge selection without
                    // returning the session anchor. Preserve their readback
                    // verification, but reject an explicitly different
                    // anchor rather than hiding a contradictory result.
                    guard selectedCatalog.sessionWorkspaceID == nil else {
                        throw BighelpLinkWorkspaceClientError.invalidResponse
                    }
                    let readback = try await client.load(
                        agentID: agentID,
                        sessionID: sessionID
                    )
                    guard generation == loadGeneration,
                          readback.sessionWorkspaceID == id else {
                        throw BighelpLinkWorkspaceClientError.invalidResponse
                    }
                    verifiedCatalog = readback
                }
                catalog = verifiedCatalog
                selectedWorkspaceIDsBySession[sessionID] = id
            } else {
                catalog = selectedCatalog
            }
            catalogAgentID = agentID
            errorMessage = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = (error as? WorkspaceClientError)?.errorDescription
                ?? "That Workspace could not be selected."
            return false
        }
    }

    @discardableResult
    func create(name: String, folderPath: String, description: String = "", agentID: String) async -> Bool {
        guard !isCreating, selectingID == nil, archivingID == nil else { return false }
        loadGeneration += 1
        let generation = loadGeneration
        isCreating = true
        defer {
            isCreating = false
        }
        do {
            if HermesFolderPath.expanded(folderPath, home: homePath) == nil, folderPath.hasPrefix("~") {
                _ = try? await learnHome(agentID: agentID)
            }
            guard let fullPath = HermesFolderPath.expanded(folderPath, home: homePath) else {
                guard generation == loadGeneration else { return false }
                errorMessage = "bighelp couldn't find the home folder on your computer. Type the full path, starting with /."
                return false
            }
            var created = try await client.create(
                name: name,
                folderPath: fullPath,
                agentID: agentID
            )
            // A new project becomes the current one; describe it if asked.
            let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let id = created.activeWorkspaceID {
                created = (try? await client.describe(id: id, description: text, agentID: agentID)) ?? created
            }
            guard generation == loadGeneration else { return false }
            catalog = created
            catalogAgentID = agentID
            errorMessage = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = "That Workspace could not be created. Check the remote folder path."
            return false
        }
    }

    @discardableResult
    func archive(id: String, agentID: String) async -> Bool {
        guard archivingID == nil, selectingID == nil, !isCreating else { return false }
        loadGeneration += 1
        let generation = loadGeneration
        archivingID = id
        defer {
            if archivingID == id { archivingID = nil }
        }
        do {
            let archived = try await client.archive(id: id, agentID: agentID)
            guard generation == loadGeneration else { return false }
            catalog = archived
            selectedWorkspaceIDsBySession = selectedWorkspaceIDsBySession.filter {
                $0.value != id
            }
            catalogAgentID = agentID
            errorMessage = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = "That Workspace registration could not be archived."
            return false
        }
    }

    func loadFolderSuggestions(typedPath: String, agentID: String) async {
        folderSuggestionGeneration += 1
        let generation = folderSuggestionGeneration
        guard let query = HermesFolderPath.query(for: typedPath) else {
            folderSuggestions = nil
            folderSuggestionErrorMessage = nil
            isLoadingFolderSuggestions = false
            return
        }
        isLoadingFolderSuggestions = true
        defer {
            if generation == folderSuggestionGeneration {
                isLoadingFolderSuggestions = false
            }
        }
        do {
            let page = try await client.folderSuggestions(
                parentPath: query.parentPath,
                prefix: query.prefix,
                offset: 0,
                limit: 100,
                agentID: agentID
            )
            guard generation == folderSuggestionGeneration else { return }
            if let home = HermesFolderPath.home(listed: query.parentPath, fullPath: page.parentPath) { homePath = home }
            folderSuggestions = page
            folderSuggestionErrorMessage = nil
        } catch {
            guard generation == folderSuggestionGeneration else { return }
            folderSuggestions = nil
            folderSuggestionErrorMessage = HermesFolderListing.message(for: error)
        }
    }

    private func learnHome(agentID: String) async throws {
        let page = try await client.folderSuggestions(parentPath: "~", prefix: "", offset: 0, limit: 1, agentID: agentID)
        if let home = HermesFolderPath.home(listed: "~", fullPath: page.parentPath) { homePath = home }
    }

    func workspaceID(forSessionID sessionID: String) -> String? {
        selectedWorkspaceIDsBySession[sessionID]
    }

    func reconcileSessionWorkspace(id: String?, sessionID: String) {
        if isLoading && loadingSessionID == sessionID {
            loadGeneration += 1
            isLoading = false
            loadingAgentID = nil
            loadingSessionID = nil
        }
        if let id {
            selectedWorkspaceIDsBySession[sessionID] = id
        } else {
            selectedWorkspaceIDsBySession.removeValue(forKey: sessionID)
        }
    }

    func resetForAccountBoundary() {
        loadGeneration += 1
        folderSuggestionGeneration += 1
        catalog = nil
        catalogAgentID = nil
        errorMessage = nil
        isLoading = false
        loadingAgentID = nil
        loadingSessionID = nil
        selectingID = nil
        isCreating = false
        archivingID = nil
        folderSuggestions = nil
        isLoadingFolderSuggestions = false
        folderSuggestionErrorMessage = nil
        homePath = nil
        selectedWorkspaceIDsBySession.removeAll()
    }
}

/// One of a computer's projects, as a chat can be moved into it.
struct ChatProjectChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Reads a computer's projects and moves one chat into one of them.
///
/// Deliberately stateless: the Sessions list shows chats from more than one
/// agent, so filing a chat must not rewrite the shared
/// `HermesWorkspaceStore` catalog that the active project lives in.
@MainActor
protocol ChatProjectMoving: AnyObject {
    func projects(agentID: String) async throws -> [ChatProjectChoice]
    /// Moves `sessionID` into `projectID` and returns the project only when
    /// Hermes confirms the chat now sits there. Nil means it did not move.
    func move(sessionID: String, agentID: String, projectID: String) async throws -> ChatProjectChoice?
}

/// The stateless mover `HermesWorkspaceStore.chatProjectMover()` hands out.
@MainActor
final class HermesWorkspaceChatProjectMover: ChatProjectMoving {
    private let client: any HermesWorkspaceCatalogClient

    init(client: any HermesWorkspaceCatalogClient) {
        self.client = client
    }

    func projects(agentID: String) async throws -> [ChatProjectChoice] {
        try await client.load(agentID: agentID).workspaces.map {
            ChatProjectChoice(id: $0.id, name: $0.name)
        }
    }

    func move(sessionID: String, agentID: String, projectID: String) async throws -> ChatProjectChoice? {
        let selected = try await client.select(id: projectID, agentID: agentID, sessionID: sessionID)
        var confirmed = selected.sessionWorkspaceID == projectID ? selected : nil
        if confirmed == nil {
            // Link-era hosts acknowledge the selection without returning the
            // chat's anchor. Read it back before saying the chat moved.
            let readback = try await client.load(agentID: agentID, sessionID: sessionID)
            if readback.sessionWorkspaceID == projectID {
                confirmed = readback
            }
        }
        guard let confirmed,
              let project = confirmed.workspaces.first(where: { $0.id == projectID }) else {
            return nil
        }
        return ChatProjectChoice(id: project.id, name: project.name)
    }
}

extension HermesWorkspaceStore {
    /// Files one chat into a project without touching this store's catalog.
    func chatProjectMover() -> any ChatProjectMoving {
        HermesWorkspaceChatProjectMover(client: client)
    }
}
