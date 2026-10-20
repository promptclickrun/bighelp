import Foundation
import Testing
@testable import Bighelp

/// Loading the catalog: what the host lists is adopted at once and saved with the next
/// checkpoint, and the saved copy never brings back what the host no longer has.
@MainActor
struct SessionCatalogLoadTests {
    @Test func aChatTheHostRemovedStaysGoneWhenTheListIsReadAgainBeforeTheCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = SessionRecord(id: "archived-elsewhere", kind: .direct, agentIDs: ["default"],
            title: "Archived on another device", remoteStoredID: "stored-removed", remoteSource: "cli",
            hasAcceptedMessage: true)
        let repository = SessionContentRepository(directory: directory, name: "native-sessions-v2", currentSchemaVersion: 2)
        try repository.save([removed])
        let client = DemoSessionCatalogClient(records: [])
        let catalog = SessionCatalogStore(client: client, repository: repository, defaults: isolatedDefaults(),
                                          persistenceCheckpointDelay: .seconds(30))
        #expect(catalog.session(id: removed.id) != nil, "The saved copy lists it until the host says otherwise.")

        try await catalog.load(requireAuthoritativeRefresh: true)
        #expect(catalog.session(id: removed.id) == nil)
        #expect(catalog.hasUnsavedChanges, "The removal waits for the checkpoint; the saved copy is behind.")

        // The Sessions screen opens before the checkpoint: an ordinary load reads the list again.
        try await catalog.load()
        #expect(catalog.session(id: removed.id) == nil, "The saved copy must not bring it back.")

        catalog.flushPersistence()
        #expect(!catalog.hasUnsavedChanges)
        let reopened = SessionCatalogStore(client: client, repository:
            SessionContentRepository(directory: directory, name: "native-sessions-v2", currentSchemaVersion: 2),
            defaults: isolatedDefaults())
        #expect(reopened.records.isEmpty)
    }
}
