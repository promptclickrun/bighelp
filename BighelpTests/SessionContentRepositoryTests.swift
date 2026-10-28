import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SessionContentRepositoryTests {
    @Test(arguments: [false, true], ["", "Newer unsent draft 👨‍👨‍👦 e\u{301}"])
    func canonicalRefreshCannotRestoreReplacedDraftAfterColdLaunch(throughList: Bool, replacement: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SessionRecord(id: "draft-refresh", kind: .direct, agentIDs: ["default"],
            title: "Draft refresh", remoteStoredID: "stored", remoteSource: "cli",
            draft: "The already-sent warm-reopen prompt")
        let repository = SessionContentRepository(directory: directory)
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(records: [record]),
            records: [record], repository: repository, loadsRepositoryOnInit: false)
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: record.id)
        #expect(features.prepareNewChat(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else {
            Issue.record("Missing route-owned composer")
            return
        }
        model.draft = "The already-sent warm-reopen prompt"
        model.flushPersistence()
        catalog.flushPersistence()
        // The optional warm refresh captured this draft before Send cleared it
        // or the user replaced it. Its list/history response is still in flight.
        let source = try #require(catalog.session(id: record.id))
        #expect(source.draft == model.draft)
        model.draft = replacement
        model.flushPersistence()
        catalog.flushPersistence()
        #expect(try SessionContentRepository(directory: directory).loadSession(id: record.id)?.draft == replacement)

        let installed: SessionRecord
        if throughList {
            try await catalog.load(requireAuthoritativeRefresh: true)
            installed = try #require(catalog.session(id: record.id))
        } else {
            installed = try features.installSessionStateSnapshot(
                SessionHydrationPage(record: source, nextOffset: nil), source: source)
        }
        catalog.flushPersistence()

        #expect(model.draft == replacement)
        #expect(installed.draft == replacement)
        #expect(catalog.session(id: record.id)?.draft == replacement)
        let coldRepository = SessionContentRepository(directory: directory)
        let coldCatalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: coldRepository)
        let reopened = try coldCatalog.restoreSessionContent(id: record.id)
        #expect(reopened.draft == replacement)
        let coldFeatures = ShellFeatureStore(timing: .immediate, catalog: coldCatalog)
        #expect(coldFeatures.prepare(route))
        guard case .chat(let coldModel)? = coldFeatures.preparedModel(for: route) else {
            Issue.record("Missing cold-reopened composer")
            return
        }
        #expect(coldModel.draft == replacement)
    }

    @Test func canonicalDraftPreservationDoesNotCrossProfileOrTranscriptOwner() {
        let local = SessionRecord(id: "draft-owner", kind: .direct, agentIDs: ["default"],
            title: "Local", remoteStoredID: "stored", remoteSource: "cli", draft: "Private local draft")
        var foreignProfile = local
        foreignProfile.agentIDs = ["other"]
        var foreignTranscript = local
        foreignTranscript.remoteStoredID = "other-stored"
        var foreignSource = local
        foreignSource.remoteSource = "other-source"
        var foreignKind = local
        foreignKind.kind = .botMode
        for var incoming in [foreignProfile, foreignTranscript, foreignSource, foreignKind] {
            incoming.draft = "Other owner's draft"
            let merged = SessionCatalogReconciliation.merged(local: local, incoming: incoming,
                preferIncomingTranscript: true)
            #expect(merged.draft == incoming.draft)
        }
    }

    @Test func sessionSourceTreatsOnlyTheBighelpAndLocalLabelsAsTheSameChat() {
        // Hermes rewrites a Bot Chat's stored source to "local" on a peer refresh and the app's
        // resume stamps it back to "bighelp". Both labels name one chat.
        #expect(DirectHermesIdentity.sameSessionSource("bighelp", "local"))
        #expect(DirectHermesIdentity.sameSessionSource("local", "bighelp"))
        #expect(DirectHermesIdentity.sameSessionSource("bighelp", "bighelp"))
        #expect(DirectHermesIdentity.sameSessionSource("local", "local"))
        #expect(DirectHermesIdentity.sameSessionSource(nil, nil))
        #expect(!DirectHermesIdentity.sameSessionSource(nil, "bighelp"))
        #expect(!DirectHermesIdentity.sameSessionSource("local", nil))
        #expect(!DirectHermesIdentity.sameSessionSource("cli", "bighelp"))
        #expect(!DirectHermesIdentity.sameSessionSource("desktop", "local"))
        #expect(!DirectHermesIdentity.sameSessionSource("other-source", "cli"))
        #expect(DirectHermesIdentity.sameSessionSource("cli", "cli"))
    }

    @Test func aBotChatWhoseSourceFlipsBetweenBighelpAndLocalIsStillTheSameChat() {
        let roster = SessionSubagentRosterSnapshot(sessionID: "bot-chat", subagents: [], updatedAt: 5)
        let todos = SessionTodoSnapshot(sessionID: "bot-chat", revision: 3, todos: [], updatedAt: 1)
        let kept = TimelineItem(id: "kept", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Hermes")),
            content: .message("Reply that must survive the flip"), metadata: .init(delivery: "Saved", sourceOrder: 1))
        let local = SessionRecord(id: "bot-chat", kind: .direct, agentIDs: ["default"], title: "Bot Chat",
            remoteStoredID: "local-2b97e876", remoteSource: "bighelp",
            sessionTodos: todos, sessionSubagents: roster, parentSessionID: "parent-session",
            draft: "Half-typed message", items: [kept])
        var flipped = local
        flipped.remoteSource = "local"
        flipped.items = []
        flipped.draft = ""
        flipped.parentSessionID = nil
        flipped.sessionTodos = nil
        flipped.sessionSubagents = nil

        #expect(SessionCatalogReconciliation.hasSameDurableIdentity(local, flipped))
        #expect(SessionCatalogReconciliation.hasSameDurableIdentity(flipped, local))

        let merged = SessionCatalogReconciliation.merged(local: local, incoming: flipped)
        #expect(merged.draft == "Half-typed message")
        #expect(merged.parentSessionID == "parent-session")
        #expect(merged.items == [kept])
        #expect(merged.sessionTodos?.revision == 3)
        #expect(merged.sessionSubagents?.updatedAt == 5)

        let reconciled = SessionCatalogReconciliation.reconciled(local: [local], authoritativeIncoming: [flipped])
        #expect(reconciled.count == 1)
        #expect(reconciled.first?.draft == "Half-typed message")
    }

    @Test func aDifferentSourceStillMeansADifferentChat() {
        let local = SessionRecord(id: "chat", kind: .direct, agentIDs: ["default"], title: "Chat",
            remoteStoredID: "stored", remoteSource: "bighelp")
        for other in ["cli", "tui", "desktop", "other-source"] {
            var incoming = local
            incoming.remoteSource = other
            #expect(!SessionCatalogReconciliation.hasSameDurableIdentity(local, incoming))
        }
    }

    @Test func nativeSessionBridgeKeepsAStreamWhenHermesFlipsTheSourceLabel() {
        #expect(NativeWorkspaceSessionBridge.sameOrAdoptingSource("bighelp", "local"))
        #expect(NativeWorkspaceSessionBridge.sameOrAdoptingSource("local", "bighelp"))
        #expect(NativeWorkspaceSessionBridge.sameOrAdoptingSource(nil, "local"))
        #expect(!NativeWorkspaceSessionBridge.sameOrAdoptingSource("bighelp", "cli"))
        #expect(!NativeWorkspaceSessionBridge.sameOrAdoptingSource("local", nil))
    }

    @Test func aLocalSourceBotChatCanStillBeResumedNatively() throws {
        let summary = try #require(DirectHermesSessionSummary(
            .object(["id": .string("local-1d1b3370"), "source": .string("local"), "title": .string("Bot Chat")]),
            profile: "default"))
        #expect(summary.supportsNativeResume)
        let foreign = try #require(DirectHermesSessionSummary(
            .object(["id": .string("20261018_170901_d6b411"), "source": .string("telegram")]),
            profile: "default"))
        #expect(!foreign.supportsNativeResume)
    }

    @Test func nativeVersionedCheckpointsPreserveRecordedHistoryAndRejectLegacyWriters() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "native-sessions-v2"
        let repository = SessionContentRepository(directory: directory, name: name, currentSchemaVersion: 2)
        let event = ChatActivityEvent(
            eventID: "saved-tool", sessionID: "native-session", turnID: "saved-turn",
            kind: .tool, lifecycle: .recorded, title: "Recorded tool", summary: nil, detail: nil,
            occurredAt: 123, result: "Original result"
        )
        var record = SessionRecord(id: "native-session", kind: .direct, agentIDs: ["default"],
                                   title: "Native", draft: "Unsent", activityEvents: [event])
        try repository.save([record])
        record.draft = "Updated unsent draft"
        let checkpoint = try await repository.encodeSnapshot([record])
        try repository.saveEncoded(checkpoint)
        let reader = SessionContentRepository(directory: directory, name: name, currentSchemaVersion: 2)
        #expect(try reader.loadSession(id: record.id) == record)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == 2)
        for file in files {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(payload["schemaVersion"] as? Int == 2)
        }
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        let legacyWriter = SessionContentRepository(directory: directory, name: name)
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 2, current: 1)) {
            try legacyWriter.save([])
        }
        for file in files { #expect(try Data(contentsOf: file) == before[file]) }
        let legacyEncoding = try DemoRepository<[SessionRecord]>.encodeForSave([])
        #expect(throws: DemoRepositoryError.unsupportedSchemaVersion(found: 1, current: 2)) {
            try repository.saveEncoded(legacyEncoding)
        }
    }

    @Test func plainRepositoryProtocolCheckpointUsesConfiguredVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository: any SessionCatalogRepository = DemoRepository<[SessionRecord]>(
            directory: directory, name: "native-sessions", seed: [], currentSchemaVersion: 2
        )
        let record = SessionRecord(id: "native", kind: .direct, agentIDs: ["default"], title: "Native", draft: "Unsent")
        let encoded = try await repository.encodeSnapshot([record])
        try repository.saveEncoded(encoded)
        #expect(try repository.load() == [record])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let saved = try Data(contentsOf: #require(files.first))
        let payload = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(payload["schemaVersion"] as? Int == 2)
    }

    @Test func preparedPlainCheckpointRejectsReplacementAndAccountRetirement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        let record = SessionRecord(id: "retained", kind: .direct, agentIDs: ["default"], title: "Retained")
        try repository.save([record])
        let pending = try await repository.encodeSnapshot([])
        let file = directory.appending(path: "sessions-v1.json")
        let newer = try DemoRepository<[SessionRecord]>.encodeForSave([record], schemaVersion: 3)
        try newer.write(to: file, options: .atomic)
        #expect(throws: DemoRepositoryError.staleFileSnapshot) { try repository.saveEncoded(pending) }
        #expect(try Data(contentsOf: file) == newer)
        try DemoRepository<[SessionRecord]>.encodeForSave([record]).write(to: file, options: .atomic)
        let retired = try await repository.encodeSnapshot([])
        repository.resetForAccountBoundary()
        #expect(throws: DemoRepositoryError.staleFileSnapshot) { try repository.saveEncoded(retired) }
        #expect(try repository.load() == [record])
    }

    @Test func coldCatalogReadsMetadataAndLoadsOnlySelectedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionContentRepository(directory: directory)
        let first = SessionRecord(id: "first", kind: .direct, agentIDs: ["default"], title: "First", draft: "unsent draft")
        let second = SessionRecord(id: "second", kind: .direct, agentIDs: ["default"], title: "Second", draft: "other draft")
        try writer.save([first, second])
        let reader = SessionContentRepository(directory: directory)
        let catalog = try reader.load()
        #expect(reader.contentLoadCount == 0)
        #expect(catalog.allSatisfy { !$0.isContentLoaded && $0.draft.isEmpty })
        #expect(try reader.loadSession(id: first.id) == first)
        #expect(reader.contentLoadCount == 1)
        try reader.save(catalog)
        #expect(reader.contentWriteCount == 0)
        #expect(try reader.loadSession(id: second.id) == second)
    }

    @Test func legacyMigrationPreservesOriginalAndAccountBoundaryRejectsPendingCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionRecord(id: "legacy", kind: .direct, agentIDs: ["default"], title: "Legacy", draft: "preserve")
        let legacy = DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        try legacy.save([first])
        let file = directory.appending(path:"sessions-v1.json")
        let before = try Data(contentsOf:file)
        let repository = SessionContentRepository(directory: directory)
        let metadata = try repository.load()
        #expect(metadata.count == 1)
        #expect(try repository.loadSession(id:first.id) == first)
        #expect(try Data(contentsOf:file) == before)
        let pending = try await repository.encodeSnapshot(metadata)
        repository.resetForAccountBoundary()
        #expect(throws: (any Error).self) { try repository.saveEncoded(pending) }
        #expect(try repository.loadSession(id:first.id) == first)
    }

    @Test func updatingOneConversationDoesNotRewriteOtherTranscripts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionContentRepository(directory: directory, name: "sessions", scopeID: { "host-fixture" })
        let first = SessionRecord(id: "one", kind: .direct, agentIDs: ["default"], title: "First", draft: "first")
        var second = SessionRecord(id: "two", kind: .direct, agentIDs: ["default"], title: "Second", draft: "second")
        try repository.save([first, second])
        let initialWrites = repository.contentWriteCount
        second.draft = "updated second"
        try repository.save([first, second])
        #expect(repository.contentWriteCount == initialWrites + 1)
        #expect(try repository.loadSession(id: first.id) == first)
        #expect(try repository.loadSession(id: second.id) == second)
        let reopened = SessionContentRepository(directory: directory, name: "sessions", scopeID: { "host-fixture" })
        #expect(try reopened.loadSession(id: first.id) == first)
        #expect(try reopened.loadSession(id: second.id) == second)
    }
}
