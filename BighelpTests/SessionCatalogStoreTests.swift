import Foundation
import Observation
import Testing
@testable import Bighelp

@MainActor
struct SessionCatalogStoreTests {
    @Test func newMessageReordersBothListsAndSurvivesCatalogReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = SessionRecord(id: "old-used", kind: .direct, agentIDs: ["finance"], title: "Old chat",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), hasAcceptedMessage: true)
        let newer = SessionRecord(id: "new-created", kind: .direct, agentIDs: ["finance"], title: "New chat",
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100), hasAcceptedMessage: true)
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [old, newer])
        let defaults = isolatedDefaults()
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository, defaults: defaults)
        #expect(catalog.recentSummaries.map(\.id) == ["new-created", "old-used"])
        catalog.replaceItems([Self.message("incoming", role: .assistant, text: "A new answer")], for: old.id)
        catalog.flushPersistence()
        for store in [catalog, SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository, defaults: defaults)] {
            let model = SessionsModel(fixtures: store.presentedRecords, calendar: Calendar(identifier: .gregorian))
            #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["old-used", "new-created"])
            #expect(store.recentSummaries.map(\.id) == ["old-used", "new-created"], "☰'s recent chats too")
            #expect(store.session(id: old.id)?.createdAt == old.createdAt)
        }
    }

    @Test func canonicalEventRefinementDoesNotCreateASecondWorkTrailIdentity() throws {
        let original = ChatActivityEvent(eventID: "stored-result-row", sessionID: "chat", turnID: "stored-turn",
            kind: .tool, lifecycle: .recorded, title: "Read", summary: nil, detail: nil, occurredAt: 1,
            result: "Recorded result", sourceOrder: 1)
        let otherTurn = ChatActivityEvent(eventID: "stored-result-row", sessionID: "chat", turnID: "another-turn",
            kind: .tool, lifecycle: .recorded, title: "Other", summary: nil, detail: nil, occurredAt: 1,
            result: "Keep this separate source", sourceOrder: 0)
        let refined = ChatActivityEvent(eventID: "stored-result-row", sessionID: "chat", turnID: "stored-turn",
            kind: .tool, lifecycle: .recorded, title: "Read", summary: nil, detail: nil, occurredAt: 2,
            toolCallID: "now-resolved-call", result: "Recorded result", sourceOrder: 3)
        let between = TimelineItem(id: "between", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Hermes")),
            content: .message("Keep this message in place"), metadata: .init(delivery: "Saved", sourceOrder: 2))
        let source = SessionRecord(id: "chat", kind: .direct, agentIDs: ["default"], title: "Chat",
            remoteStoredID: "stored", remoteSource: "tui", items: [between], activityEvents: [original, otherTurn])
        var incoming = source
        incoming.activityEvents = [refined]
        let store = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [source])
        let result = try store.installSessionStateSnapshot(.init(record: incoming, nextOffset: nil), source: source)
        #expect(result.activityEvents.count == 2)
        #expect(result.activityEvents.contains(refined))
        #expect(result.activityEvents.contains(otherTurn))
        let entries = ChatTranscriptProjection.entries(items: result.items, activityEvents: result.activityEvents,
            visibility: .default, isBotMode: false)
        let display = ChatCompletedTurnProjection.rows(from: entries, isSending: true, enabled: true)
        let canvas = ChatCanvasTranscriptProjection.rows(from: display, disclosures: ChatActivityDisclosureStore())
        #expect(Set(canvas.map(\.id)).count == canvas.count)
    }

    @Test func repeatedRecordedHistoryNeverInventsRunningWork() {
        let original = ChatActivityEvent(eventID: "history", sessionID: "chat", turnID: "turn", kind: .tool,
            lifecycle: .recorded, title: "Tool", summary: "History", detail: nil, occurredAt: 1)
        let refreshed = ChatActivityEvent(eventID: "history", sessionID: "chat", turnID: "turn", kind: .tool,
            lifecycle: .recorded, title: "Tool", summary: "Recorded history", detail: "Full detail", occurredAt: 2)
        let ledger = ChatActivityLedger(sessionID: "chat", events: [original, refreshed])
        #expect(ledger.allEvents.count == 1)
        #expect(ledger.allEvents.first?.lifecycle == .recorded)
        #expect(ledger.allEvents.first?.detail == "Full detail")
    }

    @Test func confirmedGroupDeletionRemovesItsChatProjectionOnly() {
        let room = SessionRecord(id: "hermes-room:group", kind: .botMode, agentIDs: ["default"],
            title: "Group", remoteSource: "hermes-room", botModeRoomID: "group")
        let unrelated = SessionRecord(id: "other", kind: .direct, agentIDs: ["default"], title: "Keep")
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [room, unrelated])
        catalog.setPresentationDeferred(true)
        catalog.removeConfirmedHostedGroup(roomID: "group")
        #expect(catalog.session(id: room.id) == nil)
        #expect(catalog.presentedRecords.map(\.id) == ["other"])
    }

    @Test func presentationPublishesOnlyAfterCanonicalSnapshotIsInstalled() throws {
        let source=SessionRecord(id:"chat",kind:.direct,agentIDs:["default"],title:"Chat")
        let store=SessionCatalogStore(client:DemoSessionCatalogClient(),records:[source])
        var observed=false
        store.onLivePresentation = { record, live, owner in
            #expect(store.session(id:record.id)?.title == "Hydrated")
            #expect(live["complete"]?.boolean == true)
            #expect(owner == "exact-owner")
            observed=true
        }
        var incoming=source; incoming.title="Hydrated"
        let page=SessionHydrationPage(record:incoming,nextOffset:nil,livePresentation:["complete":.boolean(true)],presentationOwner:"exact-owner")
        _ = try store.installSessionStateSnapshot(page,source:source)
        #expect(observed)
    }

    @Test func canonicalToolSnapshotReconcilesLiveTurnWithoutDuplicateCall() throws {
        let live = ChatActivityEvent(eventID:"live-event",sessionID:"chat",turnID:"live-turn",kind:.tool,
            lifecycle:.running,title:"Read",summary:nil,detail:nil,occurredAt:1,toolCallID:"same-call")
        let canonical = ChatActivityEvent(eventID:"saved-event",sessionID:"chat",turnID:"history-turn-1",kind:.tool,
            lifecycle:.succeeded,title:"Read",summary:nil,detail:"Complete",occurredAt:1,toolCallID:"same-call")
        let source=SessionRecord(id:"chat",kind:.direct,agentIDs:["default"],title:"Chat",remoteStoredID:"stored",remoteSource:"loopdy",activityEvents:[live])
        var incoming=source
        incoming.activityEvents=[canonical]
        let store=SessionCatalogStore(client:DemoSessionCatalogClient(),records:[source])
        let result=try store.installSessionStateSnapshot(.init(record:incoming,nextOffset:nil),source:source)
        #expect(result.activityEvents.count == 1)
        #expect(result.activityEvents.first?.lifecycle == .succeeded)
        #expect(result.activityEvents.first?.turnID == "history-turn-1")
    }

    @Test func historicalCatchUpPublishesHomeAndSidebarOnceWithoutReplayingOldWork() {
        let parent = SessionRecord(id: "parent", kind: .direct, agentIDs: ["finance"], title: "Finished chat",
            items: [Self.message("old", role: .assistant, text: "Done")], hasAcceptedMessage: true)
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [parent])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        features.setChatPresentationDeferred(true)
        var invalidated = false
        withObservationTracking {
            _ = catalog.recentSummaries
            _ = features.dashboardModel.workInFlightItems
        } onChange: { MainActor.assumeIsolated { invalidated = true } }
        let child = SessionSubagentSnapshot(id: "worker", sessionID: "child", parentID: parent.id,
            role: "worker", goal: "Historical work", startedAt: 1)
        features.acceptSessionSubagents(.init(sessionID: parent.id, subagents: [child], updatedAt: 1))
        #expect(!invalidated, "Historical delivery must not rebuild Home and sidebar for each replayed event.")
        #expect(features.dashboardModel.workInFlightItems.isEmpty, "Do not flash already-completed historical work as a new live task.")
        let attention = DashboardAttentionItem(id: "attention", title: "Open child", detail: "Current request",
            urgency: .needsReview, sessionID: child.sessionID, agentID: "finance")
        #expect(features.dashboardModel.session(for: attention)?.id == child.sessionID,
                "Opening a current attention request must resolve canonical state, even while presentation is deferred.")
        features.acceptSessionSubagents(.init(sessionID: parent.id, subagents: [], updatedAt: 2))
        features.acceptExternal([Self.message("new", role: .assistant, text: "Caught-up answer")], conversationID: parent.id)
        #expect(catalog.session(id: parent.id)?.items.last?.id == "new", "Canonical routing stays current during catch-up.")
        features.setChatPresentationDeferred(false)
        #expect(invalidated)
        #expect(features.dashboardModel.workInFlightItems.isEmpty)
        #expect(catalog.recentSummaries.count == 1)
    }

    @Test(arguments: [false, true])
    func reopeningWithQueuedFinalAnswersUsesOneCatalogCheckpoint(mounted: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SessionRecord(id: "replay", kind: .direct, agentIDs: ["finance"], title: "Idle history",
            items: (0..<1_000).map { Self.message("old-\($0)", role: .assistant,
                text: String(repeating: "Retained history. ", count: 100)) }, hasAcceptedMessage: true)
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [record])
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository,
                                          defaults: isolatedDefaults())
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        features.setChatPresentationDeferred(true)
        if mounted { #expect(features.prepare(.chat(conversationID: record.id))) }
        let before = catalog.repositorySaveCount
        let start = ContinuousClock.now
        for index in 0..<40 {
            features.acceptExternal([Self.message("queued-\(index)", role: .assistant, text: "Finished answer")],
                                    conversationID: record.id)
        }
        print("QUEUED_FINAL_REPLAY mounted=\(mounted) elapsed=\(ContinuousClock.now - start) writes=\(catalog.repositorySaveCount - before)")
        #expect(catalog.repositorySaveCount == before, "Reopening must not synchronously serialize every retained chat for each queued final.")
        features.setChatPresentationDeferred(false)
        let saved = try #require(repository.load().first)
        #expect(saved.items.count == 1_040)
        #expect(saved.items.suffix(40).map(\.id) == (0..<40).map { "queued-\($0)" })
        #expect(catalog.repositorySaveCount == before + 1)
        #expect(!catalog.hasUnsavedChanges)
    }

    @Test func reopeningWithCompletedSubagentsBatchesTheirDiscoveryAndTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = SessionRecord(id: "parent", kind: .direct, agentIDs: ["finance"], title: "Finished chat")
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [parent])
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository,
                                          defaults: isolatedDefaults())
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        features.setChatPresentationDeferred(true)
        for index in 0..<20 {
            let child = SessionSubagentSnapshot(id: "worker-\(index)", sessionID: "child-\(index)",
                parentID: parent.id, role: "worker", goal: "Completed task", startedAt: index * 2 + 1)
            features.acceptSessionSubagents(.init(sessionID: parent.id, subagents: [child], updatedAt: index * 2 + 1))
            features.acceptSessionSubagents(.init(sessionID: parent.id, subagents: [], updatedAt: index * 2 + 2))
        }
        #expect(catalog.repositorySaveCount == 0, "Queued rosters must share the same catch-up checkpoint as final answers.")
        features.setChatPresentationDeferred(false)
        let saved = try repository.load()
        #expect(saved.count == 21)
        #expect(saved.allSatisfy { !$0.hasActiveWork })
        #expect(saved.filter { $0.parentSessionID == parent.id }.count == 20)
        #expect(catalog.repositorySaveCount == 1)
    }

    @Test(arguments: ["draft", "host", "stream"])
    func inFlightCheckpointsPreserveNewerDurableAndAccountState(boundary: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BighelpHostRepositoryScope(hostID: "host-a")
        let original = SessionRecord(id: "session", kind: .direct, agentIDs: ["default"], title: "Host A")
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [original],
                                        scopeID: { scope.hostID })
        let gate = CatalogEncodingGate()
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository,
            defaults: isolatedDefaults(), persistenceCheckpointDelay: .zero,
            encodeSnapshot: { try await gate.encode($0) })
        func context(_ used: Int) -> SessionContextSnapshot {
            .init(sessionId: "session", model: "hermes", contextUsed: used, contextMax: 100,
                contextPercent: used, compressions: 0, isCompacting: false, updatedAt: used)
        }
        catalog.reconcileSessionContext(context(1))
        await gate.waitUntilBlocked()
        switch boundary {
        case "draft":
            try catalog.updateReferenceState(canonicalDraft: "Durable new draft", state: nil, for: "session")
        case "host":
            catalog.resetForAccountBoundary()
            scope.hostID = "host-b"
            try repository.save([SessionRecord(id: "session", kind: .direct, agentIDs: ["default"], title: "Host B")])
            catalog.restoreRepositoryCacheForHostSwitch()
        default:
            catalog.reconcileSessionContext(context(2))
        }
        await gate.open()
        // Drain the released encoder and any new checkpoint without imposing a
        // scheduler race on the test's readback.
        try await Task.sleep(for: .milliseconds(100))
        let saved = try #require(repository.load().first)
        switch boundary {
        case "draft": #expect(saved.draft == "Durable new draft")
        case "host":
            #expect(saved.title == "Host B")
            #expect(saved.sessionContext == nil)
            scope.hostID = "host-a"
            #expect(try repository.load().first?.sessionContext == nil)
        default:
            #expect(saved.sessionContext?.contextUsed == 2)
            #expect(catalog.repositorySaveCount == 2)
        }
        #expect(!catalog.hasUnsavedChanges)
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

    @Test func twoUnmountedChatsCheckpointTogetherWithoutBlockingEveryLiveEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = (0..<2).map { session in
            SessionRecord(id: "busy-\(session)", kind: .direct, agentIDs: ["default"], title: "Long chat",
                items: (0..<1_000).map { index in
                    Self.message("\(session)-\(index)", role: .assistant,
                                 text: String(repeating: "A retained answer with detail. ", count: 60))
                }, hasAcceptedMessage: true)
        }
        let repository = DemoRepository(directory: directory, name: "sessions", seed: records)
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), repository: repository,
                                          defaults: isolatedDefaults())
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let start = ContinuousClock.now
        for index in 0..<20 {
            for session in records {
                features.acceptSessionContext(.init(sessionId: session.id, model: "hermes",
                    contextUsed: index, contextMax: 100, contextPercent: index,
                    compressions: 0, isCompacting: false, updatedAt: index))
                features.acceptExternalActivity(.init(eventID: "tool-\(index)", sessionID: session.id,
                    turnID: "turn", kind: .tool, lifecycle: .succeeded, title: "Read", summary: "Complete",
                    detail: "Result \(index)", occurredAt: index, toolCallID: "call-\(index)", toolName: "read_file"))
            }
        }
        print("TWO_CHAT_EVENT_BURST elapsed=\(ContinuousClock.now - start) writes=\(catalog.repositorySaveCount)")
        #expect(catalog.repositorySaveCount == 0, "Live events must not synchronously rewrite all retained histories.")
        features.flushChatPersistence()
        let saved = try repository.load()
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.items.count == 1_000 && $0.activityEvents.count == 20 })
        #expect(saved.allSatisfy { $0.sessionContext?.contextUsed == 19 })
        #expect(catalog.repositorySaveCount == 1, "One lifecycle checkpoint must include every active session.")
    }

    @Test func delegatedWorkSurvivesParentFinalAndClearsAfterLastChild() throws {
        var record = SessionRecord(id: "parent", kind: .direct, agentIDs: ["default"], title: "Work")
        let children = ["a", "b"].map { SessionSubagentSnapshot(id: $0, sessionID: "child-" + $0,
            parentID: "parent", role: "worker", goal: "Task", startedAt: 1) }
        record.isActive = false
        record.sessionSubagents = .init(sessionID: record.id, subagents: children, updatedAt: 10)
        #expect(record.hasActiveWork)
        #expect(!record.isActive)
        let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.hasActiveWork)
        #expect(!restored.isActive)
        record.sessionSubagents = .init(sessionID: record.id, subagents: [children[1]], updatedAt: 11)
        #expect(record.hasActiveWork)
        record.sessionSubagents = .init(sessionID: record.id, subagents: [], updatedAt: 12)
        #expect(!record.hasActiveWork)
        record.isActive = true
        #expect(record.hasActiveWork)
    }

    @Test func overlappingAuthoritativeRefreshesShareOneSuccessfulLoad() async throws {
        let client = SharedAuthoritativeCatalogProbe()
        let catalog = SessionCatalogStore(client: client)
        let first = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        await client.waitUntilStarted()
        let second = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        for _ in 0..<20 { await Task.yield() }
        let requestCount = client.requestCount
        client.finish()
        let firstResult = await first.result
        let secondResult = await second.result
        #expect(requestCount == 1)
        if case .failure(let error) = firstResult { Issue.record("First refresh failed: \(error)") }
        if case .failure(let error) = secondResult { Issue.record("Second refresh failed: \(error)") }
        #expect(catalog.refreshErrorMessage == nil)
    }

    @Test func accountRefreshAndSessionOpenDoNotReportFalseConnectionFailure() async throws {
        let client = SharedAuthoritativeCatalogProbe()
        let record = SessionRecord(id: "session", kind: .direct, agentIDs: ["default"], title: "Current")
        let catalog = SessionCatalogStore(client: client, records: [record])
        let recovering = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        await client.waitUntilStarted()
        let opening = Task { try await catalog.refreshExistingSession(id: record.id) }
        for _ in 0..<20 { await Task.yield() }
        client.finish(records: [record])
        try await recovering.value
        #expect(try await opening.value.id == record.id)
        #expect(client.requestCount == 1)
    }

    @Test func cancellingOneAuthoritativeWaiterDoesNotCancelTheOther() async throws {
        let client = SharedAuthoritativeCatalogProbe()
        let catalog = SessionCatalogStore(client: client)
        let first = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        await client.waitUntilStarted()
        let second = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        client.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(client.requestCount == 1)
    }

    @Test func cancellingTheLastAuthoritativeWaiterCancelsItsRequest() async {
        let client = CancellableAuthoritativeCatalogProbe()
        let catalog = SessionCatalogStore(client: client)
        let loading = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        while !client.started { await Task.yield() }
        loading.cancel()
        _ = await loading.result
        #expect(client.cancelled)
    }

    @Test func accountResetInvalidatesSharedAuthoritativeLoad() async throws {
        let client = SharedAuthoritativeCatalogProbe()
        let catalog = SessionCatalogStore(client: client)
        let loading = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        await client.waitUntilStarted()
        catalog.resetForAccountBoundary()
        client.finish(records: [SessionRecord(id: "old-account", kind: .direct, agentIDs: ["default"], title: "Old")])
        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(catalog.records.isEmpty)
    }

    @Test func authoritativeLoadCoalescesDurableAndTransientAliasesIntoCanonicalVisibleSession() async throws {
        let storedID = "stored-parent"
        let oldVisibleID = "old-visible-parent"
        let canonicalID = "canonical-parent"
        let context = SessionContextSnapshot(
            sessionId: oldVisibleID,
            model: "hermes-4",
            contextUsed: 42,
            contextMax: 100,
            contextPercent: 42,
            compressions: 1,
            isCompacting: false,
            updatedAt: 10
        )
        let local = SessionRecord(
            id: oldVisibleID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Hydrated parent",
            remoteStoredID: storedID,
            remoteSource: "loopdy",
            sessionContext: context,
            items: [Self.message("assistant-answer", role: .assistant, text: "Canonical answer")],
            hasAcceptedMessage: true
        )
        let transientActivity = Self.semanticTool(
            "live-tool",
            sessionID: storedID,
            lifecycle: .running
        )
        let ghost = Self.provisionalRecord(id: storedID, event: transientActivity)
        let incoming = SessionRecord(
            id: canonicalID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Authoritative parent",
            remoteStoredID: storedID,
            remoteSource: "loopdy",
            isActive: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [incoming]),
            records: [local, ghost]
        )

        try await catalog.load(requireAuthoritativeRefresh: true)

        #expect(catalog.records.map(\.id) == [canonicalID])
        #expect(catalog.session(id: storedID) == nil)
        #expect(catalog.session(id: oldVisibleID) == nil)
        #expect(catalog.session(id: canonicalID)?.items.contains(where: { $0.id == "assistant-answer" }) == true)
        #expect(catalog.session(id: canonicalID)?.sessionContext?.sessionId == canonicalID)
        #expect(catalog.session(id: canonicalID)?.activityEvents.first?.sessionID == canonicalID)
    }

    @Test func rosterOwnershipAppliedWhenChildArrivesInLaterCatalogLoad() async throws {
        let child = SessionRecord(
            id: "child-visible",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Child",
            remoteStoredID: "child-stored",
            remoteSource: "loopdy",
            isActive: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [child])
        )
        catalog.reconcileSubagentSessions(
            parentSessionID: "parent-visible",
            childSessionIDs: ["child-stored"]
        )

        try await catalog.load(requireAuthoritativeRefresh: true)

        #expect(catalog.session(id: child.id)?.parentSessionID == "parent-visible")
        #expect(catalog.recentSummaries.isEmpty)
    }

    @Test func productionCompositionLoadsTheSelectedHostSessionCacheDuringInitialization() {
        #expect(BighelpAppComposition.loadsProductionSessionRepositoryOnInit)
    }

    @Test func hostSwitchRestoresOnlyTheNewHostsCachedSessionsBeforeRemoteRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-cache-swap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BighelpHostRepositoryScope(hostID: "host-old")
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [],
            scopeID: { scope.hostID }
        )
        let old = Self.record(id: "old-host", title: "Old host")
        let new = Self.record(id: "new-host", title: "New host")
        try repository.save([old])
        scope.hostID = "host-new"
        try repository.save([new])
        scope.hostID = "host-old"
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )

        catalog.resetForAccountBoundary()
        scope.hostID = "host-new"
        catalog.restoreRepositoryCacheForHostSwitch()

        #expect(catalog.records.map(\.id) == [new.id])
        #expect(catalog.session(id: old.id) == nil)
    }

    @Test func failedHydrationPreservesProvisionalLiveActivity() async throws {
        let childID = "child-hydration-failure"
        let live = Self.semanticTool("live-tool", sessionID: childID, lifecycle: .running)
        let provisional = Self.provisionalRecord(id: childID, event: live)
        let catalog = SessionCatalogStore(
            client: StaleHydrationFixtureClient(error: .unavailable),
            records: [provisional]
        )

        await #expect(throws: StaleHydrationFixtureClient.Failure.self) {
            _ = try await catalog.refreshOrPrepareSession(id: childID)
        }

        #expect(catalog.session(id: childID)?.isActive == true)
        #expect(catalog.session(id: childID)?.activityEvents == [live])
    }

    @Test func staleHydrationUnionsProvisionalActivityAndReconcilesTerminalCatchUp() async throws {
        let childID = "child-hydration-stale"
        let live = Self.semanticTool("live-tool", sessionID: childID, lifecycle: .running)
        var stale = Self.provisionalRecord(id: childID, event: nil)
        stale.isActive = true
        let terminal = Self.semanticTool(
            "canonical-terminal",
            sessionID: childID,
            lifecycle: .succeeded,
            detail: "terminal output"
        )
        var canonical = stale
        canonical.isActive = false
        canonical.activityEvents = [terminal]
        let client = StaleHydrationFixtureClient(responses: [stale, canonical])
        let catalog = SessionCatalogStore(client: client, records: [Self.provisionalRecord(id: childID, event: live)])

        let afterStale = try await catalog.refreshKnownSession(id: childID)
        #expect(afterStale.isActive == true)
        #expect(afterStale.activityEvents == [live])

        let afterTerminal = try await catalog.refreshKnownSession(id: childID)
        #expect(afterTerminal.isActive == false)
        #expect(afterTerminal.activityEvents.count == 1)
        #expect(afterTerminal.activityEvents[0].lifecycle == .succeeded)
        #expect(afterTerminal.activityEvents[0].detail == "terminal output")
    }

    @Test func subagentDetailPresentationUsesTheCurrentProvisionalRecordImmediately() {
        let provisional = SessionRecord(
            id: "child-provisional",
            kind: .direct,
            agentIDs: [],
            title: "Reviewer",
            activityEvents: [Self.activity("child-reasoning", sessionID: "child-provisional")],
            isActive: true
        )

        #expect(SessionSubagentDetailPresentation.state(for: provisional) == .live)
        #expect(SessionSubagentDetailPresentation.shouldShowWaiting(for: provisional) == false)
    }

    @Test func subagentRosterPresentationUsesFriendlyNamesAndBoundedDescriptions() {
        let ringTask = SessionSubagentSnapshot(
            id: "ring-task",
            sessionID: "ring-session",
            parentID: nil,
            role: "leaf",
            goal: "In /Users/example/worktrees/loopdy, implement one bounded SwiftUI/TDD correction for the chat context-window ring color progression. Do not commit, push, deploy, archive, upload, install, restart, or change signing/release settings.",
            startedAt: 1
        )
        let raceTask = SessionSubagentSnapshot(
            id: "race-task",
            sessionID: "race-session",
            parentID: nil,
            role: "leaf",
            goal: "Implement one bounded strict RED-GREEN TDD fix for the stale partial agent mutation race. Run focused tests and return exact results.",
            startedAt: 2
        )

        let ring = SessionSubagentRosterPresentation.card(for: ringTask)
        let race = SessionSubagentRosterPresentation.card(for: raceTask)

        #expect(ring.name == "Chat Context-Window Ring Color Progression")
        #expect(ring.summary == "Improving the chat context-window ring color progression.")
        #expect(race.name == "Stale Partial Agent Mutation Race")
        #expect(race.summary == "Fixing the stale partial agent mutation race.")
        #expect(ring.summary.count <= SessionSubagentRosterPresentation.maximumSummaryLength)
        #expect(race.summary.count <= SessionSubagentRosterPresentation.maximumSummaryLength)
        #expect(ring.summary.contains("/Users/") == false)
        #expect(ring.summary.contains("Do not commit") == false)
    }

    @Test func latestOverlappingLoadWinsWhenResponsesArriveOutOfOrder() async {
        let client = OutOfOrderSessionCatalogClient()
        let catalog = SessionCatalogStore(client: client)
        let firstLoad = Task { try? await catalog.load() }
        await client.waitUntilListStarts(count: 1)
        let secondLoad = Task { try? await catalog.load() }
        await client.waitUntilListStarts(count: 2)

        client.resumeList(
            request: 2,
            with: [Self.record(id: "newest-load", title: "Newest response")]
        )
        await secondLoad.value
        client.resumeList(
            request: 1,
            with: [Self.record(id: "stale-load", title: "Stale response")]
        )
        await firstLoad.value

        #expect(catalog.records.map(\.id) == ["newest-load"])
        #expect(catalog.session(id: "stale-load") == nil)
    }

    @Test func preparingExistingSessionRetriesUntilItsRefreshIsAuthoritative() async throws {
        let sessionID = "visible-prepare-race"
        let stale = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Stale session",
            remoteStoredID: "stored-stale-session",
            remoteSource: "loopdy",
            items: [Self.message("stale-answer", role: .assistant, text: "Stale answer")],
            hasAcceptedMessage: true
        )
        let current = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Current session",
            remoteStoredID: "stored-current-session",
            remoteSource: "loopdy",
            items: [Self.message("current:summary-preview", role: .human, text: "Current preview")],
            hasAcceptedMessage: true
        )
        let client = SupersededPrepareSessionCatalogClient()
        let catalog = SessionCatalogStore(client: client, records: [stale])
        let preparing = Task { try await catalog.prepareExistingSession(id: sessionID) }
        await client.waitUntilListStarts(count: 1)
        let competing = Task { try? await catalog.load() }
        await client.waitUntilListStarts(count: 2)

        client.resumeList(request: 1, with: [stale])
        await client.waitUntilHydrationOrListStarts(count: 3)
        if client.listCallCount >= 3 {
            client.resumeList(request: 2, with: [current])
            client.resumeList(request: 3, with: [current])
        } else {
            client.resumeList(request: 2, with: [current])
        }

        let opened = try await preparing.value
        await competing.value

        #expect(client.listCallCount == 3)
        #expect(client.hydratedRecords.map(\.remoteStoredID) == ["stored-current-session"])
        #expect(opened.remoteStoredID == "stored-current-session")
        #expect(opened.items.map(\.id) == ["hydrated-current-session"])
    }

    @Test func catalogRefreshDoesNotCarryTranscriptAcrossChangedRemoteCoordinate() async throws {
        let sessionID = "visible-coordinate-change"
        let cached = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Cached session",
            remoteStoredID: "stored-old-coordinate",
            remoteSource: "loopdy",
            items: [Self.message("old-answer", role: .assistant, text: "Old transcript")],
            activityEvents: [Self.activity("old-tool", sessionID: sessionID)],
            hasAcceptedMessage: true
        )
        let listed = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Current session",
            remoteStoredID: "stored-new-coordinate",
            remoteSource: "loopdy",
            items: [Self.message("new:summary-preview", role: .human, text: "New preview")],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [listed]),
            records: [cached]
        )

        try await catalog.load()
        let refreshed = try #require(catalog.session(id: sessionID))

        #expect(refreshed.remoteStoredID == "stored-new-coordinate")
        #expect(refreshed.items.map(\.id) == ["new:summary-preview"])
        #expect(refreshed.activityEvents.isEmpty)
    }

    @Test func resetInvalidatesAnInFlightRemoteLoad() async {
        let client = DeferredSessionCatalogClient()
        let catalog = SessionCatalogStore(client: client)
        let loading = Task { try? await catalog.load() }

        await client.waitUntilListStarts()
        catalog.resetForAccountBoundary()
        client.resumeList(with: [
            SessionRecord(
                id: "old-account-session",
                kind: .direct,
                agentIDs: ["finance"],
                title: "Old account"
            )
        ])
        await loading.value

        #expect(catalog.records.isEmpty)
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.refreshErrorMessage == nil)
    }

    @Test func repositoryBackedLoadFetchesRemoteAndPreservesRicherLocalState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localItem = Self.message("local-transcript", role: .human, text: "Keep this transcript")
        let localOnly = SessionRecord(
            id: "local-draft",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Local draft",
            draft: "Unsynced follow-up"
        )
        let localShared = SessionRecord(
            id: "shared-session",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Cached title",
            workspaceID: "project-old",
            workspaceName: "Old Project",
            draft: "Local draft text",
            items: [localItem],
            hasAcceptedMessage: true
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [localOnly, localShared]
        )
        let remoteShared = SessionRecord(
            id: localShared.id,
            kind: .direct,
            agentIDs: ["finance"],
            title: "Remote title",
            items: [],
            hasAcceptedMessage: true
        )
        let remoteOnly = SessionRecord(
            id: "remote-session",
            kind: .direct,
            agentIDs: ["travel"],
            title: "Remote session"
        )
        let client = SessionCatalogFixtureClient(records: [remoteShared, remoteOnly])
        let catalog = SessionCatalogStore(client: client, repository: repository)

        try await catalog.load()

        #expect(client.listCallCount == 1)
        #expect(Set(catalog.records.map(\.id)) == Set([
            localOnly.id,
            localShared.id,
            remoteOnly.id,
        ]))
        #expect(catalog.session(id: localOnly.id)?.draft == "Unsynced follow-up")
        #expect(catalog.session(id: localShared.id)?.title == "Remote title")
        #expect(catalog.session(id: localShared.id)?.draft == "Local draft text")
        #expect(catalog.session(id: localShared.id)?.items == [localItem])
        #expect(catalog.session(id: localShared.id)?.workspaceID == nil)
        #expect(catalog.session(id: localShared.id)?.workspaceName == nil)
        let persistedRecords = try repository.load()
        let persistedIDs = Set(persistedRecords.map(\.id))
        #expect(persistedIDs == Set([
            localOnly.id,
            localShared.id,
            remoteOnly.id,
        ]))
        let persistedShared = try #require(
            persistedRecords.first(where: { $0.id == localShared.id })
        )
        #expect(persistedShared.draft == "Local draft text")
        #expect(persistedShared.items == [localItem])
        #expect(persistedShared.workspaceID == nil)
        #expect(persistedShared.workspaceName == nil)
    }

    @Test func authoritativeHostRefreshReplacesSessionsFromThePreviousHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-host-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousHost = SessionRecord(
            id: "previous-host-session",
            kind: .direct,
            agentIDs: ["default"],
            title: "Previous host"
        )
        let selectedHost = SessionRecord(
            id: "selected-host-session",
            kind: .direct,
            agentIDs: ["default"],
            title: "Selected host"
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [previousHost]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [selectedHost]),
            repository: repository
        )

        catalog.resetForAccountBoundary()
        try await catalog.load(requireAuthoritativeRefresh: true)

        #expect(catalog.records.map(\.id) == [selectedHost.id])
        #expect(try repository.load().map(\.id) == [selectedHost.id])
    }

    @Test func failedRemoteRefreshKeepsCachedRecordsVisibleWithoutThrowing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-stale-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = SessionRecord(
            id: "cached-session",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Cached session",
            draft: "Keep me visible"
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [cached]
        )
        let client = SessionCatalogFixtureClient(listError: .listUnavailable)
        let catalog = SessionCatalogStore(client: client, repository: repository)

        try await catalog.load()

        #expect(client.listCallCount == 1)
        #expect(catalog.session(id: cached.id)?.draft == "Keep me visible")
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.refreshErrorMessage == "Sessions could not be refreshed. Try again.")
    }

    @Test func draftHistoryAndActivityPersistenceDoNotPromoteSessionRecency() {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = SessionRecord(
            id: "stable-recency",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Stable recency",
            items: [Self.message("known", role: .human, text: "Known turn")],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [record]
        )

        catalog.updateDraft("local draft", for: record.id)
        catalog.replaceItems(record.items, for: record.id)
        catalog.replaceActivity([], visibility: .default, for: record.id)

        #expect(catalog.session(id: record.id)?.updatedAt == updatedAt)
    }

    @Test func atomicChatSnapshotUpdatesDraftAndItemsTogether() {
        let record = SessionRecord(
            id: "atomic-chat-snapshot",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Atomic"
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [record]
        )
        let item = Self.message("new-turn", role: .human, text: "Hello")

        catalog.updateChatSnapshot(draft: "Next", items: [item], for: record.id)

        #expect(catalog.session(id: record.id)?.draft == "Next")
        #expect(catalog.session(id: record.id)?.items == [item])
        #expect(catalog.session(id: record.id)?.hasAcceptedMessage == true)
    }

    @Test func aNewUserOrAgentTurnPromotesSessionRecency() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let record = SessionRecord(
            id: "turn-recency",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Turn recency",
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [record]
        )

        catalog.replaceItems(
            [Self.message("new-user", role: .human, text: "New turn")],
            for: record.id
        )

        #expect(try #require(catalog.session(id: record.id)?.updatedAt) > updatedAt)
    }

    @Test func openingCachedNativeSessionDoesNotReloadOtherProfilesOrTranscripts() async throws {
        let record = SessionRecord(id: "scoped-native", kind: .direct, agentIDs: ["default"], title: "Cached")
        let client = ScopedMetadataSessionClient()
        let catalog = SessionCatalogStore(client: client, records: [record])
        let refreshed = try await catalog.refreshExistingSession(id: record.id)
        #expect(refreshed.title == "Current native title")
        #expect(client.listCalls == 0)
        #expect(client.metadataCalls == [record.id])
    }

    @Test func refreshingExistingSessionForPresentationStopsBeforeTranscriptHydration() async throws {
        let sessionID = "cached-session-opening"
        let cached = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Cached session",
            remoteStoredID: "stored-session-opening",
            remoteSource: "loopdy",
            isActive: true,
            hasAcceptedMessage: true
        )
        var listed = cached
        listed.isActive = false
        listed.title = "Current session"
        let client = SessionCatalogFixtureClient(
            records: [listed],
            hydrated: [sessionID: listed]
        )
        let catalog = SessionCatalogStore(client: client, records: [cached])

        let refreshed = try await catalog.refreshExistingSession(id: sessionID)

        #expect(refreshed.title == "Current session")
        #expect(!refreshed.isActive)
        #expect(client.listCallCount == 1)
        #expect(client.hydratedIDs.isEmpty)
    }

    @Test func acceptedStopInvalidatesAnOlderActiveCatalogResponse() async throws {
        let sessionID = "stop-generation-session"
        let active = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Long task",
            isActive: true,
            hasAcceptedMessage: true
        )
        let client = DeferredSessionCatalogClient()
        let catalog = SessionCatalogStore(client: client, records: [active])
        let staleLoad = Task { try await catalog.load(requireAuthoritativeRefresh: true) }
        await client.waitUntilListStarts()

        catalog.markInactiveAfterAcceptedStop(id: sessionID)
        client.resumeList(with: [active])
        await #expect(throws: SessionCatalogLoadOwnershipError.superseded) {
            try await staleLoad.value
        }

        #expect(catalog.session(id: sessionID)?.isActive == false)
    }

    @Test func acceptedStopSurvivesReopenUntilHermesReportsANewerGeneration() async throws {
        let sessionID = "stop-reopen-generation-session"
        let stoppedAt = Date(timeIntervalSince1970: 200)
        let active = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Long task",
            isActive: true,
            updatedAt: stoppedAt.addingTimeInterval(-10),
            hasAcceptedMessage: true
        )
        let client = SessionCatalogFixtureClient(records: [active])
        let catalog = SessionCatalogStore(client: client, records: [active])

        catalog.markInactiveAfterAcceptedStop(id: sessionID)
        _ = try await catalog.refreshExistingSession(id: sessionID)
        #expect(catalog.session(id: sessionID)?.isActive == false)

        var newer = active
        newer.updatedAt = Date().addingTimeInterval(10)
        client.setList(records: [newer])
        _ = try await catalog.refreshExistingSession(id: sessionID)
        #expect(catalog.session(id: sessionID)?.isActive == true)
    }

    @Test func preparingCachedSessionRequiresAnAuthoritativeCatalogRefresh() async {
        let cached = SessionRecord(
            id: "cached-active-session",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Cached active session",
            isActive: true
        )
        let client = SessionCatalogFixtureClient(listError: .listUnavailable)
        let catalog = SessionCatalogStore(client: client, records: [cached])

        await #expect(throws: SessionCatalogFixtureError.listUnavailable) {
            _ = try await catalog.prepareExistingSession(id: cached.id)
        }

        #expect(client.listCallCount == 1)
        #expect(client.hydratedRecords.isEmpty)
        #expect(catalog.session(id: cached.id)?.isActive == true)
    }

    @Test func failedRemoteRefreshWithValidEmptyCacheLoadsAnEmptyState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: []
        )
        let client = SessionCatalogFixtureClient(listError: .listUnavailable)
        let catalog = SessionCatalogStore(client: client, repository: repository)

        try await catalog.load()

        #expect(client.listCallCount == 1)
        #expect(catalog.records.isEmpty)
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.refreshErrorMessage == "Sessions could not be refreshed. Try again.")
    }

    @Test func failedRemoteLoadWithoutUsableLocalStateStillThrows() async {
        let client = SessionCatalogFixtureClient(listError: .listUnavailable)
        let catalog = SessionCatalogStore(client: client)

        await #expect(throws: SessionCatalogFixtureError.listUnavailable) {
            try await catalog.load()
        }

        #expect(client.listCallCount == 1)
        #expect(catalog.records.isEmpty)
        #expect(catalog.loadErrorMessage == "Sessions could not be loaded. Try again.")
        #expect(catalog.refreshErrorMessage == nil)
    }

    @Test func transientLinkSessionFailureIsRecoveredBeforeHistoryIsReportedMissing() async throws {
        let session = Self.record(id: "transient-link-session", title: "Recovered session")
        let client = SessionCatalogFixtureClient(
            records: [session],
            linkFailuresRemaining: 1
        )
        let catalog = SessionCatalogStore(client: client)

        try await catalog.load()

        #expect(client.listCallCount == 2)
        #expect(catalog.session(id: session.id)?.title == "Recovered session")
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.refreshErrorMessage == nil)
    }

    @Test func successfulRefreshClearsEarlierRefreshError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-refresh-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = SessionRecord(
            id: "cached-session",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Cached session"
        )
        let remote = SessionRecord(
            id: "remote-session",
            kind: .direct,
            agentIDs: ["travel"],
            title: "Remote session"
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [cached]
        )
        let client = SessionCatalogFixtureClient(listError: .listUnavailable)
        let catalog = SessionCatalogStore(client: client, repository: repository)

        try await catalog.load()
        #expect(catalog.refreshErrorMessage != nil)

        client.setList(records: [remote])
        try await catalog.load()

        #expect(client.listCallCount == 2)
        #expect(catalog.session(id: cached.id) != nil)
        #expect(catalog.session(id: remote.id) != nil)
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.refreshErrorMessage == nil)
    }

    @Test func newlyCreatedLinkSessionIsDurableWithoutASeparateGatewayConnection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-link-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: []
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )

        let created = try await catalog.createDirect(agentID: "default")
        let restored = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )

        #expect(restored.session(id: created.id)?.agentIDs == ["default"])
    }

    @Test func locallyCreatedSessionUsesAnOpaqueLinkSafeCoordinate() async throws {
        let client = DemoSessionCatalogClient(records: [])

        let session = try await client.create(kind: .direct, agentIDs: ["finance"])

        #expect((16...128).contains(session.id.count))
        #expect(session.id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        })
    }

    @Test func retentionCapsSummariesWithoutDroppingOlderAcceptedSession() async throws {
        let accepted = (0...500).map { index -> SessionRecord in
            var record = SessionRecord(
                id: "accepted-\(index)",
                kind: .direct,
                agentIDs: ["finance"],
                title: "Accepted \(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                hasAcceptedMessage: true
            )
            if index == 0 {
                record.draft = "Keep the original follow-up"
                record.items = [
                    TimelineItem(
                        id: "older-transcript",
                        role: .human,
                        sender: .user(snapshot: .init(name: "You")),
                        content: .message("Original transcript remains durable"),
                        metadata: TimelineMetadata(delivery: "Sent")
                    )
                ]
            }
            return record
        }
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: accepted)
        )

        try await catalog.load()

        #expect(catalog.recentSummaries.map(\.id) == (1...500).reversed().map { "accepted-\($0)" })
        #expect(catalog.session(id: "accepted-0")?.draft == "Keep the original follow-up")
        #expect(catalog.session(id: "accepted-0")?.items.map(\.id) == ["older-transcript"])
    }

    @Test func emptyDraftSessionIsDurableButExcludedFromRecents() async throws {
        let client = SessionCatalogFixtureClient()
        let catalog = SessionCatalogStore(client: client)

        let created = try await catalog.createDirect(agentID: "finance")

        #expect(catalog.session(id: created.id)?.agentIDs == ["finance"])
        #expect(catalog.recentSummaries.isEmpty)

        catalog.updateDraft("Keep this for later", for: created.id)
        #expect(catalog.session(id: created.id)?.draft == "Keep this for later")

        catalog.accept(
            TimelineItem(
                id: "accepted-1",
                role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("Review the budget"),
                metadata: TimelineMetadata(delivery: "Sent")
            ),
            for: created.id
        )
        #expect(catalog.recentSummaries.map(\.id) == [created.id])
    }

    @Test func hydratingAnOpenedSessionReplacesOnlyThatSummaryRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-hydrated-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = SessionRecord(
            id: "session-summary-0001",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Budget",
            workspaceID: "project-budget",
            workspaceName: "Budget App",
            items: [],
            hasAcceptedMessage: true
        )
        var hydrated = summary
        hydrated.workspaceID = nil
        hydrated.workspaceName = nil
        hydrated.items = [
            TimelineItem(
                id: "message-full-1",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Avery")),
                content: .message("Full history"),
                metadata: .init(delivery: "Saved")
            )
        ]
        let client = SessionCatalogFixtureClient(records: [summary], hydrated: [summary.id: hydrated])
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [summary]
        )
        let catalog = SessionCatalogStore(client: client, repository: repository)

        let opened = try await catalog.hydrateSession(id: summary.id)
        // Refreshes share a background checkpoint; suspension/navigation flush
        // remains the explicit durability boundary before store recreation.
        catalog.flushPersistence()
        let restored = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )

        #expect(opened.items.map(\.id) == ["message-full-1"])
        #expect(opened.workspaceID == "project-budget")
        #expect(opened.workspaceName == "Budget App")
        #expect(catalog.session(id: summary.id)?.items.map(\.id) == ["message-full-1"])
        #expect(catalog.session(id: summary.id)?.workspaceID == "project-budget")
        #expect(restored.session(id: summary.id)?.items.map(\.id) == ["message-full-1"])
        #expect(restored.session(id: summary.id)?.workspaceName == "Budget App")
        #expect(client.hydratedIDs == [summary.id])
    }

    @Test func historyPagesLoadNewestTurnsFirstAndOlderTurnsOnlyOnDemand() async throws {
        let summary = SessionRecord(
            id: "session-on-demand-0001",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Long conversation",
            remoteStoredID: "stored-on-demand-0001",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        var newest = summary
        newest.items = [
            Self.message("newest-question", role: .human, text: "Latest question"),
            Self.message("newest-answer", role: .assistant, text: "Latest answer"),
        ]
        var older = summary
        older.items = [
            Self.message("older-question", role: .human, text: "Earlier question"),
            Self.message("older-answer", role: .assistant, text: "Earlier answer"),
        ]
        let client = PagedSessionCatalogClient(
            record: summary,
            pages: [
                0: SessionHydrationPage(record: newest, nextOffset: 2),
                2: SessionHydrationPage(record: older, nextOffset: nil),
            ]
        )
        let catalog = SessionCatalogStore(client: client, records: [summary])

        let initial = try await catalog.hydrateInitialPage(id: summary.id, turnLimit: 8)

        #expect(client.requestedOffsets == [nil])
        #expect(initial.items.map(\.id) == ["newest-question", "newest-answer"])
        #expect(catalog.hasPreviousHistory(id: summary.id))

        let complete = try await catalog.hydratePreviousPage(id: summary.id, turnLimit: 8)

        #expect(client.requestedOffsets == [nil, 2])
        #expect(complete.items.map(\.id) == [
            "older-question", "older-answer", "newest-question", "newest-answer",
        ])
        #expect(!catalog.hasPreviousHistory(id: summary.id))
    }

    @Test func previousHistoryPageDeduplicatesAndReconcilesCanonicalToolIdentity() async throws {
        let sessionID = "session-tool-page-dedupe"
        let summary = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Paged tools",
            remoteStoredID: "stored-tool-page-dedupe",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let success = ChatActivityEvent(
            eventID: "newer-success-event",
            sessionID: sessionID,
            turnID: "canonical-turn",
            kind: .tool,
            lifecycle: .succeeded,
            title: "Running a command",
            summary: "Completed",
            detail: nil,
            occurredAt: 200,
            toolCallID: "canonical-call",
            toolName: "terminal",
            arguments: #"{"command":"swift test"}"#,
            result: "Passed"
        )
        let malformedFailure = ChatActivityEvent(
            eventID: "older-malformed-failure-event",
            sessionID: sessionID,
            turnID: success.turnID,
            kind: .tool,
            lifecycle: .failed,
            title: success.title,
            summary: "Tool did not complete",
            detail: "Malformed duplicate",
            occurredAt: 100,
            toolCallID: success.toolCallID,
            toolName: success.toolName
        )
        var newest = summary
        newest.activityEvents = [success]
        var older = summary
        older.activityEvents = [malformedFailure]
        let client = PagedSessionCatalogClient(
            record: summary,
            pages: [
                0: SessionHydrationPage(record: newest, nextOffset: 2),
                2: SessionHydrationPage(record: older, nextOffset: nil),
            ]
        )
        let catalog = SessionCatalogStore(client: client, records: [summary])

        _ = try await catalog.hydrateInitialPage(id: sessionID)
        let hydrated = try await catalog.hydratePreviousPage(id: sessionID)

        #expect(hydrated.activityEvents.count == 1)
        #expect(hydrated.activityEvents.first?.lifecycle == .succeeded)
        #expect(hydrated.activityEvents.first?.result == "Passed")
        #expect(hydrated.activityEvents.first?.detail == "Malformed duplicate")
    }

    @Test func hydratingSessionDoesNotKeepStaleEmptyProtocolRowsFromCachedTranscript() async throws {
        let sessionID = "session-stale-empty-protocol-row"
        let cached = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["finance"],
            title: "Weather",
            items: [
                Self.message("cached-user", role: .human, text: "What is the weather?"),
                Self.message("cached-tool-request", role: .assistant, text: ""),
                Self.message("cached-answer", role: .assistant, text: "It is sunny."),
            ],
            hasAcceptedMessage: true
        )
        let canonical = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: cached.agentIDs,
            title: cached.title,
            items: [
                Self.message("canonical-user", role: .human, text: "What is the weather?"),
                Self.message("canonical-answer", role: .assistant, text: "It is sunny."),
            ],
            hasAcceptedMessage: true
        )
        let client = SessionCatalogFixtureClient(
            records: [cached],
            hydrated: [sessionID: canonical]
        )
        let catalog = SessionCatalogStore(client: client, records: [cached])

        let opened = try await catalog.hydrateSession(id: sessionID)

        #expect(opened.items == canonical.items)
        #expect(opened.items.allSatisfy { item in
            guard case .message(let text) = item.content else { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    @Test func activeEmptyHistoryPageDoesNotEraseCanonicalCachedTranscript() async throws {
        let sessionID = "session-active-flush-gap"
        let cached = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["default"],
            title: "Long-running session",
            remoteStoredID: "stored-active-flush-gap",
            remoteSource: "loopdy",
            items: [Self.message("cached-answer", role: .assistant, text: "Still visible")],
            isActive: true,
            hasAcceptedMessage: true
        )
        var activeEmpty = cached
        activeEmpty.items = []
        let client = SessionCatalogFixtureClient(
            records: [cached],
            hydrated: [sessionID: activeEmpty]
        )
        let catalog = SessionCatalogStore(client: client, records: [cached])

        let opened = try await catalog.hydrateSession(id: sessionID)

        #expect(opened.items.map(\.id) == ["cached-answer"])
    }

    @Test func preparingAnIncomingSessionLoadsItsSummaryThenHydratesTheCanonicalTranscript() async throws {
        let summary = SessionRecord(
            id: "session-incoming-0001",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Incoming update",
            items: [],
            hasAcceptedMessage: true
        )
        var canonical = summary
        canonical.items = [
            TimelineItem(
                id: "incoming-assistant-1",
                role: .assistant,
                sender: .agent(id: "juno", snapshot: .init(name: "Juno")),
                content: .message("Here is the completed answer."),
                metadata: .init(delivery: "Saved")
            ),
        ]
        let client = SessionCatalogFixtureClient(
            records: [summary],
            hydrated: [summary.id: canonical]
        )
        let catalog = SessionCatalogStore(client: client)

        let opened = try await catalog.prepareExistingSession(id: summary.id)

        #expect(client.listCallCount == 1)
        #expect(client.hydratedIDs == [summary.id])
        #expect(opened.items.map(\.id) == ["incoming-assistant-1"])
        #expect(catalog.session(id: summary.id)?.items == canonical.items)
    }

    @Test func preparingACachedSessionRefreshesItsHermesCoordinateBeforeCanonicalHydration() async throws {
        let sessionID = "visible-juno-session"
        let cached = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Cached Juno session",
            remoteStoredID: "stored-stale-session",
            remoteSource: "loopdy",
            items: [Self.message("cached-preview", role: .human, text: "Cached preview")],
            activityEvents: [
                Self.activity("cached-tool-1", sessionID: sessionID),
                Self.activity("cached-tool-2", sessionID: sessionID),
            ],
            isActive: true,
            hasAcceptedMessage: true
        )
        let listed = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Canonical Juno session",
            remoteStoredID: "stored-current-session",
            remoteSource: "loopdy",
            items: [Self.message("listed:summary-preview", role: .human, text: "List preview")],
            hasAcceptedMessage: true
        )
        var canonical = listed
        canonical.items = [
            Self.message("canonical-user", role: .human, text: "Exact question"),
            Self.message("canonical-answer", role: .assistant, text: "Exact answer"),
        ]
        canonical.activityEvents = [Self.activity("canonical-tool", sessionID: sessionID)]
        let client = SessionCatalogFixtureClient(
            records: [listed],
            hydrated: [sessionID: canonical]
        )
        let catalog = SessionCatalogStore(client: client, records: [cached])

        let opened = try await catalog.prepareExistingSession(id: sessionID)

        #expect(client.listCallCount == 1)
        #expect(client.hydratedRecords.map(\.remoteStoredID) == ["stored-current-session"])
        #expect(opened.remoteStoredID == "stored-current-session")
        #expect(!opened.isActive)
        #expect(catalog.session(id: sessionID)?.isActive == false)
        #expect(opened.items == canonical.items)
        #expect(opened.activityEvents == canonical.activityEvents)
        #expect(!opened.items.contains(where: { $0.id == "cached-preview" || $0.id.hasSuffix(":summary-preview") }))
    }

    @Test func newestHydrationOwnsTheSessionWhenResponsesCompleteOutOfOrder() async throws {
        let sessionID = "visible-concurrent-session"
        let summary = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["juno"],
            title: "Concurrent session",
            remoteStoredID: "stored-concurrent-session",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let client = OutOfOrderSessionHydrationClient(record: summary)
        let catalog = SessionCatalogStore(client: client, records: [summary])
        let first = Task { try await catalog.hydrateSession(id: sessionID) }
        await client.waitUntilHydrateStarts(count: 1)
        let second = Task { try await catalog.hydrateSession(id: sessionID) }
        await client.waitUntilHydrateStarts(count: 2)

        client.resumeHydrate(
            request: 2,
            items: [Self.message("newest-answer", role: .assistant, text: "Newest canonical answer")]
        )
        _ = try await second.value
        client.resumeHydrate(
            request: 1,
            items: [Self.message("stale-answer", role: .assistant, text: "Stale canonical answer")]
        )
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }

        #expect(catalog.session(id: sessionID)?.items.map(\.id) == ["newest-answer"])
    }

    @Test func scopedRefreshReturnsTheWinningHydrationInsteadOfFreezingOnSupersession() async throws {
        let sessionID = "visible-child-refresh-race"
        let summary = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["reviewer"],
            title: "Child session",
            remoteStoredID: "stored-child-session",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let client = OutOfOrderSessionHydrationClient(record: summary)
        let catalog = SessionCatalogStore(client: client, records: [summary])
        let childRefresh = Task { try await catalog.refreshKnownSession(id: sessionID) }
        await client.waitUntilHydrateStarts(count: 1)
        let competingRefresh = Task { try await catalog.hydrateSession(id: sessionID) }
        await client.waitUntilHydrateStarts(count: 2)

        client.resumeHydrate(
            request: 2,
            items: [Self.message("winning-answer", role: .assistant, text: "Current child update")]
        )
        _ = try await competingRefresh.value
        client.resumeHydrate(
            request: 1,
            items: [Self.message("stale-answer", role: .assistant, text: "Stale child update")]
        )

        let refreshed = try await childRefresh.value
        #expect(refreshed.items.map(\.id) == ["winning-answer"])
        #expect(catalog.session(id: sessionID)?.items.map(\.id) == ["winning-answer"])
    }

    @Test func childRefreshListsOnlyUntilDiscoveryEvenWhenFirstHydrationFails() async throws {
        let sessionID = "visible-child-discovery"
        let summary = SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["reviewer"],
            title: "Child session",
            remoteStoredID: "stored-child-discovery",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let client = FirstHydrationFailsSessionCatalogClient(record: summary)
        let catalog = SessionCatalogStore(client: client)

        await #expect(throws: FirstHydrationFailsSessionCatalogClient.Failure.self) {
            _ = try await catalog.refreshOrPrepareSession(id: sessionID)
        }
        let refreshed = try await catalog.refreshOrPrepareSession(id: sessionID)

        #expect(client.listCallCount == 1)
        #expect(client.hydrateCallCount == 2)
        #expect(refreshed.items.map(\.id) == ["child-recovered-answer"])
    }

    @Test func refreshingTheCatalogDoesNotReplaceAnExistingCanonicalTranscriptWithAnEqualSizeSummary() async throws {
        let canonicalItem = Self.message(
            "hermes:stored-session:message-1",
            role: .assistant,
            text: "The canonical answer"
        )
        let canonical = SessionRecord(
            id: "session-canonical-refresh",
            kind: .direct,
            agentIDs: ["default"],
            title: "Weather",
            items: [canonicalItem],
            hasAcceptedMessage: true
        )
        let summary = SessionRecord(
            id: canonical.id,
            kind: .direct,
            agentIDs: canonical.agentIDs,
            title: canonical.title,
            items: [
                Self.message(
                    "hermes:stored-session:summary-preview",
                    role: .human,
                    text: "The canonical answer"
                ),
            ],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [summary]),
            records: [canonical]
        )

        try await catalog.load()

        #expect(catalog.session(id: canonical.id)?.items == [canonicalItem])
    }

    @Test func refreshingWithAnUnmarkedHumanPreviewDoesNotEraseACanonicalAssistantTurn() async throws {
        let canonicalItem = Self.message(
            "hermes:stored-session:message-2",
            role: .assistant,
            text: "The answer is still available after reopening."
        )
        let canonical = SessionRecord(
            id: "session-legacy-preview",
            kind: .direct,
            agentIDs: ["default"],
            title: "Legacy weather",
            items: [canonicalItem],
            hasAcceptedMessage: true
        )
        let legacyPreview = SessionRecord(
            id: canonical.id,
            kind: .direct,
            agentIDs: canonical.agentIDs,
            title: canonical.title,
            items: [
                Self.message(
                    "legacy-preview-id",
                    role: .human,
                    text: "What is the weather?"
                ),
            ],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [legacyPreview]),
            records: [canonical]
        )

        try await catalog.load()

        #expect(catalog.session(id: canonical.id)?.items == [canonicalItem])
    }

    @Test func saveFailureSetsPersistenceErrorWithoutMasqueradingAsLoadFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-session-save-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = SessionRecord(
            id: "unsaved-session",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Unsaved session"
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [record]
        )
        try repository.save([record])
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )
        try FileManager.default.removeItem(at: directory)
        try Data("not-a-directory".utf8).write(to: directory)

        catalog.updateDraft("This remains in memory", for: record.id)

        #expect(catalog.session(id: record.id)?.draft == "This remains in memory")
        #expect(catalog.loadErrorMessage == nil)
        #expect(catalog.persistenceErrorMessage == "Session changes could not be saved. Try again.")
        #expect(catalog.hasUnsavedChanges)
    }

    @Test func olderSessionRecordDefaultsAdditiveFields() throws {
        let data = Data(
            """
            {
              "id": "legacy-session",
              "kind": "direct",
              "agentIDs": ["finance"],
              "createdAt": 0
            }
            """.utf8
        )

        let record = try JSONDecoder().decode(SessionRecord.self, from: data)

        #expect(record.title == "New chat")
        #expect(record.draft.isEmpty)
        #expect(record.items.isEmpty)
        #expect(record.updatedAt == record.createdAt)
        #expect(!record.hasAcceptedMessage)
        #expect(record.activityEvents.isEmpty)
        #expect(record.activityVisibility == .default)
        #expect(!record.isActive)
        #expect(record.workspaceID == nil)
        #expect(record.workspaceName == nil)
    }

    @Test func workTrailAndVisibilityPersistWithTheirOwningSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-activity-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [
                SessionRecord(
                    id: "session_activity_0001",
                    kind: .direct,
                    agentIDs: ["finance"],
                    title: "Weather"
                )
            ]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )
        let event = ChatActivityEvent(
            eventID: "tool_event_fixture_0001",
            sessionID: "session_activity_0001",
            turnID: "turn_fixture_0000001",
            kind: .tool,
            lifecycle: .running,
            title: "Checking weather",
            summary: "weather for Chicago",
            detail: nil,
            occurredAt: 1_788_000_001,
            toolCallID: "call_weather_fixture_01"
        )

        catalog.replaceActivity(
            [event],
            visibility: .init(showReasoning: true, showToolCalls: false),
            for: "session_activity_0001"
        )
        catalog.flushPersistence()
        let restored = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )

        #expect(restored.session(id: "session_activity_0001")?.activityEvents == [event])
        #expect(restored.session(id: "session_activity_0001")?.activityVisibility == .init(
            showReasoning: true,
            showToolCalls: false
        ))
    }

    @Test func forkingFromAMessageCopiesOnlyTheVerifiedCheckpointPrefix() async throws {
        let items = [
            Self.message("turn-1-user", role: .human, text: "First question"),
            Self.message("turn-1-assistant", role: .assistant, text: "First answer"),
            Self.message("turn-2-user", role: .human, text: "Second question"),
            Self.message("turn-2-assistant", role: .assistant, text: "Second answer"),
            Self.message("turn-3-user", role: .human, text: "Third question"),
        ]
        let source = SessionRecord(
            id: "source-session-coordinate",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Budget review",
            items: items,
            hasAcceptedMessage: true
        )
        let forkClient = SessionForkFixtureClient()
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [source]),
            records: [source],
            forkClient: forkClient
        )

        let fork = try await catalog.forkSession(
            id: source.id,
            throughItemID: "turn-2-assistant"
        )

        #expect(fork.title == "Budget review · Fork")
        #expect(fork.items.map(\.id) == Array(items.prefix(4)).map(\.id))
        #expect(fork.draft.isEmpty)
        #expect(catalog.session(id: fork.id) == fork)
        let request = try #require(forkClient.requests.first)
        #expect(request.sourceSessionID == source.id)
        #expect(request.forkSessionID == fork.id)
        #expect((16...128).contains(fork.id.count))
        #expect(request.checkpoint.userTurn == 2)
        #expect(request.checkpoint.role == .assistant)
        #expect(request.checkpoint.matches(content: "Second answer"))
        #expect(!request.checkpoint.matches(content: "First answer"))
    }

    @Test func forkRejectsANonMessageOrUnknownCheckpointBeforeCallingTheBackend() async throws {
        let source = SessionRecord(
            id: "source-session-coordinate",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Budget review",
            items: [Self.message("known-message", role: .human, text: "Hello")],
            hasAcceptedMessage: true
        )
        let forkClient = SessionForkFixtureClient()
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [source]),
            records: [source],
            forkClient: forkClient
        )

        await #expect(throws: SessionCatalogError.invalidSession) {
            try await catalog.forkSession(id: source.id, throughItemID: "missing-message")
        }
        #expect(forkClient.requests.isEmpty)
    }

    @Test func remoteSessionActionsPersistThenUpdateTheVisibleCatalog() async throws {
        let rename = Self.record(id: "rename-session", title: "Before")
        let archive = Self.record(id: "archive-session", title: "Archive me")
        let delete = Self.record(id: "delete-session", title: "Delete me")
        let client = MutationRecordingSessionCatalogClient(
            records: [rename, archive, delete]
        )
        let catalog = SessionCatalogStore(
            client: client,
            records: [rename, archive, delete]
        )

        try await catalog.renameSession(id: rename.id, title: "After")
        try await catalog.archiveSession(id: archive.id)
        try await catalog.deleteSession(id: delete.id)

        #expect(catalog.session(id: rename.id)?.title == "After")
        #expect(catalog.session(id: archive.id) == nil)
        #expect(catalog.session(id: delete.id) == nil)
        #expect(client.operations == [
            .rename(id: rename.id, title: "After"),
            .archive(id: archive.id),
            .delete(id: delete.id),
        ])
    }

    /// A refresh that read the list before the archive finished used to put
    /// the archived chat back.
    @Test(arguments: [false, true])
    func aRefreshThatStartedBeforeArchivingDoesNotBringTheChatBack(authoritative: Bool) async throws {
        let keep = Self.record(id: "keep-session", title: "Keep")
        let archive = Self.record(id: "archive-session", title: "Archive me")
        let client = GatedListSessionCatalogClient(records: [keep, archive])
        let catalog = SessionCatalogStore(client: client, records: [keep, archive])

        let refresh = Task { try? await catalog.load(requireAuthoritativeRefresh: authoritative) }
        while client.waitingLists == 0 { await Task.yield() }
        try await catalog.archiveSession(id: archive.id)
        client.releaseLists()
        await refresh.value

        #expect(catalog.session(id: archive.id) == nil)
        #expect(catalog.session(id: keep.id) != nil)
    }

    @Test func pinningIsLocalPersistsAndNeverCallsTheRemoteMutationClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-local-session-pin-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Self.record(id: "pin-session", title: "Pin me")
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [original]
        )
        let client = MutationRecordingSessionCatalogClient(
            records: [original],
            failure: .unavailable
        )
        let catalog = SessionCatalogStore(client: client, repository: repository)

        try await catalog.setSessionPinned(id: original.id, pinned: true)

        #expect(catalog.session(id: original.id)?.isPinned == true)
        #expect(try repository.load().first?.isPinned == true)
        #expect(client.operations.isEmpty)
    }

    @Test func authoritativeRefreshPreservesTheLocalPinState() async throws {
        let original = Self.record(id: "locally-pinned-session", title: "Pin me")
        let client = MutationRecordingSessionCatalogClient(records: [original])
        let catalog = SessionCatalogStore(client: client, records: [original])

        try await catalog.setSessionPinned(id: original.id, pinned: true)
        try await catalog.load(requireAuthoritativeRefresh: true)

        #expect(catalog.session(id: original.id)?.isPinned == true)
        #expect(client.operations.isEmpty)
    }

    @Test func sessionPinSurvivesLogoutStoreRecreationAndAuthoritativeRefresh() async throws {
        let defaults = isolatedDefaults()
        let original = Self.record(id: "durably-pinned-session", title: "Keep pinned")
        let first = SessionCatalogStore(
            client: MutationRecordingSessionCatalogClient(records: [original]),
            records: [original],
            defaults: defaults,
            currentHostID: { "host-studio" }
        )

        try await first.setSessionPinned(id: original.id, pinned: true)
        first.resetForAccountBoundary()

        let restored = SessionCatalogStore(
            client: MutationRecordingSessionCatalogClient(records: [original]),
            defaults: defaults,
            currentHostID: { "host-studio" }
        )
        try await restored.load(requireAuthoritativeRefresh: true)

        #expect(restored.session(id: original.id)?.isPinned == true)
    }

    @Test func deletingTheAccountErasesPersistedSessionPinPreferences() async throws {
        let defaults = isolatedDefaults()
        let original = Self.record(id: "deleted-account-session", title: "Do not retain")
        let first = SessionCatalogStore(
            client: MutationRecordingSessionCatalogClient(records: [original]),
            records: [original],
            defaults: defaults,
            currentHostID: { "host-studio" }
        )
        try await first.setSessionPinned(id: original.id, pinned: true)

        SessionCatalogStore.erasePersistedUserPreferences(defaults: defaults)

        let restored = SessionCatalogStore(
            client: MutationRecordingSessionCatalogClient(records: [original]),
            defaults: defaults,
            currentHostID: { "host-studio" }
        )
        try await restored.load(requireAuthoritativeRefresh: true)
        #expect(restored.session(id: original.id)?.isPinned == false)
    }

    @Test func failedSessionActionDoesNotMutateTheVisibleCatalog() async throws {
        let original = Self.record(id: "failed-session", title: "Original")
        let client = MutationRecordingSessionCatalogClient(
            records: [original],
            failure: .unavailable
        )
        let catalog = SessionCatalogStore(client: client, records: [original])

        await #expect(throws: MutationRecordingSessionCatalogClient.Failure.unavailable) {
            try await catalog.renameSession(id: original.id, title: "Should not stick")
        }

        #expect(catalog.session(id: original.id)?.title == "Original")
        #expect(catalog.session(id: original.id)?.isPinned == false)
    }

    @Test func invalidSessionTitlesAreRejectedBeforeRemoteMutation() async {
        let original = Self.record(id: "invalid-title-session", title: "Original")
        let client = MutationRecordingSessionCatalogClient(records: [original])
        let catalog = SessionCatalogStore(client: client, records: [original])

        for title in ["   ", String(repeating: "x", count: SessionTitleRules.maximumLength + 1)] {
            await #expect(throws: SessionCatalogError.invalidTitle) {
                try await catalog.renameSession(id: original.id, title: title)
            }
        }

        #expect(client.operations.isEmpty)
        #expect(catalog.session(id: original.id)?.title == "Original")
    }

    private static func message(
        _ id: String,
        role: TimelineRole,
        text: String
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            role: role,
            sender: role == .human
                ? .user(snapshot: .init(name: "You"))
                : .agent(id: "finance", snapshot: .init(name: "Avery")),
            content: .message(text),
            metadata: .init(delivery: "Saved")
        )
    }

    private static func activity(_ id: String, sessionID: String) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: id,
            sessionID: sessionID,
            turnID: "turn-\(id)",
            kind: .tool,
            lifecycle: .succeeded,
            title: id,
            summary: "Saved activity",
            detail: nil,
            occurredAt: 1
        )
    }

    private static func semanticTool(
        _ eventID: String,
        sessionID: String,
        lifecycle: ChatActivityLifecycle,
        detail: String? = nil
    ) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: eventID,
            sessionID: sessionID,
            turnID: "turn-shared-tool",
            kind: .tool,
            lifecycle: lifecycle,
            title: "Running terminal",
            summary: lifecycle == .running ? "Running" : "Succeeded",
            detail: detail,
            occurredAt: lifecycle == .running ? 1 : 2,
            durationMilliseconds: lifecycle == .running ? nil : 10,
            toolCallID: "call-shared-tool",
            toolName: "terminal",
            arguments: "{\"command\":\"printf proof\"}",
            result: detail,
            subagentID: nil,
            botRunID: nil,
            memberID: nil,
            sourceOrder: nil
        )
    }

    private static func provisionalRecord(id: String, event: ChatActivityEvent?) -> SessionRecord {
        SessionRecord(
            id: id,
            kind: .direct,
            agentIDs: [],
            title: "Reviewer",
            activityEvents: event.map { [$0] } ?? [],
            isActive: true
        )
    }

    private static func record(id: String, title: String) -> SessionRecord {
        SessionRecord(
            id: id,
            kind: .direct,
            agentIDs: ["finance"],
            title: title
        )
    }
}

private enum RecordedSessionMutation: Equatable {
    case rename(id: String, title: String)
    case pin(id: String, pinned: Bool)
    case archive(id: String)
    case delete(id: String)
}

@MainActor
private final class MutationRecordingSessionCatalogClient: SessionCatalogClient {
    enum Failure: Error, Equatable { case unavailable }

    private(set) var operations: [RecordedSessionMutation] = []
    private let records: [SessionRecord]
    private let failure: Failure?

    init(records: [SessionRecord], failure: Failure? = nil) {
        self.records = records
        self.failure = failure
    }

    func list() async throws -> [SessionRecord] { records }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw Failure.unavailable
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord { record }

    func rename(_ record: SessionRecord, title: String) async throws {
        if let failure { throw failure }
        operations.append(.rename(id: record.id, title: title))
    }

    func setPinned(_ record: SessionRecord, pinned: Bool) async throws {
        if let failure { throw failure }
        operations.append(.pin(id: record.id, pinned: pinned))
    }

    func archive(_ record: SessionRecord) async throws {
        if let failure { throw failure }
        operations.append(.archive(id: record.id))
    }

    func delete(_ record: SessionRecord) async throws {
        if let failure { throw failure }
        operations.append(.delete(id: record.id))
    }
}

/// Holds each list read until released, then answers with the host's list at
/// that moment, like Hermes: an archived chat is gone from later reads.
@MainActor
private final class GatedListSessionCatalogClient: SessionCatalogClient {
    private var records: [SessionRecord]
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    var waitingLists: Int { gates.count }

    init(records: [SessionRecord]) {
        self.records = records
    }

    func releaseLists() {
        isReleased = true
        gates.forEach { $0.resume() }
        gates.removeAll()
    }

    func list() async throws -> [SessionRecord] {
        guard !isReleased else { return records }
        let snapshot = records
        await withCheckedContinuation { gates.append($0) }
        return snapshot
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw CancellationError()
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord { record }
    func rename(_ record: SessionRecord, title: String) async throws {}
    func setPinned(_ record: SessionRecord, pinned: Bool) async throws {}

    func archive(_ record: SessionRecord) async throws {
        records.removeAll { $0.id == record.id }
    }

    func delete(_ record: SessionRecord) async throws {
        records.removeAll { $0.id == record.id }
    }
}

@MainActor
private final class StaleHydrationFixtureClient: SessionCatalogClient {
    enum Failure: Error { case unavailable }

    private var responses: [SessionRecord]
    private let error: Failure?

    init(responses: [SessionRecord] = [], error: Failure? = nil) {
        self.responses = responses
        self.error = error
    }

    func list() async throws -> [SessionRecord] { responses.first.map { [$0] } ?? [] }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw Failure.unavailable
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        if let error { throw error }
        return responses.isEmpty ? record : responses.removeFirst()
    }
}

@MainActor
private final class SessionForkFixtureClient: SessionForkClient {
    private(set) var requests: [SessionForkRequest] = []

    func fork(_ request: SessionForkRequest) async throws -> SessionForkReceipt {
        requests.append(request)
        return SessionForkReceipt(
            forkSessionID: request.forkSessionID,
            title: "Budget review · Fork"
        )
    }
}

enum SessionCatalogFixtureError: Error, Equatable {
    case listUnavailable
}

@MainActor
final class SessionCatalogFixtureClient: SessionCatalogClient {
    private var records: [SessionRecord]
    private let hydrated: [String: SessionRecord]
    private var listError: SessionCatalogFixtureError?
    private var linkFailuresRemaining: Int
    private var nextID = 1
    private(set) var listCallCount = 0
    private(set) var hydratedIDs: [String] = []
    private(set) var hydratedRecords: [SessionRecord] = []

    init(
        records: [SessionRecord] = [],
        hydrated: [String: SessionRecord] = [:],
        listError: SessionCatalogFixtureError? = nil,
        linkFailuresRemaining: Int = 0
    ) {
        self.records = records
        self.hydrated = hydrated
        self.listError = listError
        self.linkFailuresRemaining = linkFailuresRemaining
    }

    func setList(
        records: [SessionRecord],
        error: SessionCatalogFixtureError? = nil
    ) {
        self.records = records
        listError = error
    }

    func list() async throws -> [SessionRecord] {
        listCallCount += 1
        if linkFailuresRemaining > 0 {
            linkFailuresRemaining -= 1
            throw BighelpLinkLiveSocketError.disconnected
        }
        if let listError {
            throw listError
        }
        return records
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        defer { nextID += 1 }
        let record = SessionRecord(
            id: "session-\(nextID)",
            kind: kind,
            agentIDs: agentIDs,
            title: "New chat",
            createdAt: Date(timeIntervalSinceReferenceDate: Double(nextID))
        )
        records.append(record)
        return record
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        hydratedIDs.append(record.id)
        hydratedRecords.append(record)
        return hydrated[record.id] ?? record
    }
}

@MainActor
private final class PagedSessionCatalogClient: SessionCatalogClient {
    private let record: SessionRecord
    private let pages: [Int: SessionHydrationPage]
    private(set) var requestedOffsets: [Int?] = []

    init(record: SessionRecord, pages: [Int: SessionHydrationPage]) {
        self.record = record
        self.pages = pages
    }

    func list() async throws -> [SessionRecord] { [record] }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func hydratePage(
        _ record: SessionRecord,
        offset: Int?,
        turnLimit: Int
    ) async throws -> SessionHydrationPage {
        requestedOffsets.append(offset)
        guard turnLimit == 8, let page = pages[offset ?? 0] else {
            throw SessionCatalogFixtureError.listUnavailable
        }
        return page
    }
}

@MainActor
private final class OutOfOrderSessionHydrationClient: SessionCatalogClient {
    private let record: SessionRecord
    private var continuations: [Int: CheckedContinuation<SessionRecord, Error>] = [:]
    private var startedCount = 0

    init(record: SessionRecord) {
        self.record = record
    }

    func list() async throws -> [SessionRecord] { [record] }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        startedCount += 1
        let request = startedCount
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func waitUntilHydrateStarts(count: Int) async {
        while startedCount < count { await Task.yield() }
    }

    func resumeHydrate(request: Int, items: [TimelineItem]) {
        var hydrated = record
        hydrated.items = items
        continuations.removeValue(forKey: request)?.resume(returning: hydrated)
    }
}

@MainActor
private final class FirstHydrationFailsSessionCatalogClient: SessionCatalogClient {
    enum Failure: Error {
        case unavailable
    }

    private let record: SessionRecord
    private(set) var listCallCount = 0
    private(set) var hydrateCallCount = 0

    init(record: SessionRecord) {
        self.record = record
    }

    func list() async throws -> [SessionRecord] {
        listCallCount += 1
        return [record]
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw Failure.unavailable
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        hydrateCallCount += 1
        guard hydrateCallCount > 1 else { throw Failure.unavailable }
        var hydrated = record
        hydrated.items = [TimelineItem(
            id: "child-recovered-answer",
            role: .assistant,
            sender: .agent(id: "reviewer", snapshot: .init(name: "Reviewer")),
            content: .message("Recovered child update"),
            metadata: .init(delivery: "Saved")
        )]
        return hydrated
    }
}

@MainActor
private final class CancellableAuthoritativeCatalogProbe: SessionCatalogClient {
    private(set) var started = false
    private(set) var cancelled = false
    func list() async throws -> [SessionRecord] {
        started = true
        do { try await Task.sleep(for: .seconds(1)) }
        catch { cancelled = true; throw error }
        return []
    }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }
}

@MainActor
private final class SharedAuthoritativeCatalogProbe: SessionCatalogClient {
    private(set) var requestCount = 0
    private var continuations: [CheckedContinuation<[SessionRecord], Error>] = []

    func list() async throws -> [SessionRecord] {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func waitUntilStarted() async {
        while requestCount == 0 { await Task.yield() }
    }

    func finish(records: [SessionRecord] = []) {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: records) }
    }
}

@MainActor
private final class DeferredSessionCatalogClient: SessionCatalogClient {
    private var listContinuation: CheckedContinuation<[SessionRecord], Error>?
    private var listStarted = false

    func list() async throws -> [SessionRecord] {
        listStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            listContinuation = continuation
        }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func waitUntilListStarts() async {
        while !listStarted { await Task.yield() }
    }

    func resumeList(with records: [SessionRecord]) {
        listContinuation?.resume(returning: records)
        listContinuation = nil
    }
}

@MainActor
private final class OutOfOrderSessionCatalogClient: SessionCatalogClient {
    private var continuations: [Int: CheckedContinuation<[SessionRecord], Error>] = [:]
    private var startedCount = 0

    func list() async throws -> [SessionRecord] {
        startedCount += 1
        let request = startedCount
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func waitUntilListStarts(count: Int) async {
        while startedCount < count { await Task.yield() }
    }

    func resumeList(request: Int, with records: [SessionRecord]) {
        continuations.removeValue(forKey: request)?.resume(returning: records)
    }
}

@MainActor
private final class SupersededPrepareSessionCatalogClient: SessionCatalogClient {
    private var listContinuations: [Int: CheckedContinuation<[SessionRecord], Error>] = [:]
    private(set) var listCallCount = 0
    private(set) var hydratedRecords: [SessionRecord] = []

    func list() async throws -> [SessionRecord] {
        listCallCount += 1
        let request = listCallCount
        return try await withCheckedThrowingContinuation { continuation in
            listContinuations[request] = continuation
        }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionCatalogFixtureError.listUnavailable
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        hydratedRecords.append(record)
        var hydrated = record
        let coordinate = record.remoteStoredID == "stored-current-session"
            ? "current"
            : "stale"
        hydrated.items = [TimelineItem(
            id: "hydrated-\(coordinate)-session",
            role: .assistant,
            sender: .agent(id: "juno", snapshot: .init(name: "Juno")),
            content: .message("\(coordinate.capitalized) transcript"),
            metadata: .init(delivery: "Saved")
        )]
        return hydrated
    }

    func waitUntilListStarts(count: Int) async {
        while listCallCount < count { await Task.yield() }
    }

    func waitUntilHydrationOrListStarts(count: Int) async {
        while hydratedRecords.isEmpty && listCallCount < count { await Task.yield() }
    }

    func resumeList(request: Int, with records: [SessionRecord]) {
        listContinuations.removeValue(forKey: request)?.resume(returning: records)
    }
}

private actor CatalogEncodingGate {
    private var isOpen = false
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func encode(_ records: [SessionRecord]) async throws -> Data {
        if !isOpen {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try DemoRepository<[SessionRecord]>.encodeForSave(records)
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class ScopedMetadataSessionClient: SessionCatalogClient {
    var listCalls = 0
    var metadataCalls: [String] = []
    func list() async throws -> [SessionRecord] { listCalls += 1; return [] }
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord { throw SessionCatalogError.invalidSession }
    func refreshMetadata(_ record: SessionRecord) async throws -> SessionRecord? {
        metadataCalls.append(record.id)
        var result = record; result.title = "Current native title"; return result
    }
}

struct SessionRowTimestampTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func todayShowsTimeAndYesterdayIsNamed() {
        let now = date(2026, 9, 24, 15)
        #expect(SessionRow.compactTimestamp(date(2026, 9, 24, 9), now: now, calendar: calendar)
            == date(2026, 9, 24, 9).formatted(date: .omitted, time: .shortened))
        #expect(SessionRow.compactTimestamp(date(2026, 9, 23), now: now, calendar: calendar)
            == String(localized: "Yesterday"))
    }

    @Test func olderDatesStepFromWeekdayToShortDate() {
        let now = date(2026, 9, 24, 15)
        let thisWeek = date(2026, 9, 20)
        #expect(SessionRow.compactTimestamp(thisWeek, now: now, calendar: calendar)
            == thisWeek.formatted(.dateTime.weekday(.wide)))
        let thisYear = date(2026, 3, 2)
        #expect(SessionRow.compactTimestamp(thisYear, now: now, calendar: calendar)
            == thisYear.formatted(.dateTime.month(.abbreviated).day()))
        let lastYear = date(2025, 12, 30)
        #expect(SessionRow.compactTimestamp(lastYear, now: now, calendar: calendar)
            == lastYear.formatted(date: .numeric, time: .omitted))
    }
}
