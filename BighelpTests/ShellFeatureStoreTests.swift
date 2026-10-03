import Combine
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ShellFeatureStoreTests {
    @Test func voicePresentationUsesLiveFactoryAndRetiresItAtAccountBoundary() {
        let session = SessionRecord(id: "voice-owner", kind: .direct, agentIDs: ["default"], title: "Voice")
        let harness = makeStore(records: [session])
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: session.id)
        let client = LiveVoiceControlClient(owner: owner, operation: { _, _ in [:] }, isOwnerCurrent: { _ in true })
        let live = LiveVoiceModel(agentName: "Fixture", client: client)
        harness.store.configureLiveVoiceFactory { record, _, _ in record.id == session.id ? live : nil }
        let presentation = harness.store.makeVoicePresentation(
            for: session.id,
            conversationMode: .codexLive,
            liveProvider: .apiKey,
            liveVoice: "bossa"
        )
        #expect(presentation.liveModel === live)
        #expect(presentation.conversationMode == .codexLive)
        #expect(live.provider == .apiKey)
        #expect(live.voice == "bossa")
        #expect(live.canStart)
        let turnBased = harness.store.makeVoicePresentation(
            for: session.id,
            conversationMode: .turnBased,
            liveProvider: .codexSubscription,
            liveVoice: "maple"
        )
        #expect(turnBased.conversationMode == .turnBased)
        #expect(turnBased.liveModel == nil)
        #expect(!live.canStart)
        harness.store.resetForAccountBoundary()
        #expect(!live.canStart)
    }

    @Test func saturatedBackgroundToolsReuseBoundedIndexes() {
        func event(_ index: Int) -> ChatActivityEvent {
            ChatActivityEvent(eventID: "saturated-\(index)", sessionID: "saturated", turnID: "turn",
                              kind: .tool, lifecycle: .running, title: "Tool", summary: nil,
                              detail: nil, occurredAt: 1_788_000_001 + index, toolCallID: "call-\(index)")
        }
        var session = SessionRecord(id: "saturated", kind: .direct, agentIDs: ["default"], title: "Background")
        session.activityEvents = (0..<500).map(event)
        let harness = makeStore(records: [session])
        harness.store.setChatPresentationDeferred(true)
        for index in 500..<1_100 {
            harness.store.acceptExternalActivity(event(index), agentID: "default")
        }
        #expect(harness.catalog.session(id: session.id)?.activityEvents == (600..<1_100).map(event))
        #expect(harness.store.backgroundActivityProjectionCount == 1)
        harness.store.setChatPresentationDeferred(false)
    }

    @Test func deferredBackgroundToolsReduceOncePerSessionAndKeepEveryEvent() {
        let session = SessionRecord(id: "background-burst", kind: .direct, agentIDs: ["default"], title: "Background")
        let harness = makeStore(records: [session])
        harness.store.setChatPresentationDeferred(true)
        let events = (0..<100).map { index in
            ChatActivityEvent(eventID: "burst-\(index)", sessionID: session.id, turnID: "turn",
                              kind: .tool, lifecycle: .running, title: "Tool", summary: nil,
                              detail: nil, occurredAt: 1_788_000_001 + index, toolCallID: "call-\(index)")
        }
        for event in events { harness.store.acceptExternalActivity(event, agentID: "default") }
        harness.store.setChatPresentationDeferred(false)
        #expect(harness.catalog.session(id: session.id)?.activityEvents == events)
        #expect(harness.store.backgroundActivityProjectionCount == 1)
    }

    @Test func backgroundBatchIndexesRetireAfterHydrationAndAccountReset() {
        let session = SessionRecord(id: "background-reset", kind: .direct, agentIDs: ["default"], title: "Background")
        let harness = makeStore(records: [session])
        func event(_ index: Int) -> ChatActivityEvent {
            ChatActivityEvent(eventID: "event-\(index)", sessionID: session.id, turnID: "turn",
                              kind: .tool, lifecycle: .running, title: "Tool", summary: nil,
                              detail: nil, occurredAt: 1_788_000_001 + index, toolCallID: "call-\(index)")
        }
        harness.store.setChatPresentationDeferred(true)
        harness.store.acceptExternalActivity(event(1))
        harness.catalog.replaceActivity([event(2)], visibility: .default, for: session.id)
        harness.store.acceptExternalActivity(event(3))
        #expect(harness.catalog.session(id: session.id)?.activityEvents == [event(2), event(3)])
        #expect(harness.store.backgroundActivityProjectionCount == 2)
        harness.store.resetForAccountBoundary()
        harness.store.acceptExternalActivity(event(4))
        #expect(harness.store.backgroundActivityProjectionCount == 3)
        harness.store.setChatPresentationDeferred(false)
        #expect(harness.catalog.session(id: session.id)?.activityEvents == [event(2), event(3), event(4)])
    }

    @Test(arguments: [false, true])
    func queuedFinalsRefreshHomeOnceAfterHistoricalCatchUp(resetBeforeEnd: Bool) async throws {
        let source = CatchUpDashboardSource()
        let session = SessionRecord(id: "session_replay_0001", kind: .direct, agentIDs: ["finance"], title: "Done")
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [session])
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, dashboardSource: source)
        features.setChatPresentationDeferred(true)
        for index in 0..<10 {
            let message = try BighelpLinkAssistantMessage.decode([
                "version": 1, "type": "assistant.message", "messageId": "replayed_final_000\(index)",
                "sessionId": session.id, "agentId": "finance", "agentName": "Fixture", "text": "Done",
                "sentAt": 1_800_000_000 + index, "delivery": "final",
            ])
            features.acceptAssistantLiveness(message)
            for _ in 0..<10 { await Task.yield() }
        }
        #expect(source.loadCount == 0, "Replay must not launch dashboard requests for every old answer.")
        if resetBeforeEnd {
            features.resetForAccountBoundary()
            catalog.resetForAccountBoundary()
            #expect(catalog.presentedRecords.isEmpty)
        }
        features.setChatPresentationDeferred(false)
        for _ in 0..<100 { await Task.yield() }
        #expect(source.loadCount == (resetBeforeEnd ? 0 : 1))
    }

    @Test func homeSubagentRosterSuppliesMissingChildTitleAndEndsRemovedChild() {
        let parent = SessionRecord(id: "home-parent", kind: .direct, agentIDs: ["default"], title: "Parent", isActive: true)
        let harness = makeStore(records: [parent])
        harness.store.acceptSessionSubagents(SessionSubagentRosterSnapshot(sessionID: parent.id, subagents: [
            SessionSubagentSnapshot(id: "home-worker", sessionID: "home-child", parentID: parent.id,
                role: "leaf", goal: "Review accessibility", startedAt: 1)
        ], updatedAt: 1))
        #expect(harness.catalog.session(id: "home-child")?.isActive == true)
        #expect(harness.catalog.session(id: "home-child")?.agentIDs == ["default"])
        #expect(harness.catalog.session(id: "home-child")?.title.lowercased().contains("accessibility") == true)
        #expect(harness.store.dashboardModel.workInFlightItems.contains { $0.sessionID == "home-child" })
        harness.store.acceptSessionSubagents(SessionSubagentRosterSnapshot(sessionID: parent.id, subagents: [], updatedAt: 2))
        #expect(harness.catalog.session(id: "home-child")?.isActive == false)
        #expect(!harness.store.dashboardModel.workInFlightItems.contains { $0.sessionID == "home-child" })
    }

    @Test func durableProtocolIDRoutesLiveStateIntoCanonicalVisibleSessionWithoutGhostRow() {
        let session = SessionRecord(
            id: "visible-parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Parent",
            remoteStoredID: "stored-parent",
            remoteSource: "loopdy",
            isActive: true
        )
        let harness = makeStore(records: [session])
        let activity = ChatActivityEvent(
            eventID: "stored-id-tool",
            sessionID: "stored-parent",
            turnID: "stored-id-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Inspecting",
            summary: nil,
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: "stored-id-call"
        )
        let context = SessionContextSnapshot(
            sessionId: "stored-parent",
            model: "hermes-4",
            contextUsed: 40,
            contextMax: 100,
            contextPercent: 40,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1
        )

        harness.store.acceptExternalActivity(activity)
        harness.store.acceptSessionContext(context)

        #expect(harness.catalog.records.map(\.id) == [session.id])
        #expect(harness.catalog.session(id: "stored-parent") == nil)
        #expect(harness.catalog.session(id: session.id)?.activityEvents.first?.sessionID == session.id)
        #expect(harness.catalog.session(id: session.id)?.sessionContext?.sessionId == session.id)
    }

    @Test func authenticatedSubagentRosterMarksChildAsOwnedByParentSession() {
        let parent = SessionRecord(
            id: "parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Parent"
        )
        let child = SessionRecord(
            id: "child",
            kind: .direct,
            agentIDs: [],
            title: "Child",
            isActive: true
        )
        let harness = makeStore(records: [parent, child])
        let roster = SessionSubagentRosterSnapshot(
            sessionID: parent.id,
            subagents: [
                SessionSubagentSnapshot(
                    id: "subagent-1",
                    sessionID: child.id,
                    parentID: nil,
                    role: "reviewer",
                    goal: "Review the change",
                    startedAt: 1
                ),
            ],
            updatedAt: 1
        )

        harness.store.acceptSessionSubagents(roster)

        #expect(harness.catalog.session(id: child.id)?.parentSessionID == parent.id)
    }

    @Test func staleSubagentRosterCannotMarkAnObsoleteChild() {
        let parent = SessionRecord(
            id: "parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Parent"
        )
        let currentChild = SessionRecord(
            id: "current-child",
            kind: .direct,
            agentIDs: [],
            title: "Current child"
        )
        let obsoleteChild = SessionRecord(
            id: "obsolete-child",
            kind: .direct,
            agentIDs: [],
            title: "Obsolete child"
        )
        let harness = makeStore(records: [parent, currentChild, obsoleteChild])
        func roster(childID: String, updatedAt: Int) -> SessionSubagentRosterSnapshot {
            SessionSubagentRosterSnapshot(
                sessionID: parent.id,
                subagents: [
                    SessionSubagentSnapshot(
                        id: "subagent-\(childID)",
                        sessionID: childID,
                        parentID: nil,
                        role: "reviewer",
                        goal: "Review",
                        startedAt: updatedAt
                    ),
                ],
                updatedAt: updatedAt
            )
        }

        harness.store.acceptSessionSubagents(roster(childID: currentChild.id, updatedAt: 2))
        harness.store.acceptSessionSubagents(roster(childID: obsoleteChild.id, updatedAt: 1))

        #expect(harness.catalog.session(id: currentChild.id)?.parentSessionID == parent.id)
        #expect(harness.catalog.session(id: obsoleteChild.id)?.parentSessionID == nil)
    }

    @Test func unknownActiveSubagentSessionUsesPrefixedActivityTitle() {
        let harness = makeStore(records: [])
        let event = ChatActivityEvent(
            eventID: "subagent-started",
            sessionID: "child-session",
            turnID: "child-turn",
            kind: .subagent,
            lifecycle: .running,
            title: "Review cache behavior",
            summary: nil,
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: nil
        )

        harness.store.acceptExternalActivity(event)

        #expect(harness.catalog.session(id: event.sessionID)?.title == "Subagent task")
    }

    @Test func alreadyPrefixedUnknownSubagentSessionKeepsASinglePrefix() {
        let harness = makeStore(records: [])
        let event = ChatActivityEvent(
            eventID: "subagent-prefixed",
            sessionID: "prefixed-child-session",
            turnID: "prefixed-child-turn",
            kind: .subagent,
            lifecycle: .running,
            title: "sub_Review cache behavior",
            summary: nil,
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: nil
        )

        harness.store.acceptExternalActivity(event)

        #expect(harness.catalog.session(id: event.sessionID)?.title == "Subagent task")
    }

    @Test func activityForKnownParentSessionDoesNotRenameIt() {
        let known = SessionRecord(
            id: "known-parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Original parent title"
        )
        let harness = makeStore(records: [known])
        let event = ChatActivityEvent(
            eventID: "known-parent-activity",
            sessionID: known.id,
            turnID: "known-parent-turn",
            kind: .subagent,
            lifecycle: .running,
            title: "Child activity",
            summary: nil,
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: nil
        )

        harness.store.acceptExternalActivity(event)

        #expect(harness.catalog.session(id: known.id)?.title == known.title)
    }

    @Test func liveBotChatActivityProjectsIntoThePreparedChatCanvas() {
        let session = SessionRecord(
            id: "known-bot-chat-parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Active chat"
        )
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        let event = ChatActivityEvent(
            eventID: "live-bot-chat-return",
            sessionID: session.id,
            turnID: "live-bot-chat-turn",
            kind: .botHandoff,
            lifecycle: .succeeded,
            title: "Agent reply",
            summary: "@nova replied",
            detail: nil,
            occurredAt: 1_788_000_001,
            result: "Review complete.",
            botRunID: "bot-run-1",
            memberID: "default",
            fromMemberID: "nova",
            sourceOrder: 1
        )

        harness.store.acceptExternalActivity(event)

        let projected = model.activityTurns.flatMap(\.events)
        #expect(projected == [event])
        // Live tool events share a bounded checkpoint; an explicit lifecycle
        // flush must retain the complete authoritative event.
        model.flushPersistence()
        #expect(harness.catalog.session(id: session.id)?.activityEvents == [event])
        #expect(harness.catalog.records.count == 1)
    }

    @Test func terminalBotChatActivityPersistsBeforeTheChatIsPrepared() {
        let session = SessionRecord(
            id: "unopened-bot-chat-parent",
            kind: .direct,
            agentIDs: ["default"],
            title: "Unopened chat"
        )
        let harness = makeStore(records: [session])
        let event = ChatActivityEvent(
            eventID: "unopened-bot-chat-return",
            sessionID: session.id,
            turnID: "unopened-bot-chat-turn",
            kind: .botHandoff,
            lifecycle: .succeeded,
            title: "Agent reply",
            summary: "@nova replied",
            detail: nil,
            occurredAt: 1_788_000_002,
            result: "Review complete.",
            botRunID: "bot-run-unopened",
            memberID: "default",
            fromMemberID: "nova",
            sourceOrder: 1
        )

        harness.store.acceptExternalActivity(event)

        #expect(harness.catalog.session(id: session.id)?.activityEvents == [event])
    }

    @Test func automaticBotModeRouteRestoresSilentlyWhenPersistenceIsAvailable() throws {
        let session = SessionRecord(
            id: "bot-room-automatic-restore",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Restored Bot room",
            botModeRoomID: "bot-room-automatic-restore",
            hasAcceptedMessage: true
        )
        let room = try BotModeRoom(
            id: session.id,
            members: [
                .init(profileID: "finance", handle: "finance", sessionID: "finance-session"),
                .init(profileID: "research", handle: "research", sessionID: "research-session")
            ]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let persistence = ShellBotModePersistence(rooms: [room])
        let rooms = BotModeRoomStore(
            client: BotModeFixtureClient(),
            persistence: persistence
        )
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            botModeRooms: rooms
        )

        #expect(store.prepare(.chat(conversationID: session.id)))
        #expect(persistence.loadCount == 1)
        #expect(rooms.loadErrorMessage == nil)
    }

    @Test func explicitBotModeNavigationLoadsRoomPersistence() {
        let session = SessionRecord(
            id: "bot-room-explicit-load",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Bot room",
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let persistence = ShellFailingBotModePersistence()
        let rooms = BotModeRoomStore(
            client: BotModeFixtureClient(),
            persistence: persistence
        )
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            botModeRooms: rooms
        )

        #expect(throws: BotModePersistenceError.writeFailed) {
            try store.prepareForUserNavigation(
                .chat(conversationID: session.id)
            )
        }
        #expect(persistence.loadCount == 1)
    }

    @Test func savedSessionHistoryPrependsOlderPageIntoTheRouteOwnedModel() async throws {
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient())
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        try await catalog.load()
        let session = try await catalog.refreshExistingSession(
            id: "demo-tool-folder-anchor"
        )
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        model.beginHistoryHydration(from: session)
        _ = try await catalog.hydrateInitialPage(id: session.id)
        #expect(store.prepare(route))
        model.finishHistoryHydration(hasPreviousHistory: catalog.hasPreviousHistory(id: session.id))
        #expect(model.items.count == 1)
        #expect(model.items.first?.content == .message("Anchor sentinel stays visible."))

        model.beginLoadingPreviousHistory()
        _ = try await catalog.hydratePreviousPage(id: session.id)
        #expect(store.prepare(route))
        model.finishLoadingPreviousHistory(hasPreviousHistory: catalog.hasPreviousHistory(id: session.id))

        #expect(model.items.count == 21)
        #expect(model.items.first?.content == .message(
            "Earlier fixture update 1 keeps this restored conversation taller than one screen."
        ))
        #expect(model.items.last?.content == .message("Anchor sentinel stays visible."))
        #expect(!model.hasPreviousHistory)
    }

    @Test func savedSessionNavigationRefreshesBeforePresentingRouteOwnedHydration() {
        #expect(SessionRestorePresentationPolicy.opensCachedSessionBeforeHydration)
        let route = AppRoute.chat(conversationID: "session-route-owned-0001")
        #expect(SessionRestorePresentationPolicy.ownsHydration(route: route, path: [route]))
        #expect(!SessionRestorePresentationPolicy.ownsHydration(route: route, path: []))
        #expect(!SessionRestorePresentationPolicy.ownsHydration(
            route: route,
            path: [.scheduledTasks]
        ))
        let originPath: [AppRoute] = []
        #expect(SessionRestorePresentationPolicy.canComplete(
            originTab: .sessions,
            originPath: originPath,
            currentTab: .sessions,
            currentPath: originPath
        ))
        #expect(!SessionRestorePresentationPolicy.canComplete(
            originTab: .sessions,
            originPath: originPath,
            currentTab: .home,
            currentPath: originPath
        ))
        #expect(!SessionRestorePresentationPolicy.canComplete(
            originTab: .sessions,
            originPath: originPath,
            currentTab: .sessions,
            currentPath: [.scheduledTasks]
        ))
        #expect(SessionRestorePresentationPolicy.ownsRestore(
            route: route,
            originTab: .sessions,
            originPath: originPath,
            currentTab: .sessions,
            currentPath: [route]
        ))
        #expect(!SessionRestorePresentationPolicy.ownsRestore(
            route: route,
            originTab: .sessions,
            originPath: originPath,
            currentTab: .home,
            currentPath: []
        ))
        #expect(!SessionRestorePresentationPolicy.ownsRestore(
            route: route,
            originTab: .sessions,
            originPath: originPath,
            currentTab: .sessions,
            currentPath: [.scheduledTasks]
        ))
    }

    @Test func activeSessionContextRestoredFromCatalogIsReplayedWhenReopened() throws {
        let context = SessionContextSnapshot(
            sessionId: "session_context_reopen_0001",
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 1,
            isCompacting: false,
            updatedAt: 1_788_000_100
        )
        var session = record(id: context.sessionId)
        session.isActive = true
        session.workspaceID = "project-loopdy"
        session.workspaceName = "bighelp iOS"
        session.sessionContext = context
        let persisted = try JSONDecoder().decode(
            SessionRecord.self,
            from: JSONEncoder().encode(session)
        )
        let harness = makeStore(records: [persisted])

        let route = AppRoute.chat(conversationID: persisted.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        #expect(model.isSending)
        #expect(model.sessionContext == context)
        #expect(ProjectChangesTargetResolver.target(
            agentID: "finance",
            sessionID: model.conversationID,
            restoredWorkspaceID: model.sessionWorkspaceID,
            restoredWorkspaceName: model.sessionWorkspaceName,
            loadedWorkspaceID: nil,
            loadedWorkspaceName: nil
        ) == ProjectGitTarget(
            agentID: "finance",
            sessionID: context.sessionId,
            workspaceID: "project-loopdy",
            workspaceName: "bighelp iOS"
        ))
    }

    @Test func changedRemoteCoordinateClearsRestoredContextFromPreparedChat() async throws {
        let sessionID = "session_context_coordinate_change_0001"
        let context = SessionContextSnapshot(
            sessionId: sessionID,
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 1,
            isCompacting: false,
            updatedAt: 1_788_000_100
        )
        var cached = record(id: sessionID)
        cached.remoteStoredID = "stored-old-coordinate"
        cached.remoteSource = "loopdy"
        cached.workspaceID = "project-old"
        cached.workspaceName = "Old Project"
        cached.sessionContext = context
        var current = cached
        current.remoteStoredID = "stored-new-coordinate"
        current.workspaceID = nil
        current.workspaceName = nil
        current.sessionContext = nil
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [current]),
            records: [cached]
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: sessionID)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        #expect(model.sessionContext == context)

        try await catalog.load()
        #expect(store.prepare(route))

        #expect(model.sessionContext == nil)
        #expect(model.sessionWorkspaceID == nil)
        #expect(model.sessionWorkspaceName == nil)
    }

    @Test func sessionRailSnapshotsReceivedBeforeRoutePreparationAreReconciledIntoChat() {
        let session = record(id: "session_rail_snapshots_0001")
        let harness = makeStore(records: [session])
        let context = SessionContextSnapshot(
            sessionId: session.id,
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 1,
            isCompacting: true,
            updatedAt: 1_788_000_101
        )
        let todo = ChatTaskItem(id: "task-1", content: "Verify the rail", status: .inProgress)
        let subagent = SessionSubagentSnapshot(
            id: "subagent-1",
            sessionID: "child_session_0001",
            parentID: nil,
            role: "Reviewer",
            goal: "Review the session rail",
            startedAt: 1_788_000_102
        )

        harness.store.acceptSessionContext(context)
        harness.store.acceptSessionTodos(SessionTodoSnapshot(
            sessionID: session.id,
            revision: 3,
            todos: [todo],
            updatedAt: 1_788_000_103
        ))
        harness.store.acceptSessionSubagents(SessionSubagentRosterSnapshot(
            sessionID: session.id,
            subagents: [subagent],
            updatedAt: 1_788_000_104
        ))

        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        #expect(model.sessionContext == context)
        #expect(model.taskDrawer?.items == [todo])
        #expect(model.sessionSubagents == [subagent])
    }

    @Test func repeatedLiveSessionTitlesUpdateTheCatalogAndPreparedChatInPlace() {
        let session = record(id: "session_live_title_updates_0001")
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))

        for (title, timestamp) in [
            ("First automatic title", 1_788_000_201),
            ("Second automatic title", 1_788_000_202),
            ("Current automatic title", 1_788_000_203),
        ] {
            harness.store.acceptSessionContext(SessionContextSnapshot(
                sessionId: session.id,
                title: title,
                model: "gpt-5.6-sol",
                contextUsed: 10_000,
                contextMax: 258_000,
                contextPercent: 4,
                compressions: 0,
                isCompacting: false,
                updatedAt: timestamp
            ))
        }

        #expect(harness.catalog.session(id: session.id)?.title == "Current automatic title")
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        #expect(model.sessionTitle == "Current automatic title")
    }

    @Test func preparedChatModelsObserveTheCurrentAppWideMidSessionDefault() {
        let session = record(id: "session_mid_session_settings_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let behavior = ShellMidSessionBehaviorBox(.steer)
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            midSessionBehavior: { behavior.value }
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        #expect(model.defaultMidSessionBehavior == .steer)

        behavior.value = .queued
        #expect(model.defaultMidSessionBehavior == .queued)
    }

    @Test func unsentDirectChatAgentSelectionUpdatesHeaderCanonicalSessionAndSendRoute() async throws {
        let session = record(id: "session_agent_reassignment_0001")
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "session-agent-reassignment-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [session]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )
        let profiles = [
            AgentProfile(
                id: "finance",
                name: "Finance",
                role: "Finance agent",
                summary: "",
                instructions: "",
                avatarFileName: nil,
                isDefault: true
            ),
            AgentProfile(
                id: "research",
                name: "Research",
                role: "Research agent",
                summary: "",
                instructions: "",
                avatarFileName: nil,
                isDefault: false
            ),
        ]
        let agents = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        var routedClients: [String: AgentRoutedConversationClient] = [:]
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agents: agents,
            conversationClient: { session, _ in
                let agentID = session.agentIDs.first ?? "default"
                let client = AgentRoutedConversationClient(agentID: agentID)
                routedClients[agentID] = client
                return client
            }
        )
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }

        let result = store.reassignDirectChat(sessionID: session.id, to: "research")
        model.draft = "Route this to research"
        await model.send()

        #expect(result == .reassigned)
        #expect(model.memberIDs == ["research"])
        #expect(catalog.session(id: session.id)?.agentIDs == ["research"])
        #expect(ChatDestinationAgentResolver(catalog: catalog, agents: agents).resolve(sessionID: session.id)
            == ChatDestinationAgentIdentity(name: "Research", role: "Research agent"))
        #expect(routedClients["finance"]?.messages.isEmpty == true)
        #expect(routedClients["research"]?.messages == ["Route this to research"])
        #expect(model.items.last?.sender.id == "research")

        let restored = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            repository: repository
        )
        #expect(restored.session(id: session.id)?.agentIDs == ["research"])
    }

    @Test func acceptedDirectChatRefusesAgentReassignmentWithoutChangingHistoryOrRoute() async {
        let human = TimelineItem(
            id: "accepted-human",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("Keep this with Finance"),
            metadata: .init(delivery: "Sent")
        )
        let session = SessionRecord(
            id: "session_agent_reassignment_history_0001",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [human],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let financeClient = AgentRoutedConversationClient(agentID: "finance")
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in financeClient }
        )
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }

        let result = store.reassignDirectChat(sessionID: session.id, to: "research")

        #expect(result == .blockedByHistory)
        #expect(model.memberIDs == ["finance"])
        #expect(model.items == [human.ordered(1)])
        #expect(catalog.session(id: session.id)?.kind == .direct)
        #expect(catalog.session(id: session.id)?.agentIDs == ["finance"])
        #expect(catalog.session(id: session.id)?.items.map(\.id) == ["accepted-human"])
        #expect(catalog.session(id: session.id)?.items.map(\.content) == [human.content])
    }

    @Test func chatPreparationUsesTheInjectedProductionConversationClient() async {
        let session = record(id: "session_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let client = InjectedConversationClient()
        let sessionControl = ShellSessionControlMessagingFixture()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in client },
            sessionControlMessaging: sessionControl
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected Chat model")
            return
        }
        model.draft = "Use the live client"
        await model.send()

        #expect(client.messages == ["Use the live client"])
        #expect(model.runtimeControls?.sessionID == session.id)
        #expect(model.runtimeControls?.agentID == "finance")
    }

    @Test func openingExistingActiveChatShowsItsModelBeforeOpeningPicker() async throws {
        var session = record(id: "session_saved_model_fixture_0001")
        session.remoteStoredID = "stored_saved_model_fixture_0001"
        session.isActive = true
        session.sessionContext = SessionContextSnapshot(
            sessionId: session.id, model: "session-selected-model",
            contextUsed: 100, contextMax: 1000, contextPercent: 10,
            compressions: 0, isCompacting: false, updatedAt: 100
        )
        let messaging = ShellSessionControlMessagingFixture()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [session]),
            agentRuntimeDefaults: ShellAgentRuntimeDefaultsFixture(),
            sessionControlMessaging: messaging
        )
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let controls = model.runtimeControls else {
            Issue.record("Expected session runtime controls")
            return
        }
        #expect(controls.currentModel == "session-selected-model")
        for _ in 0..<5 { await Task.yield() }
        #expect(controls.currentModel == "session-selected-model")
        #expect(messaging.openedKinds.allSatisfy { $0 == .reasoning })
        model.reconcileSessionContext(.init(sessionId: session.id, model: "live-fallback-model",
            contextUsed: 200, contextMax: 1000, contextPercent: 20,
            compressions: 0, isCompacting: false, updatedAt: 101))
        #expect(controls.currentModel == "live-fallback-model")
        model.reconcileSessionContext(session.sessionContext!)
        #expect(controls.currentModel == "live-fallback-model")
    }

    @Test func freshlyCreatedChatWithRemoteCoordinateLoadsDefaultsWithoutOpeningPicker() async throws {
        var session = record(id: "new-chat-remote-coordinate")
        session.remoteStoredID = session.id
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [session])
        let defaults = ShellAgentRuntimeDefaultsFixture()
        let messaging = ShellSessionControlMessagingFixture()
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog,
            agentRuntimeDefaults: defaults, sessionControlMessaging: messaging)
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepareNewChat(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared chat"); return
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.runtimeControls?.currentModel == "gpt-5.6")
        #expect(model.runtimeControls?.currentProvider == "openai")
        #expect(messaging.openedKinds.allSatisfy { $0 == .reasoning })
    }

    @Test func restoredEmptyRemoteChatDoesNotBorrowAgentDefaults() async throws {
        var session = record(id: "restored-empty-remote")
        session.remoteStoredID = session.id
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [session])
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog,
            agentRuntimeDefaults: ShellAgentRuntimeDefaultsFixture(),
            sessionControlMessaging: ShellSessionControlMessagingFixture())
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected prepared chat"); return
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.runtimeControls?.currentModel == nil)
    }

    @Test func chatPreparationSeedsTheSelectedAgentsMainChatDefaultsIntoSessionControls() async {
        let session = record(id: "session_runtime_defaults_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let runtimeDefaults = ShellAgentRuntimeDefaultsFixture()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agentRuntimeDefaults: runtimeDefaults,
            sessionControlMessaging: ShellSessionControlMessagingFixture()
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let controls = model.runtimeControls else {
            Issue.record("Expected session runtime controls")
            return
        }

        for _ in 0..<3 { await Task.yield() }

        #expect(runtimeDefaults.requestedAgentIDs == ["finance"])
        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningValue == "high")
    }

    @Test func chatPreparationRetriesTransientAgentDefaultsFailure() async {
        let session = record(id: "session_runtime_defaults_retry_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let runtimeDefaults = ShellAgentRuntimeDefaultsFixture()
        runtimeDefaults.defaultsLoadFailuresRemaining = 1
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agentRuntimeDefaults: runtimeDefaults,
            runtimeDefaultsRetryDelays: [.milliseconds(0)],
            sessionControlMessaging: ShellSessionControlMessagingFixture()
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let controls = model.runtimeControls else {
            Issue.record("Expected session runtime controls")
            return
        }

        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(1))
            if runtimeDefaults.requestedAgentIDs.count == 2 { break }
        }

        #expect(runtimeDefaults.requestedAgentIDs == ["finance", "finance"])
        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningValue == "high")
    }

    @Test func chatPreparationSurfacesAgentDefaultsFailureAfterRetries() async {
        let session = record(id: "session_runtime_defaults_failure_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let runtimeDefaults = ShellAgentRuntimeDefaultsFixture()
        runtimeDefaults.defaultsLoadFailuresRemaining = 2
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agentRuntimeDefaults: runtimeDefaults,
            runtimeDefaultsRetryDelays: [.milliseconds(0)],
            sessionControlMessaging: ShellSessionControlMessagingFixture()
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let controls = model.runtimeControls else {
            Issue.record("Expected session runtime controls")
            return
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while controls.errorMessage == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(runtimeDefaults.requestedAgentIDs == ["finance", "finance"])
        #expect(controls.errorMessage == "Couldn’t load agent defaults. Check your Hermes connection and try again.")
    }

    @Test func reconnectRetryHydratesDefaultsForAnAlreadyPreparedChat() async {
        let session = record(id: "session_runtime_defaults_reconnect_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let runtimeDefaults = ShellAgentRuntimeDefaultsFixture()
        runtimeDefaults.defaultsLoadFailuresRemaining = 1
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agentRuntimeDefaults: runtimeDefaults,
            runtimeDefaultsRetryDelays: [],
            sessionControlMessaging: ShellSessionControlMessagingFixture()
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let controls = model.runtimeControls else {
            Issue.record("Expected session runtime controls")
            return
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(controls.currentModel == nil)

        runtimeDefaults.defaultsLoadFailuresRemaining = 0
        store.retryAgentRuntimeDefaults()
        for _ in 0..<5 { await Task.yield() }

        #expect(runtimeDefaults.requestedAgentIDs == ["finance", "finance"])
        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningValue == "high")
    }

    @Test func chatPreparationBindsTheHermesCommandCatalogToTheExactSessionAndAgent() async throws {
        let session = record(id: "session_commands_fixture_0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let commands = ShellSlashCommandCatalogClientFixture()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            slashCommandCatalogClient: commands
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route),
              let commandCatalog = model.slashCommandCatalog else {
            Issue.record("Expected a session-bound command catalog")
            return
        }
        await commandCatalog.load()

        #expect(commands.requests == [
            .init(sessionID: session.id, agentID: "finance"),
        ])
        #expect(commandCatalog.commands.map(\.name) == ["help"])
    }

    @Test func externallyArrivingFinalUpdatesThePreparedOpenChatImmediately() {
        let session = record(id: "session_fixture_0001")
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        let final = TimelineItem(
            id: "message_final_live_0001",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Juno")),
            content: .message("The live final answer"),
            metadata: .init(delivery: "Delivered")
        )

        harness.store.acceptExternal([final], conversationID: session.id)

        #expect(model.items.last?.id == final.id)
        #expect(model.items.last?.content == final.content)
        #expect(model.items.last?.metadata.sourceOrder == 1)
        #expect(harness.catalog.session(id: session.id)?.items.last == model.items.last)
        // This harness has no disk repository. The repository-backed terminal
        // test below verifies the separate durable flush contract.
    }

    @Test func responseHapticsUseTheRealUnsolicitedRouteAndSuppressCatchup() throws {
        let session = record(id: "session_haptic_route_fixture_0001")
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model"); return
        }
        var events: [ResponseTextGrowth] = []
        let subscription = model.responseTextGrowth.sink { events.append($0) }
        func deliver(_ id: String, _ text: String, delivery: String = "draft") throws {
            routeUnsolicitedAssistantMessage(try assistantMessage(messageID: id, sessionID: session.id, delivery: delivery, draftID: delivery == "draft" ? 1 : nil, text: text), featureStore: harness.store, agentDirectory: nil)
        }
        try deliver("message_haptic_commentary_0001", "Let me check")
        #expect(events.count == 1)
        try deliver("message_haptic_commentary_0001", "Let me check")
        #expect(events.count == 1)
        try deliver("message_haptic_commentary_0001", "Let me check the result")
        #expect(events.count == 2)
        harness.store.setChatPresentationDeferred(true)
        try deliver("message_haptic_catchup_0001", "Historical catchup")
        #expect(events.count == 2)
        harness.store.setChatPresentationDeferred(false)
        #expect(events.count == 2)
        try deliver("message_haptic_final_0001", "The answer", delivery: "final")
        #expect(events.count == 3)
        #expect(events.last?.messageID == "message_haptic_final_0001")
        withExtendedLifetime(subscription) {}
    }

    @Test func unsolicitedAssistantDraftRevisionsAndFinalUpdateOnePreparedChatMessage() throws {
        let session = record(id: "session_unsolicited_live_fixture_0001")
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }

        let draft = try assistantMessage(
            messageID: "message_unsolicited_stream_0001",
            sessionID: session.id,
            delivery: "draft",
            draftID: 1,
            text: "Juno is checking the weather…"
        )
        routeUnsolicitedAssistantMessage(
            draft,
            featureStore: harness.store,
            agentDirectory: nil
        )

        #expect(model.streamingItem == nil)
        #expect(model.presentedItems.last?.content == .message("Juno is checking the weather…"))
        #expect(harness.catalog.session(id: session.id)?.items.last?.id == draft.messageID)
        #expect(model.items.last?.metadata.sourceOrder == 1)

        let revisedDraft = try assistantMessage(
            messageID: draft.messageID,
            sessionID: session.id,
            delivery: "draft",
            draftID: 1,
            text: "Juno found the forecast and is checking details…"
        )
        routeUnsolicitedAssistantMessage(
            revisedDraft,
            featureStore: harness.store,
            agentDirectory: nil
        )

        #expect(model.items.count == 1)
        #expect(model.items.last?.content == .message("Juno found the forecast and is checking details…"))
        #expect(model.items.last?.metadata.sourceOrder == 1)

        let final = try assistantMessage(
            messageID: draft.messageID,
            sessionID: session.id,
            delivery: "final",
            text: "The weather is clear and 72°F."
        )
        routeUnsolicitedAssistantMessage(
            final,
            featureStore: harness.store,
            agentDirectory: nil
        )

        #expect(model.streamingItem == nil)
        #expect(model.items.last?.content == .message("The weather is clear and 72°F."))
        #expect(model.items.map(\.id) == [final.messageID])
        #expect(model.items.compactMap(\.metadata.sourceOrder) == [1])
        #expect(harness.catalog.session(id: session.id)?.items.last?.id == final.messageID)
    }

    @Test func shellExternalStreamingTailMutationIsBoundedAndSavesOnlyAtTerminalFlush() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShellStreamingScale-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settled = (1...1_000).map { (index: Int) in
            TimelineItem(
                id: "shell-settled-\(index)",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                content: .message("Settled \(index)"),
                metadata: .init(delivery: "Delivered", sourceOrder: index)
            )
        }
        let session = SessionRecord(
            id: "shell-streaming-scale",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Scale",
            items: settled,
            hasAcceptedMessage: true
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [session]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session],
            repository: repository
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        #expect(store.prepare(.chat(conversationID: session.id)))

        for revision in 1...20 {
            store.acceptExternal([TimelineItem(
                id: "shell-live-tail",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                content: .message("Revision \(revision)"),
                metadata: .init(delivery: "Streaming")
            )], conversationID: session.id)
            #expect(catalog.lastChatMutationWorkCount <= 2)
        }
        #expect(catalog.repositorySaveCount == 0)
        #expect(catalog.session(id: session.id)?.items.count == 1_001)
        #expect(catalog.session(id: session.id)?.items.last?.content == .message("Revision 20"))

        store.acceptExternal([TimelineItem(
            id: "shell-live-tail",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Final"),
            metadata: .init(delivery: "Delivered")
        )], conversationID: session.id)

        #expect(catalog.repositorySaveCount == 1)
        #expect(try repository.load().first?.items.last?.content == .message("Final"))
    }

    @Test func shellExternalStreamingChatModelWorkIsIndependentOfSettledPrefixLength() {
        func mutationWork(settledCount: Int) -> Int {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "shell-model-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let session = SessionRecord(
                id: "shell-model-scaling-\(settledCount)",
                kind: .direct,
                agentIDs: ["finance"],
                title: "Scale",
                items: settled,
                hasAcceptedMessage: true
            )
            let catalog = SessionCatalogStore(
                client: SessionCatalogFixtureClient(),
                records: [session]
            )
            let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
            let route = AppRoute.chat(conversationID: session.id)
            #expect(store.prepare(route))
            guard case .chat(let model) = store.preparedModel(for: route) else {
                Issue.record("Expected prepared Chat model")
                return .max
            }
            for text in ["First", "Revision"] {
                store.acceptExternal([TimelineItem(
                    id: "shell-model-live-tail",
                    role: .assistant,
                    sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                    content: .message(text),
                    metadata: .init(delivery: "Streaming")
                )], conversationID: session.id)
            }
            return model.lastItemMutationWorkCount
        }

        let shortWork = mutationWork(settledCount: 10)
        let longWork = mutationWork(settledCount: 1_000)

        #expect(shortWork == 2)
        #expect(longWork == 2)
    }

    @Test func firstShellExternalStreamingDraftWorkIsIndependentOfSettledPrefixLength() {
        func mutationWork(settledCount: Int) -> Int {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "first-shell-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let session = SessionRecord(
                id: "first-shell-scaling-\(settledCount)",
                kind: .direct,
                agentIDs: ["finance"],
                title: "Scale",
                items: settled,
                hasAcceptedMessage: true
            )
            let catalog = SessionCatalogStore(
                client: SessionCatalogFixtureClient(),
                records: [session]
            )
            let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
            let route = AppRoute.chat(conversationID: session.id)
            #expect(store.prepare(route))
            guard case .chat(let model) = store.preparedModel(for: route) else {
                Issue.record("Expected prepared Chat model")
                return .max
            }

            store.acceptExternal([TimelineItem(
                id: "first-shell-live-tail",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                content: .message("First"),
                metadata: .init(delivery: "Streaming")
            )], conversationID: session.id)
            return model.lastItemMutationWorkCount
        }

        let shortWork = mutationWork(settledCount: 10)
        let longWork = mutationWork(settledCount: 1_000)

        #expect(longWork <= shortWork + 2)
        #expect(longWork <= 4)
    }

    @Test func externalStreamingUpdateReplacesExistingNonTailItemWithoutDuplicatingItsID() {
        let existing = TimelineItem(
            id: "older-streaming-item",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Earlier revision"),
            metadata: .init(delivery: "Streaming", sourceOrder: 1)
        )
        let settledTail = TimelineItem(
            id: "settled-tail",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Settled tail"),
            metadata: .init(delivery: "Delivered", sourceOrder: 2)
        )
        let session = SessionRecord(
            id: "shell-nontail-streaming-update",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Non-tail",
            items: [existing, settledTail],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))

        store.acceptExternal([TimelineItem(
            id: existing.id,
            role: existing.role,
            sender: existing.sender,
            content: .message("Updated earlier revision"),
            metadata: .init(delivery: "Streaming")
        )], conversationID: session.id)

        let items = catalog.session(id: session.id)?.items ?? []
        #expect(items.map(\.id) == [existing.id, settledTail.id])
        #expect(items.first?.content == .message("Updated earlier revision"))
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func unsolicitedNativeAttachmentIsResolvedBeforeItReachesTheChat() async throws {
        let session = record(id: "session_unsolicited_attachment_fixture_0001")
        let harness = makeStore(records: [session])
        let route = AppRoute.chat(conversationID: session.id)
        #expect(harness.store.prepare(route))
        guard case .chat(let model) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected prepared Chat model")
            return
        }
        let resolver = ShellAgentAttachmentResolver()
        let final = try assistantMessage(
            messageID: "message_unsolicited_attachment_0001",
            sessionID: session.id,
            delivery: "final",
            text: "MEDIA:/private/render.png"
        )

        let resolutionTask = routeUnsolicitedAssistantMessage(
            final,
            featureStore: harness.store,
            agentDirectory: nil,
            attachmentResolver: resolver
        )
        await resolutionTask?.value

        #expect(model.items.last?.content == .message("Rendered image attached."))
        #expect(model.items.last?.attachments.map(\.fileName) == ["render.png"])
        #expect(resolver.receivedStoredID == session.id)
    }

    @Test func preparingAnAlreadyCachedChatReconcilesARecentlyHydratedTranscript() async throws {
        let summary = record(id: "session_hydrate_fixture_0001")
        let restoredMessage = TimelineItem(
            id: "history-assistant-0001",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Juno")),
            content: .message("The restored answer"),
            metadata: .init(delivery: "Saved")
        )
        let restored = SessionRecord(
            id: summary.id,
            kind: .direct,
            agentIDs: summary.agentIDs,
            title: summary.title,
            items: [
                TimelineItem(
                    id: "history-user-0001",
                    role: .human,
                    sender: .user(snapshot: .init(name: "You")),
                    content: .message("What did you find?"),
                    metadata: .init(delivery: "Saved")
                ),
                restoredMessage,
            ],
            hasAcceptedMessage: true
        )
        let sessionClient = SessionCatalogFixtureClient(
            records: [summary],
            hydrated: [summary.id: restored]
        )
        let catalog = SessionCatalogStore(client: sessionClient, records: [summary])
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: summary.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected a cached Chat model")
            return
        }
        #expect(model.items.isEmpty)

        _ = try await catalog.hydrateSession(id: summary.id)
        #expect(store.prepare(route))

        #expect(model.items.map(\.id) == restored.items.map(\.id))
        #expect(model.items.map(\.content) == restored.items.map(\.content))
        #expect(model.items.compactMap(\.metadata.sourceOrder) == [1, 2])
        #expect(model.items.last?.id == restoredMessage.id)
        #expect(model.items.last?.content == restoredMessage.content)
    }

    @Test func routeLookupDoesNotPrepareMissingModel() {
        let store = makeStore(records: [record(id: "demo-finance")]).store
        let route = AppRoute.chat(conversationID: "missing")

        if case .some = store.preparedModel(for: route) {
            Issue.record("A lookup created a missing route model")
        }
        if case .some = store.preparedModel(for: route) {
            Issue.record("The first lookup mutated the route cache")
        }
    }

    @Test func routePreparationRejectsUnknownApprovalFixture() {
        let store = makeStore(records: []).store
        let known = AppRoute.approval(requestID: ApprovalRequest.vendorFixture.id)
        let unknown = AppRoute.approval(requestID: "approval-unknown")

        #expect(store.prepare(known))
        guard case .approval(let model) = store.preparedModel(for: known) else {
            Issue.record("Known approval fixture was not prepared")
            return
        }
        #expect(model.request.id == ApprovalRequest.vendorFixture.id)

        #expect(!store.prepare(unknown))
        if case .some = store.preparedModel(for: unknown) {
            Issue.record("Unknown approval route aliased a fixture model")
        }
    }

    @Test func loadedApprovalPreservesEveryAuthoritativeHermesDecisionScope() async throws {
        let loaded = LoadedApprovalRequest(
            request: .vendorFixture,
            allowedDecisions: [.once, .session, .always, .deny]
        )
        let loader = ShellApprovalRequestLoaderFixture(loaded: loaded)
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: SessionCatalogStore(client: SessionCatalogFixtureClient(), records: []),
            approvalRequestLoader: loader,
            approvalClient: ApprovalFixtureClient(confirmationDelay: .zero)
        )
        let route = AppRoute.approval(requestID: loaded.request.id)

        #expect(try await store.prepareApproval(id: loaded.request.id))
        guard case .approval(let model) = store.preparedModel(for: route) else {
            Issue.record("Loaded approval was not prepared")
            return
        }

        #expect(loader.requestedIDs == [loaded.request.id])
        #expect(model.request == loaded.request)
        #expect(model.availableDecisions == [.once, .session, .always, .deny])
    }

    @Test func routeOwnershipEvictsDiscardedFreshChatsWithoutChangingRetainedIdentity() {
        let named = AppRoute.chat(conversationID: "demo-finance")
        let reachableFresh = AppRoute.chat(conversationID: "demo-new-100")
        let discardedFresh = (1...40).map {
            AppRoute.chat(conversationID: "demo-new-\($0)")
        }
        let store = makeStore(records: [
            record(id: "demo-finance"),
            record(id: "demo-new-100")
        ] + discardedFresh.compactMap { route in
            guard case .chat(let conversationID) = route else { return nil }
            return record(id: conversationID)
        }).store

        #expect(store.prepare(named))
        #expect(store.prepare(reachableFresh))
        discardedFresh.forEach { #expect(store.prepare($0)) }

        guard case .chat = store.preparedModel(for: named),
              case .chat(let reachableModel) = store.preparedModel(for: reachableFresh) else {
            Issue.record("Expected prepared Chat models")
            return
        }
        let discardedConversationID = "demo-new-1"
        #expect(
            store.makeVoicePresentation(for: discardedConversationID).id
                == "demo-new-1-voice-1"
        )
        #expect(
            store.makeVoicePresentation(for: discardedConversationID).id
                == "demo-new-1-voice-2"
        )

        store.retainModels(ownedBy: [reachableFresh])

        guard case .chat(let retainedReachableModel) = store.preparedModel(for: reachableFresh) else {
            Issue.record("Reachable model was evicted")
            return
        }
        #expect(retainedReachableModel === reachableModel)
        if case .some = store.preparedModel(for: named) {
            Issue.record("Discarded Chat model remained cached")
        }
        for route in discardedFresh {
            if case .some = store.preparedModel(for: route) {
                Issue.record("Discarded fresh Chat remained cached: \(route)")
            }
        }
        #expect(
            store.makeVoicePresentation(for: discardedConversationID).id
                == "demo-new-1-voice-1"
        )
    }

    @Test func routeModelsStayStableAndVoiceSessionsRemainConversationScoped() {
        let store = makeStore(records: [
            record(id: "demo-finance"),
            record(id: "demo-travel")
        ]).store
        let financeRoute = AppRoute.chat(conversationID: "demo-finance")
        let travelRoute = AppRoute.chat(conversationID: "demo-travel")
        let approvalRoute = AppRoute.approval(
            requestID: ApprovalRequest.vendorFixture.id
        )

        #expect(store.prepare(financeRoute))
        #expect(store.prepare(travelRoute))
        #expect(store.prepare(approvalRoute))
        guard case .chat(let financeChat) = store.preparedModel(for: financeRoute),
              case .chat(let restoredFinanceChat) = store.preparedModel(for: financeRoute),
              case .chat(let travelChat) = store.preparedModel(for: travelRoute),
              case .approval(let approval) = store.preparedModel(for: approvalRoute),
              case .approval(let restoredApproval) = store.preparedModel(for: approvalRoute) else {
            Issue.record("Expected prepared fixture models")
            return
        }

        #expect(financeChat === restoredFinanceChat)
        #expect(financeChat !== travelChat)
        #expect(approval === restoredApproval)
        #expect(approval.status == .idle)

        let firstFinanceVoice = store.makeVoicePresentation(for: "demo-finance")
        let nextFinanceVoice = store.makeVoicePresentation(for: "demo-finance")
        let travelVoice = store.makeVoicePresentation(for: "demo-travel")
        #expect(firstFinanceVoice.id != nextFinanceVoice.id)
        #expect(firstFinanceVoice.model !== nextFinanceVoice.model)
        #expect(firstFinanceVoice.model !== travelVoice.model)
        #expect(travelVoice.model.conversationID == "demo-travel")
    }

    @Test func evictedChatModelRestoresDraftFromCanonicalSession() {
        let harness = makeStore(records: [record(id: "session-1")])
        let route = AppRoute.chat(conversationID: "session-1")
        #expect(harness.store.prepare(route))
        guard case .chat(let original) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected an initial Chat model")
            return
        }
        original.draft = "Keep this draft"

        harness.store.retainModels(ownedBy: [])
        #expect(harness.store.preparedModel(for: route) == nil)
        #expect(harness.store.prepare(route))
        guard case .chat(let restored) = harness.store.preparedModel(for: route) else {
            Issue.record("Expected a restored Chat model")
            return
        }
        #expect(restored !== original)
        #expect(restored.draft == "Keep this draft")
    }

    @Test func preparingAHermesActiveSessionRestoresItsRunningPresentation() {
        var active = record(id: "session-hermes-active-0001")
        active.isActive = true
        let store = makeStore(records: [active]).store
        let route = AppRoute.chat(conversationID: active.id)

        #expect(store.prepare(route))
        guard case .chat(let model) = store.preparedModel(for: route) else {
            Issue.record("Expected an active Chat model")
            return
        }

        #expect(model.isSending)
    }

    @Test func statusOnlyHydrationReactivatesTheRetainedChatModel() async throws {
        let cached = record(id: "session-status-only-active-0001")
        var active = cached
        active.isActive = true
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(hydrated: [cached.id: active]),
            records: [cached]
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: cached.id)

        #expect(store.prepare(route))
        guard case .chat(let cachedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected a cached Chat model")
            return
        }
        #expect(!cachedModel.isSending)

        _ = try await catalog.hydrateSession(id: cached.id)
        #expect(store.prepare(route))
        guard case .chat(let hydratedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the hydrated Chat model")
            return
        }

        #expect(hydratedModel === cachedModel)
        #expect(hydratedModel.isSending)
    }

    @Test func statusOnlyHydrationRetiresARemotelyRestoredActiveTurn() async throws {
        var active = record(id: "session-status-only-inactive-0001")
        active.isActive = true
        var inactive = active
        inactive.isActive = false
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(hydrated: [active.id: inactive]),
            records: [active]
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: active.id)

        #expect(store.prepare(route))
        guard case .chat(let activeModel) = store.preparedModel(for: route) else {
            Issue.record("Expected an active Chat model")
            return
        }
        #expect(activeModel.isSending)

        _ = try await catalog.hydrateSession(id: active.id)
        #expect(store.prepare(route))
        guard case .chat(let hydratedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the hydrated Chat model")
            return
        }

        #expect(hydratedModel === activeModel)
        #expect(!hydratedModel.isSending)
    }

    @Test func reopeningAHermesActiveSessionRoutesTheNextMessageAsSteering() async {
        var active = record(id: "session-hermes-active-steer-0001")
        active.isActive = true
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [active]
        )
        let messaging = ShellSubmissionRecordingMessaging()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in messaging }
        )
        let route = AppRoute.chat(conversationID: active.id)

        #expect(store.prepare(route))
        store.retainModels(ownedBy: [])
        #expect(store.prepare(route))
        guard case .chat(let reopenedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the Hermes-active Chat model to reopen")
            return
        }

        #expect(reopenedModel.isSending)
        reopenedModel.draft = "Use the simpler fix instead"
        await reopenedModel.sendMidSession(using: .steer)

        #expect(messaging.submissions.count == 1)
        #expect(messaging.submissions.first?.sessionID == active.id)
        #expect(messaging.submissions.first?.text == "Use the simpler fix instead")
        #expect(messaging.submissions.first?.behavior == .steer)
        #expect(reopenedModel.isSending)
    }

    @Test func leavingAndReopeningAChatRetainsItsActuallyRunningTurnModel() async {
        let session = record(id: "session-active-route-0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let client = ShellControlledConversationClient()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in client }
        )
        let route = AppRoute.chat(conversationID: session.id)

        #expect(store.prepare(route))
        guard case .chat(let runningModel) = store.preparedModel(for: route) else {
            Issue.record("Expected a prepared Chat model")
            return
        }
        runningModel.draft = "Keep working"
        let turn = Task { await runningModel.send() }
        await client.waitUntilStarted()
        #expect(runningModel.isSending)

        store.retainModels(ownedBy: [])
        #expect(store.prepare(route))
        guard case .chat(let reopenedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the active Chat model to remain resumable")
            client.finish()
            await turn.value
            return
        }

        #expect(reopenedModel === runningModel)
        #expect(reopenedModel.isSending)

        client.finish()
        await turn.value
    }

    @Test func navigationAwayFlushesDirtyActiveChatAndRetainsItsModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActiveNavigationFlush-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionRecord(
            id: "active-navigation-flush",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Active",
            isActive: true,
            hasAcceptedMessage: true
        )
        let repository = DemoRepository<[SessionRecord]>(
            directory: directory,
            name: "sessions",
            seed: [session]
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session],
            repository: repository
        )
        let store = ShellFeatureStore(timing: .immediate, catalog: catalog)
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let model)? = store.preparedModel(for: route) else {
            Issue.record("Expected active chat")
            return
        }
        model.draft = "Persist before leaving"

        store.retainModels(ownedBy: [])

        #expect(catalog.repositorySaveCount == 1)
        #expect(try repository.load().first?.draft == "Persist before leaving")
        guard case .chat(let retained)? = store.preparedModel(for: route) else {
            Issue.record("Active chat must remain retained")
            return
        }
        #expect(retained === model)
        #expect(retained.isSending)
    }

    @Test func inactiveHydrationWithoutATerminalReplyDoesNotRetireALocallyRunningTurn() async throws {
        let active = record(id: "session-active-hydration-0001")
        var incompleteHydration = active
        incompleteHydration.isActive = false
        incompleteHydration.items = [
            TimelineItem(
                id: "hermes:stored-session:canonical-human",
                role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("Keep working"),
                metadata: .init(delivery: "Saved", sourceOrder: 1)
            ),
        ]
        incompleteHydration.hasAcceptedMessage = true
        let catalogClient = SessionCatalogFixtureClient(
            hydrated: [active.id: incompleteHydration]
        )
        let catalog = SessionCatalogStore(client: catalogClient, records: [active])
        let client = ShellControlledConversationClient()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in client }
        )
        let route = AppRoute.chat(conversationID: active.id)

        #expect(store.prepare(route))
        guard case .chat(let runningModel) = store.preparedModel(for: route) else {
            Issue.record("Expected a prepared Chat model")
            return
        }
        runningModel.draft = "Keep working"
        let turn = Task { await runningModel.send() }
        await client.waitUntilStarted()
        store.retainModels(ownedBy: [])

        _ = try await catalog.hydrateSession(id: active.id)
        #expect(store.prepare(route))
        guard case .chat(let reopenedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the running Chat model to reopen")
            client.finish()
            await turn.value
            return
        }

        #expect(reopenedModel === runningModel)
        #expect(reopenedModel.isSending)

        client.finish()
        await turn.value
    }

    @Test(arguments: [true, false])
    func reopeningCompletedSessionRequiresThePendingMessageIdentity(matchesCurrentSubmission: Bool) async throws {
        let active = record(id: "session-completed-route-0001")
        let canonicalAssistant = TimelineItem(
            id: "hermes:stored-session:assistant-final",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("The original turn finished while this chat was away."),
            metadata: .init(delivery: "Saved", sourceOrder: 2)
        )
        let canonicalHuman = TimelineItem(id: "hermes:stored-session:human-original", role: .human,
            sender: .user(snapshot: .init(name: "You")), content: .message("Original request"),
            metadata: .init(delivery: "Saved", sourceOrder: 1, platformMessageID: matchesCurrentSubmission ? "message_reopen_1" : "message_prior_turn"))
        var completed = active
        completed.isActive = false
        completed.items = [canonicalHuman, canonicalAssistant]
        completed.hasAcceptedMessage = true
        let catalogClient = SessionCatalogFixtureClient(
            hydrated: [active.id: completed]
        )
        let catalog = SessionCatalogStore(client: catalogClient, records: [active])
        let messaging = ShellReattachingChatMessaging()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in messaging }
        )
        let route = AppRoute.chat(conversationID: active.id)

        #expect(store.prepare(route))
        guard case .chat(let runningModel) = store.preparedModel(for: route) else {
            Issue.record("Expected a prepared Chat model")
            return
        }
        runningModel.draft = "Original request"
        let originalTurn = Task { await runningModel.send() }
        await messaging.waitUntilFirstSendStarts()
        store.retainModels(ownedBy: [])

        _ = try await catalog.hydrateSession(id: active.id)
        #expect(store.prepare(route))
        guard case .chat(let reopenedModel) = store.preparedModel(for: route) else {
            Issue.record("Expected the completed Chat model to reopen")
            return
        }

        #expect(reopenedModel === runningModel)
        if !matchesCurrentSubmission {
            #expect(reopenedModel.isSending)
            #expect(messaging.reconciledInactiveSessionIDs.isEmpty)
            #expect(!reopenedModel.items.contains(where: { $0.id == canonicalAssistant.id }))
            messaging.reconcileInactiveSession(conversationID: active.id)
            await originalTurn.value
            return
        }
        #expect(!reopenedModel.isSending)
        #expect(reopenedModel.items.map(\.id) == [canonicalHuman.id, canonicalAssistant.id])
        #expect(messaging.reconciledInactiveSessionIDs == [active.id])

        reopenedModel.draft = "Follow up now"
        await reopenedModel.send()
        await originalTurn.value

        #expect(messaging.messages == ["Original request", "Follow up now"])
        #expect(!reopenedModel.isSending)
    }

    @Test func voiceOpenedFromAnActiveChatInheritsSteeringAuthority() {
        let session = record(id: "voice-active-session")
        let (store, catalog) = makeStore(records: [session])
        catalog.markActiveForLocalTurn(id: session.id)
        let voice = store.makeVoicePresentation(for: session.id, mode: .walkieTalkie).model
        #expect(voice.isAgentRunActive)
        #expect(voice.status == .working)
        voice.reconcileAgentRun(isActive: false)
        #expect(!voice.isAgentRunActive)
        #expect(voice.status == .listening)
    }

    @Test func endingVoiceDuringATurnKeepsChatActiveUntilHermesFinishes() async throws {
        let session = record(id: "session-voice-chat-handoff-0001")
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: [session]
        )
        let voiceInput = ShellVoiceHandoffInputSource()
        let voiceClient = ShellVoiceHandoffClient()
        let store = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            conversationClient: { _, _ in ShellStoppableConversationClient() },
            voiceClient: { _, _ in voiceClient },
            voiceInputLevelSource: { voiceInput }
        )
        let route = AppRoute.chat(conversationID: session.id)
        #expect(store.prepare(route))
        guard case .chat(let chat) = store.preparedModel(for: route) else {
            Issue.record("Expected a prepared Chat model")
            return
        }
        let voice = store.makeVoicePresentation(for: session.id).model

        await voice.startMonitoring()
        voiceInput.emit(.init(text: "Keep working after voice closes", isFinal: true))
        await voiceClient.waitUntilRequested()

        #expect(chat.isSending)
        #expect(catalog.session(id: session.id)?.isActive == true)
        #expect(await voice.end())
        #expect(!voice.isActive)
        #expect(chat.isSending)
        #expect(catalog.session(id: session.id)?.isActive == true)

        let final = TimelineItem(
            id: "voice-chat-handoff-final",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Finished after voice closed."),
            metadata: .init(delivery: "Delivered")
        )
        voiceClient.complete(with: final)
        await voice.waitUntilTurnSettles()

        #expect(!chat.isSending)
        #expect(chat.items.last?.id == final.id)
        #expect(catalog.session(id: session.id)?.isActive == false)
    }

    private func makeStore(records: [SessionRecord]) -> (store: ShellFeatureStore, catalog: SessionCatalogStore) {
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(),
            records: records
        )
        return (ShellFeatureStore(timing: .immediate, catalog: catalog), catalog)
    }

    private func record(id: String) -> SessionRecord {
        SessionRecord(
            id: id,
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance"
        )
    }

    private func assistantMessage(
        messageID: String,
        sessionID: String,
        delivery: String,
        draftID: Int? = nil,
        text: String
    ) throws -> BighelpLinkAssistantMessage {
        try BighelpLinkAssistantMessage.decode([
            "version": 1,
            "type": "assistant.message",
            "messageId": messageID,
            "sessionId": sessionID,
            "agentId": "finance",
            "agentName": "Juno",
            "text": text,
            "sentAt": 1_788_000_001,
            "delivery": delivery,
            "draftId": draftID as Any,
        ])
    }
}

@MainActor
private final class ShellBotModePersistence: BotModeRoomPersistence {
    private let rooms: [BotModeRoom]
    private(set) var loadCount = 0

    init(rooms: [BotModeRoom]) {
        self.rooms = rooms
    }

    func load(recoveringRuns: Bool) throws -> [BotModeRoom] {
        loadCount += 1
        return rooms
    }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        room
    }
}

@MainActor
private final class ShellAgentAttachmentResolver: AgentAttachmentResolving {
    private(set) var receivedStoredID: String?

    func resolve(
        agentID: String,
        storedID: String,
        items: [AgentAttachmentTextItem]
    ) async throws -> [ResolvedAgentAttachmentItem] {
        receivedStoredID = storedID
        return [
            ResolvedAgentAttachmentItem(
                id: items[0].id,
                text: "Rendered image attached.",
                attachments: [
                    try ChatAttachment(
                        id: "attachment_unsolicited_0001",
                        fileName: "render.png",
                        mimeType: "image/png",
                        data: Data([0x89, 0x50, 0x4E, 0x47])
                    ),
                ]
            ),
        ]
    }
}

@MainActor
private final class ShellFailingBotModePersistence: BotModeRoomPersistence {
    private(set) var loadCount = 0

    func load(recoveringRuns: Bool) throws -> [BotModeRoom] {
        loadCount += 1
        throw BotModePersistenceError.writeFailed
    }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        throw BotModePersistenceError.writeFailed
    }
}

@MainActor
private final class ShellMidSessionBehaviorBox {
    var value: MidSessionChatBehavior

    init(_ value: MidSessionChatBehavior) {
        self.value = value
    }
}

@MainActor
private final class ShellApprovalRequestLoaderFixture: ApprovalRequestLoading {
    let loaded: LoadedApprovalRequest
    private(set) var requestedIDs: [String] = []

    init(loaded: LoadedApprovalRequest) {
        self.loaded = loaded
    }

    func loadApproval(id: String) async throws -> LoadedApprovalRequest {
        requestedIDs.append(id)
        return loaded
    }
}

@MainActor
private final class ShellVoiceHandoffInputSource: VoiceInputLevelSource {
    var onLevel: ((Float, UInt64) -> Void)?
    var onTranscript: ((VoiceRecognitionUpdate, UInt64) -> Void)?
    var onUnavailable: ((VoiceInputLevelError, UInt64) -> Void)?
    private var generation: UInt64 = 0

    func start(generation: UInt64) async throws {
        self.generation = generation
    }

    func stop() {}

    func emit(_ update: VoiceRecognitionUpdate) {
        onTranscript?(update, generation)
    }
}

@MainActor
private final class ShellVoiceHandoffClient: VoiceSessionClient {
    private var continuation: CheckedContinuation<VoiceAgentReply, Error>?
    private(set) var requests: [String] = []

    func respond(
        to transcript: String,
        conversationID: String,
        onDraft: @escaping (String) -> Void
    ) async throws -> VoiceAgentReply {
        requests.append(transcript)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func endSession(conversationID: String) async throws {}

    func waitUntilRequested() async {
        while requests.isEmpty { await Task.yield() }
    }

    func complete(with item: TimelineItem) {
        guard case .message(let text) = item.content else { return }
        continuation?.resume(returning: VoiceAgentReply(
            speaker: item.sender.snapshot.name,
            text: text,
            timelineItems: [item]
        ))
        continuation = nil
    }
}

@MainActor
private final class ShellStoppableConversationClient: StoppableConversationClient {
    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }

    func stop(conversationID: String) async throws {}
}

@MainActor
private final class InjectedConversationClient: ConversationClient {
    private(set) var messages: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        messages.append(message)
        return ConversationResponse(items: [
            TimelineItem(
                id: "response_fixture_0001",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                content: .message("Live response"),
                metadata: TimelineMetadata(delivery: "Delivered")
            )
        ])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }
}

@MainActor
private final class ShellControlledConversationClient: ConversationClient {
    private var continuation: CheckedContinuation<ConversationResponse, Error>?
    private var didStart = false

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func finish() {
        continuation?.resume(returning: ConversationResponse(items: []))
        continuation = nil
    }
}

@MainActor
private final class ShellReattachingChatMessaging: InactiveSessionReconciliationConversationClient {
    private var firstContinuation: CheckedContinuation<ConversationResponse, Error>?
    private(set) var messages: [String] = []
    private(set) var reconciledInactiveSessionIDs: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        messages.append(message)
        guard messages.count == 1 else { return ConversationResponse(items: []) }
        return try await withCheckedThrowingContinuation { firstContinuation = $0 }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }

    func pendingMessageID(conversationID: String) -> String? {
        firstContinuation == nil ? nil : "message_reopen_1"
    }

    func reconcileInactiveSession(conversationID: String) {
        reconciledInactiveSessionIDs.append(conversationID)
        firstContinuation?.resume(throwing: CancellationError())
        firstContinuation = nil
    }

    func waitUntilFirstSendStarts() async {
        while firstContinuation == nil { await Task.yield() }
    }
}

@MainActor
private final class ShellSubmissionRecordingMessaging: MidSessionConversationClient {
    struct Submission {
        let sessionID: String
        let text: String
        let behavior: MidSessionChatBehavior
    }
    private(set) var submissions: [Submission] = []

    func sendMidSession(message: String, attachments: [ChatAttachment], conversationID: String,
        behavior: MidSessionChatBehavior, onDraft: @escaping (TimelineItem) -> Void) async throws -> MidSessionSubmissionOutcome {
        submissions.append(Submission(sessionID: conversationID, text: message, behavior: behavior))
        return .accepted
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        throw CancellationError()
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }
}

@MainActor
private final class AgentRoutedConversationClient: ConversationClient {
    let agentID: String
    private(set) var messages: [String] = []

    init(agentID: String) {
        self.agentID = agentID
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        messages.append(message)
        return ConversationResponse(items: [
            TimelineItem(
                id: "response-\(agentID)-\(messages.count)",
                role: .assistant,
                sender: .agent(id: agentID, snapshot: .init(name: agentID.capitalized)),
                content: .message("Reply from \(agentID)"),
                metadata: .init(delivery: "Delivered")
            )
        ])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }
}

@MainActor
private final class ShellSessionControlMessagingFixture: BighelpLinkSessionControlMessaging {
    private(set) var openedKinds: [BighelpLinkPickerKind] = []
    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        openedKinds.append(request.kind)
        throw BighelpLinkLiveSocketError.invalidPickerResponse
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        throw BighelpLinkLiveSocketError.invalidPickerResponse
    }
}

@MainActor
private final class ShellAgentRuntimeDefaultsFixture: AgentRuntimeDefaultsClient {
    private(set) var requestedAgentIDs: [String] = []
    var defaultsLoadFailuresRemaining = 0

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        requestedAgentIDs.append(agentID)
        if defaultsLoadFailuresRemaining > 0 {
            defaultsLoadFailuresRemaining -= 1
            throw AgentRuntimeDefaultsFixtureError.transient
        }
        return AgentRuntimeDefaults(
            mainChats: AgentRuntimeSelection(
                providerID: "openai",
                modelID: "gpt-5.6",
                reasoningEffort: "high"
            ),
            subagents: .automatic,
            scheduledTasks: .automatic
        )
    }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        []
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {}
}

private enum AgentRuntimeDefaultsFixtureError: Error {
    case transient
}

@MainActor
private final class ShellSlashCommandCatalogClientFixture: SlashCommandCatalogClient {
    struct Request: Equatable {
        let sessionID: String
        let agentID: String
    }

    private(set) var requests: [Request] = []

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        requests.append(.init(sessionID: sessionID, agentID: agentID))
        return [
            SlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                category: "Help",
                argsHint: "[query]",
                aliases: ["commands"],
                argumentMode: .text,
                source: .core,
                requiresArguments: false
            ),
        ]
    }
}

@MainActor
private final class CatchUpDashboardSource: DashboardDataSource {
    var loadCount = 0
    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        return DashboardSnapshot(weather: nil, inbox: [], attentionItems: [], completedItems: [], agents: [])
    }
}
