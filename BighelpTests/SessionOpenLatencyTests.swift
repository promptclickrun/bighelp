import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SessionOpenLatencyTests {
    @Test func leavingTheOnlyNavigationObserverStillFinishesHydrationOffscreen() async throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        model.draft = "Draft stays mine"
        let handle = try features.startNavigationHydration(id: client.record.id)
        let observer = Task { try await handle.value() }
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        observer.cancel()
        features.retainModels(ownedBy: [])
        await #expect(throws: CancellationError.self) { try await observer.value }
        #expect(model.isHydratingHistory)
        let joined = try features.startNavigationHydration(id: client.record.id)
        #expect(joined.id == handle.id)
        client.release()
        let result = try await joined.value()
        #expect(!client.cancelled)
        #expect(client.calls == 1)
        #expect(result.items.last?.content == .message("Canonical answer"))
        #expect(model.items.last?.content == .message("Canonical answer"))
        #expect(model.draft == "Draft stays mine")
        #expect(!model.isHydratingHistory)
        guard case .chat(let retained)? = features.preparedModel(for: route) else { Issue.record("Lost offscreen model"); return }
        #expect(retained === model)
    }

    @Test func warmNavigationRequiresCompletedHydrationAndReusesTheCurrentModel() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "warm-navigation"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog,
            navigationWorkspaceOwner: { owner }, nativeWarmSessionIsCurrent: { _, _ in true })
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        #expect(!features.canReturnToWarmSession(id: client.record.id))
        let handle = try features.startNavigationHydration(id: client.record.id)
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        client.release()
        _ = try await handle.value()
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        features.retainModels(ownedBy: [])
        #expect(features.canReturnToWarmSession(id: client.record.id))
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            #expect(try features.prepareCachedForUserNavigation(route))
            _ = try await features.startNavigationHydration(id: client.record.id).value()
        }
        #expect(elapsed < .seconds(2))
        #expect(client.calls == 1)
        #expect(!model.isHydratingHistory)
        guard case .chat(let retained)? = features.preparedModel(for: route) else { Issue.record("Lost warm model"); return }
        #expect(retained === model)
        features.cancelNavigationHydrations()
        #expect(!features.canReturnToWarmSession(id: client.record.id))
    }

    @Test func aReconnectDuringAnOpenOpensTheChatAgainOnTheNewConnection() async throws {
        let connection = HeldConnection(id: "reconnect-during-open")
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, navigationWorkspaceOwner: { connection.owner })
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        let first = try features.startNavigationHydration(id: client.record.id)
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }

        // The app reconnects (a new connection, the same sign-in) while the history read is out.
        connection.reconnect()
        client.release()
        await #expect(throws: CancellationError.self) { try await first.value() }

        // The chat isn't left without a connection of its own: it opens again on the new one.
        for _ in 0..<100 where client.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.calls == 2)
        let again = try features.startNavigationHydration(id: client.record.id)
        client.release()
        _ = try await again.value()
        #expect(client.calls == 2)
        #expect(model.items.last?.content == .message("Canonical answer"))
        #expect(!model.isHydratingHistory)
    }

    @Test func aChatOpenedWhileTheHostWasAwayOpensOnceTheConnectionReturns() async throws {
        let connection = HeldConnection(id: "opened-while-away")
        connection.owner = nil
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, navigationWorkspaceOwner: { connection.owner })
        let route = AppRoute.chat(conversationID: client.record.id)
        // The saved copy shows while the host is away; there is no connection to open it on.
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        #expect(throws: CancellationError.self) { try features.startNavigationHydration(id: client.record.id) }

        connection.reconnect()
        features.openDetachedChat(id: client.record.id)
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.calls == 1)
        client.release()
        _ = try await features.startNavigationHydration(id: client.record.id).value()
        #expect(model.items.last?.content == .message("Canonical answer"))
        // Opened on this connection, it isn't opened a second time.
        features.openDetachedChat(id: client.record.id)
        for _ in 0..<10 { await Task.yield() }
        #expect(client.calls == 1)
    }

    @Test func navigationDeadlineReleasesItsFooterAndRejectsLateHistory() async throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, navigationHydrationTimeout: .milliseconds(30))
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        let handle = try features.startNavigationHydration(id: client.record.id)
        await #expect(throws: CancellationError.self) { try await handle.value() }
        #expect(!model.isHydratingHistory)
        client.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(catalog.session(id: client.record.id)?.items.isEmpty == true)
    }

    @Test func nativeWarmRetentionKeepsFourSafeIdleModelsAndProtectsHydration() throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "warm-capacity"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let records = (0..<7).map { SessionRecord(id: "warm-\($0)", kind: .direct, agentIDs: ["default"], title: "Saved") }
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: records)
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, navigationWorkspaceOwner: { owner })
        for record in records {
            let route = AppRoute.chat(conversationID: record.id)
            #expect(try features.prepareCachedForUserNavigation(route))
            if record.id == records.first?.id, case .chat(let model)? = features.preparedModel(for: route) {
                model.beginHistoryHydration(from: record)
            }
            features.retainModels(ownedBy: [])
        }
        let retained = records.filter { features.preparedModel(for: .chat(conversationID: $0.id)) != nil }.map(\.id)
        #expect(retained == ["warm-0", "warm-3", "warm-4", "warm-5", "warm-6"])
        features.resetForAccountBoundary()
        #expect(records.allSatisfy { features.preparedModel(for: .chat(conversationID: $0.id)) == nil })
    }

    @Test func leavingHydratingChatKeepsItsExactModelAndDraft() throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else {
            Issue.record("No initial model"); return
        }
        model.beginHistoryHydration(from: client.record)
        model.draft = "Keep this draft while I leave"
        #expect(!model.isSending)
        features.retainModels(ownedBy: [])
        guard case .chat(let retained)? = features.preparedModel(for: route) else {
            Issue.record("Navigation discarded the still-hydrating model"); return
        }
        #expect(retained === model)
        #expect(retained.draft == "Keep this draft while I leave")
        #expect(retained.isHydratingHistory)
    }

    @Test func cachedMountDoesNotReconcileAnOlderCatalogOverLiveText() throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: client.record.id)
        #expect(try features.prepareCachedForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No model"); return }
        model.acceptExternal([TimelineItem(id: "live", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Hermes")), content: .message("New live text"),
            metadata: .init(delivery: "Streaming"))])
        #expect(try features.prepareCachedForUserNavigation(route))
        #expect(model.items.last?.content == .message("New live text"))
    }

    @Test func simultaneousOpensShareHistoryAndOneCancelledReaderDoesNotCancelAnother() async throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let first = Task { try await catalog.hydrateInitialPage(id: client.record.id) }
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await catalog.hydrateInitialPage(id: client.record.id) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(client.calls == 1)
        client.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await second.value
        #expect(result.items.last?.content == .message("Canonical answer"))
        #expect(!client.cancelled)
        catalog.flushPersistence()
    }

    @Test func retiredHistoryCannotOverwriteTheCacheOrNewOpen() async throws {
        let client = HeldSessionPageClient()
        let catalog = SessionCatalogStore(client: client, records: [client.record])
        let first = Task { try await catalog.hydrateInitialPage(id: client.record.id) }
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        catalog.cancelHistoryRefreshes()
        client.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(catalog.session(id: client.record.id)?.items.isEmpty == true)
        let second = Task { try await catalog.hydrateInitialPage(id: client.record.id) }
        for _ in 0..<100 where client.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        client.release()
        _ = try await second.value
        #expect(client.calls == 2)
    }

    @Test func cachedOwnerAndDraftAreAvailableWhileHistoryIsHeld() async throws {
        let client = HeldSessionPageClient()
        var record = client.record
        record.draft = "Unsent draft"
        record.items = [TimelineItem(id: "cached-answer", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Hermes")), content: .message("Cached answer"), metadata: .init(source: "Fixture", delivery: "Saved"))]
        let catalog = SessionCatalogStore(client: client, records: [record])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: record.id)
        #expect(try features.prepareForUserNavigation(route))
        guard case .chat(let model)? = features.preparedModel(for: route) else { Issue.record("No cached owner"); return }
        model.beginHistoryHydration(from: record)
        let refresh = Task { try await catalog.hydrateInitialPage(id: record.id) }
        for _ in 0..<100 where client.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.items.first?.content == .message("Cached answer"))
        #expect(model.draft == "Unsent draft")
        model.draft = "Edited during refresh"
        client.release()
        _ = try await refresh.value
        #expect(features.prepare(route))
        #expect(model.draft == "Edited during refresh")
        guard case .chat(let retained)? = features.preparedModel(for: route) else { Issue.record("Lost cached owner"); return }
        #expect(retained === model)
    }
}

/// The host connection a test changes: `reconnect()` is a new connection with the same sign-in.
@MainActor
private final class HeldConnection {
    private let authority: WorkspaceAuthority
    private let signIn = UUID()
    var owner: WorkspaceOwner?

    init(id: String) {
        authority = try! .fixture(id: id)
        reconnect()
    }

    func reconnect() {
        owner = WorkspaceOwner(authority: authority, authenticationGeneration: signIn, connectionGeneration: UUID())
    }
}

@MainActor
private final class HeldSessionPageClient: SessionCatalogClient {
    var canDeleteConversation: Bool { false }
    var record = SessionRecord(id: "held-session", kind: .direct, agentIDs: ["default"], title: "Saved")
    var calls = 0
    var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func list() async throws -> [SessionRecord] { [record] }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord { record }
    func delete(_ record: SessionRecord) async throws {}
    func hydratePage(_ record: SessionRecord, offset: Int?, turnLimit: Int) async throws -> SessionHydrationPage {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        cancelled = Task.isCancelled
        var page = record
        page.items = [TimelineItem(id: "canonical-answer", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Hermes")), content: .message("Canonical answer"), metadata: .init(source: "Fixture", delivery: "Saved"))]
        return SessionHydrationPage(record: page, nextOffset: nil)
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}
