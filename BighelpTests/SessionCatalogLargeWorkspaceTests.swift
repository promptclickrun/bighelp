import Foundation
import Testing
@testable import Bighelp

/// A computer that runs scheduled tasks lists one chat per run, so a catalog of a few
/// thousand chats is normal. Hermes says `sessions.changed` after every run, and each
/// one refreshes the list; typing in the open chat checkpoints it too. Neither may
/// walk or rewrite the whole catalog on the main actor.
@MainActor
@Suite(.serialized)
struct SessionCatalogLargeWorkspaceTests {
    private static let scheduledChatCount = 4_350
    private static let openChatID = "open-chat"

    @Test func aListRefreshWithNothingNewStaysCheapAndWritesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try Self.makeWorkspace(in: directory)
        let catalog = workspace.catalog
        try await catalog.load(requireAuthoritativeRefresh: true)
        catalog.flushPersistence()
        let savesBefore = catalog.repositorySaveCount
        let contentWritesBefore = workspace.repository.contentWriteCount

        let start = ContinuousClock.now
        try await catalog.load(requireAuthoritativeRefresh: true)
        let elapsed = ContinuousClock.now - start
        print("LARGE_WORKSPACE_REFRESH chats=\(catalog.records.count) elapsed=\(elapsed)"
            + " saves=\(catalog.repositorySaveCount - savesBefore)"
            + " contentWrites=\(workspace.repository.contentWriteCount - contentWritesBefore)")
        #expect(catalog.records.count == Self.scheduledChatCount + 1)
        #expect(catalog.repositorySaveCount == savesBefore,
                "A refresh that found nothing new must not rewrite the catalog.")
        #expect(workspace.repository.contentWriteCount == contentWritesBefore)
        #expect(!catalog.hasUnsavedChanges)
        #expect(elapsed < .milliseconds(500),
                "Reconciling the host's list must be linear in the number of chats.")
        #expect(catalog.session(id: Self.openChatID)?.items.count == Self.openChatItems.count,
                "The open chat keeps its loaded transcript through a refresh.")
    }

    @Test func typingInTheOpenChatCheckpointsOnlyThatChatWithoutStallingTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try Self.makeWorkspace(in: directory, checkpointDelay: .milliseconds(500))
        let catalog = workspace.catalog
        try await catalog.load(requireAuthoritativeRefresh: true)
        catalog.flushPersistence()
        let savesBefore = catalog.repositorySaveCount
        let contentWritesBefore = workspace.repository.contentWriteCount

        var maximumGap: Duration = .zero
        let probe = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, now - previous)
                previous = now
            }
        }
        let typed = "Please summarize what the last scheduled run found"
        for length in 1...typed.count {
            catalog.updateChatSnapshot(draft: String(typed.prefix(length)), items: Self.openChatItems,
                activityEvents: Self.openChatEvents, activityVisibility: nil, for: Self.openChatID)
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<400 where catalog.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(50)) }
        probe.cancel()
        await probe.value
        let saves = catalog.repositorySaveCount - savesBefore
        let contentWrites = workspace.repository.contentWriteCount - contentWritesBefore
        print("LARGE_WORKSPACE_TYPING maximumMainActorGap=\(maximumGap) saves=\(saves) contentWrites=\(contentWrites)"
            + " error=\(catalog.persistenceErrorMessage ?? "none")")
        #expect(saves >= 1 && saves <= 4, "Typing coalesces into a few checkpoints, never one per key.")
        #expect(contentWrites == saves, "Only the chat being typed in is rewritten.")
        #expect(!catalog.hasUnsavedChanges)
        #expect(maximumGap < .milliseconds(100), "A checkpoint must leave typing responsive.")
        #expect(try SessionContentRepository(directory: directory, name: "native-sessions-v2", currentSchemaVersion: 2)
            .loadSession(id: Self.openChatID)?.draft == typed)
    }

    @Test func aLargeAutomaticCheckpointLeavesTheMainActorResponsive() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SessionRecord(id: "large", kind: .direct, agentIDs: ["default"], title: "Long history",
            items: (0..<20_000).map { Self.message("answer-\($0)", role: .assistant,
                text: String(repeating: "Full retained answer. ", count: 100)) }, hasAcceptedMessage: true)
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [record])
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository,
                                          defaults: isolatedDefaults())
        var maximumGap: Duration = .zero
        let probe = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, now - previous)
                previous = now
            }
        }
        catalog.reconcileSessionContext(.init(sessionId: "large", model: "hermes", contextUsed: 1,
            contextMax: 100, contextPercent: 1, compressions: 0, isCompacting: false, updatedAt: 1))
        try await Task.sleep(for: .seconds(3))
        probe.cancel()
        await probe.value
        print("LARGE_CATALOG_CHECKPOINT maximumMainActorGap=\(maximumGap) writes=\(catalog.repositorySaveCount)")
        #expect(catalog.repositorySaveCount == 1)
        #expect(maximumGap < .milliseconds(100), "Encoding long histories must leave typing and navigation responsive.")
        #expect(try repository.load().first?.items.count == 20_000)
    }

    // MARK: - Fixture

    private struct Workspace {
        let catalog: SessionCatalogStore
        let repository: SessionContentRepository
    }

    /// The catalog as a relaunch finds it: every chat saved as metadata, the open chat's
    /// transcript loaded, and a host that lists the same chats with a one-line preview.
    private static func makeWorkspace(in directory: URL, checkpointDelay: Duration = .seconds(2)) throws -> Workspace {
        let saved = scheduledChats(preview: false) + [openChat]
        let seeded = SessionContentRepository(directory: directory, name: "native-sessions-v2", currentSchemaVersion: 2)
        try seeded.save(saved)
        let repository = SessionContentRepository(directory: directory, name: "native-sessions-v2", currentSchemaVersion: 2)
        let catalog = SessionCatalogStore(
            client: DemoSessionCatalogClient(records: scheduledChats(preview: true) + [openChatListRow]),
            repository: repository, defaults: isolatedDefaults(), persistenceCheckpointDelay: checkpointDelay)
        try catalog.restoreSessionContent(id: openChatID)
        return Workspace(catalog: catalog, repository: repository)
    }

    /// The host's list rows carry the last line as `catalogPreview` and no items.
    private static func scheduledChats(preview: Bool) -> [SessionRecord] {
        (0..<scheduledChatCount).map { index in
            let at = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index) * 900)
            var record = SessionRecord(id: "session-\(index)", kind: .direct, agentIDs: ["default"],
                title: "Scheduled run \(index)", remoteStoredID: "stored-\(index)",
                remoteSource: index % 5 == 0 ? "telegram" : "cron",
                createdAt: at, updatedAt: at, hasAcceptedMessage: true)
            if preview { record.catalogPreview = "Run \(index) finished." }
            return record
        }
    }

    private static let openChatItems: [TimelineItem] = (0..<2_000).map {
        message("answer-\($0)", role: $0 % 2 == 0 ? .human : .assistant,
                text: String(repeating: "A long retained answer with every detail kept. ", count: 40))
    }

    private static let openChatEvents: [ChatActivityEvent] = (0..<500).map { index in
        ChatActivityEvent(eventID: "tool-\(index)", sessionID: openChatID, turnID: "turn-\(index / 4)", kind: .tool,
            lifecycle: .succeeded, title: "Read", summary: "Complete", detail: "Result \(index)",
            occurredAt: index, toolCallID: "call-\(index)", toolName: "read_file")
    }

    private static let openChat = SessionRecord(id: openChatID, kind: .direct, agentIDs: ["default"],
        title: "Morning plan", remoteStoredID: "stored-open", remoteSource: "cli", items: openChatItems,
        activityEvents: openChatEvents, createdAt: Date(timeIntervalSince1970: 1_705_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_705_000_000), hasAcceptedMessage: true)

    private static let openChatListRow: SessionRecord = {
        var row = SessionRecord(id: openChatID, kind: .direct, agentIDs: ["default"],
            title: "Morning plan", remoteStoredID: "stored-open", remoteSource: "cli",
            createdAt: Date(timeIntervalSince1970: 1_705_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_705_000_000), hasAcceptedMessage: true)
        row.catalogPreview = "A long retained answer with every detail kept."
        return row
    }()

    private static func message(_ id: String, role: TimelineRole, text: String) -> TimelineItem {
        TimelineItem(
            id: id,
            role: role,
            sender: role == .human
                ? .user(snapshot: .init(name: "You"))
                : .agent(id: "default", snapshot: .init(name: "Avery")),
            content: .message(text),
            metadata: .init(delivery: "Saved")
        )
    }
}
