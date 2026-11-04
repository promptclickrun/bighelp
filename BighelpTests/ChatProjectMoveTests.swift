import Foundation
import Testing
@testable import Bighelp

/// Move to Project…: a chat moves only once Hermes confirms it, and then the chat list, the
/// open chat and File changes read the new project at once.
@MainActor
struct ChatProjectMoveTests {
    @Test func aMoveRecordsTheChatsProjectWithoutChangingTheShownCatalog() async throws {
        let store = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await store.load(agentID: "default")
        let shown = store.catalog

        // A chat in Chats can belong to another agent than the one the store shows.
        let project = try await store.moveSession("chat-move-1", agentID: "research", to: "home")

        #expect(project.id == "home")
        #expect(store.workspaceID(forSessionID: "chat-move-1") == "home")
        #expect(store.catalogAgentID == "default")
        #expect(store.catalog == shown)
    }

    @Test func aMoveHermesDoesNotConfirmChangesNothing() async {
        let store = HermesWorkspaceStore(client: UnconfirmedMoveClient())
        store.reconcileSessionWorkspace(id: "notes", sessionID: "chat-move-2")

        await #expect(throws: WorkspaceClientError.outcomeUnknown) {
            try await store.moveSession("chat-move-2", agentID: "default", to: "garden")
        }
        #expect(store.workspaceID(forSessionID: "chat-move-2") == "notes")
    }

    @Test func aConfirmedMoveShowsInTheChatListAndTheOpenChat() async throws {
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient())
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        try await catalog.load()
        let session = try await catalog.refreshExistingSession(id: "demo-tool-folder-anchor")
        #expect(features.prepare(.chat(conversationID: session.id)))
        let model = try #require(features.preparedChatModel(id: session.id))

        features.recordMovedProject(
            HermesWorkspaceSummary(id: "garden", name: "Garden", description: "", folderCount: 1, isActive: false),
            sessionID: session.id
        )

        #expect(catalog.session(id: session.id)?.workspaceID == "garden")
        #expect(catalog.session(id: session.id)?.workspaceName == "Garden")
        #expect(model.sessionWorkspaceID == "garden")
        #expect(model.sessionWorkspaceName == "Garden")
    }

    @Test func launchDeletesWhatPerChatBackgroundsSaved() throws {
        let suite = "chat-appearance-cleanup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dataDirectory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let photos = dataDirectory.appending(path: "session-appearance/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: photos.appending(path: "photo.jpg"))
        defaults.set(Data("{}".utf8), forKey: "loopdy.session-appearance.v1.abc")
        defaults.set(Data("{}".utf8), forKey: "loopdy.session-appearance.v1.abc.transaction")
        defaults.set(true, forKey: "loopdy.chat.showProjectChanges")

        RetiredChatAppearance.removeSavedData(defaults: defaults, dataDirectory: dataDirectory)

        #expect(defaults.object(forKey: "loopdy.session-appearance.v1.abc") == nil)
        #expect(defaults.object(forKey: "loopdy.session-appearance.v1.abc.transaction") == nil)
        #expect(defaults.bool(forKey: "loopdy.chat.showProjectChanges"), "Other settings stay")
        #expect(!FileManager.default.fileExists(atPath: dataDirectory.appending(path: "session-appearance").path))
        #expect(FileManager.default.fileExists(atPath: dataDirectory.path), "Only the backgrounds' folder goes")
    }
}

/// Hermes answers the move with the chat still in another project.
@MainActor
private final class UnconfirmedMoveClient: HermesWorkspaceCatalogClient {
    private let catalog = HermesWorkspaceCatalog(activeWorkspaceID: nil, workspaces: [
        HermesWorkspaceSummary(id: "notes", name: "Notes", description: "", folderCount: 1, isActive: false),
        HermesWorkspaceSummary(id: "garden", name: "Garden", description: "", folderCount: 1, isActive: false),
    ])

    func load(agentID: String) async throws -> HermesWorkspaceCatalog { catalog }

    func select(id: String, agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        HermesWorkspaceCatalog(activeWorkspaceID: nil, sessionWorkspaceID: "notes", workspaces: catalog.workspaces)
    }

    func create(name: String, folderPath: String, agentID: String) async throws -> HermesWorkspaceCatalog { catalog }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog { catalog }

    func folderSuggestions(parentPath: String, prefix: String, offset: Int, limit: Int,
                           agentID: String) async throws -> HermesWorkspaceFolderPage {
        HermesWorkspaceFolderPage(parentPath: parentPath, folders: [], nextOffset: nil)
    }
}
