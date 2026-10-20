import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SessionCatalogCacheAuthorityTests {
    @Test(arguments: [false, true], [false, true])
    func anOrdinaryLoadCannotResurrectAnAuthoritativelyEmptyCatalog(
        usesContentRepository: Bool, refreshFails: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = SessionRecord(id: "removed", kind: .direct, agentIDs: ["default"], title: "Removed chat")
        let repository: any SessionCatalogRepository = usesContentRepository
            ? SessionContentRepository(directory: directory)
            : DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        try repository.save([cached])
        let client = SessionCatalogFixtureClient()
        let catalog = SessionCatalogStore(client: client, repository: repository,
            defaults: isolatedDefaults(), persistenceCheckpointDelay: .seconds(3_600))
        defer { catalog.cancelPersistenceCheckpoint() }
        #expect(catalog.records.map(\.id) == [cached.id])

        try await catalog.load(requireAuthoritativeRefresh: true)
        #expect(catalog.records.isEmpty)
        #expect(catalog.hasUnsavedChanges)
        #expect(catalog.repositorySaveCount == 0)
        #expect(try repository.load().map(\.id) == [cached.id], "The old cache remains until the checkpoint.")

        client.setList(records: [], error: refreshFails ? .listUnavailable : nil)
        try await catalog.load()
        #expect(catalog.records.isEmpty, "A pending authoritative deletion outranks the older saved catalog.")
        #expect(catalog.repositorySaveCount == 0, "Loading must keep persistence deferred.")
        #expect((catalog.refreshErrorMessage != nil) == refreshFails)
        #expect(catalog.loadErrorMessage == nil)
        catalog.flushPersistence()
        #expect(catalog.repositorySaveCount == 1)
        #expect(!catalog.hasUnsavedChanges)

        let reopenedRepository: any SessionCatalogRepository = usesContentRepository
            ? SessionContentRepository(directory: directory)
            : DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        let reopened = SessionCatalogStore(client: SessionCatalogFixtureClient(), repository: reopenedRepository,
            defaults: isolatedDefaults())
        #expect(reopened.records.isEmpty)
        try await reopened.load()
        #expect(reopened.records.isEmpty)
        #expect(!reopened.hasUnsavedChanges)
    }

    @Test func aPendingRemovalKeepsTheRemainingChatsDraftAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = SessionRecord(id: "removed", kind: .direct, agentIDs: ["default"], title: "Removed chat")
        let retained = SessionRecord(id: "retained", kind: .direct, agentIDs: ["default"], title: "Retained chat",
            draft: "Unsent follow-up 👨‍👨‍👦 e\u{301}", items: [TimelineItem(id: "answer", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Avery")),
                content: .message("Complete retained answer"), metadata: .init(delivery: "Saved"))],
            hasAcceptedMessage: true)
        let writer = SessionContentRepository(directory: directory)
        try writer.save([removed, retained])
        let repository = SessionContentRepository(directory: directory)
        let client = SessionCatalogFixtureClient(records: [SessionRecord(id: retained.id, kind: .direct,
            agentIDs: ["default"], title: retained.title, hasAcceptedMessage: true)])
        let catalog = SessionCatalogStore(client: client, repository: repository,
            defaults: isolatedDefaults(), persistenceCheckpointDelay: .seconds(3_600))
        defer { catalog.cancelPersistenceCheckpoint() }
        try catalog.restoreSessionContent(id: retained.id)

        try await catalog.load(requireAuthoritativeRefresh: true)
        try await catalog.load()
        #expect(catalog.records.map(\.id) == [retained.id])
        #expect(catalog.session(id: retained.id)?.draft == retained.draft)
        #expect(catalog.session(id: retained.id)?.items == retained.items)
        #expect(catalog.repositorySaveCount == 0)
        catalog.flushPersistence()

        let reopened = SessionContentRepository(directory: directory)
        #expect(try reopened.load().map(\.id) == [retained.id])
        #expect(try reopened.loadSession(id: retained.id)?.draft == retained.draft)
        #expect(try reopened.loadSession(id: retained.id)?.items == retained.items)
    }
}
