import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatBotModeIntegrationTests {
    @Test func roomProjectionHidesAllWorkKindsWithoutChangingDirectChats() {
        let kinds: [ChatActivityKind] = [.reasoning, .tool, .subagent, .botHandoff]
        let events = kinds.enumerated().map { index, kind in
            ChatActivityEvent(
                eventID: "work-\(index)", sessionID: "room", turnID: "turn",
                kind: kind, lifecycle: .succeeded, title: "Recorded work",
                summary: "Recorded work detail", detail: nil, occurredAt: index,
                sourceOrder: index
            )
        }
        let visibility = ChatActivityVisibility(showReasoning: true, showToolCalls: true)
        let room = ChatTranscriptProjection.entries(
            items: [], activityEvents: events, visibility: visibility, isBotMode: true
        )
        let direct = ChatTranscriptProjection.entries(
            items: [], activityEvents: events, visibility: visibility, isBotMode: false
        )
        #expect(room.isEmpty)
        #expect(direct.flatMap { entry -> [ChatActivityEvent] in
            if case .activity(let turn) = entry { return turn.events }
            return []
        } == events)
    }

    /// Nothing goes out through the placeholder: the message waits for the chat's own connection,
    /// and comes back to the box if that never comes.
    @Test func anUnpreparedDirectChatWaitsForItsConnectionAndKeepsItsDraft() async throws {
        let model = ChatModel(conversationID: "unprepared-direct", client: NativeWorkspaceUnavailableClient(),
            initialItems: [], initialDraft: "Keep this draft")
        #expect(!model.isBotMode)
        #expect(model.canSend)
        await model.send()
        #expect(model.stagedSends.count == 1)
        #expect(model.items.isEmpty)
        model.connectionIsOverdue = true
        for _ in 0..<200 where !model.stagedSends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.draft == "Keep this draft")
        #expect(model.items.isEmpty)
    }

    @Test func selectingOutsideAgentAddsMemberAndReplacesPartialMention() throws {
        let model = ChatModel.testBotFixture(draft: "Please ask @res")

        try model.selectMention(agentID: "research", replacing: "@res")

        #expect(model.draft == "Please ask @research ")
        #expect(model.memberIDs == ["finance", "research"])
    }

    @Test func mentionSuggestionsIncludeEveryoneCurrentAndOutsideAgents() {
        let model = ChatModel.testBotFixture(draft: "Please ask @")

        #expect(model.mentionSuggestions.map(\.kind) == [.everyone, .member, .outsideAgent])
        #expect(model.mentionSuggestions.first?.title == "Everyone")
        #expect(model.mentionSuggestions.contains(where: { $0.agentID == "finance" }))
        #expect(model.mentionSuggestions.contains(where: { $0.agentID == "research" }))
    }

    @Test func disabledPersistedRoomRemainsReadableButCannotExecuteOrChangeMembership() async throws {
        let model = ChatModel.testBotFixture(
            draft: "Ask @research",
            roomMemberIDs: ["finance", "research"],
            sharedEvents: [.human(text: "Prior shared turn", id: "prior-shared")],
            executionEnabled: false
        )
        let visibleBefore = model.timelineEvents

        #expect(model.isBotMode)
        #expect(model.botModeExecutionEnabled == false)
        #expect(model.canInteractWithBotMode == false)
        #expect(model.canSend == false)
        #expect(model.botModeStatus == "Connect to the selected Hermes host to run this room.")
        #expect(model.timelineEvents == visibleBefore)

        #expect(throws: BotModeRoomError.executionUnavailable) {
            try model.addMember(agentID: "travel")
        }
        #expect(throws: BotModeRoomError.executionUnavailable) {
            try model.removeMember(agentID: "research")
        }

        await model.send()

        #expect(model.draft == "Ask @research")
        #expect(model.timelineEvents == visibleBefore)
        #expect(model.failureMessage == "Group chats are unavailable for this Hermes connection.")
    }

    @Test(arguments: [false, true])
    func verifiedHermesBotModeExecutesThroughHostedRoomsWithLocalHarnessDisabled(usesUnavailableDirectClient: Bool) async throws {
        let legacy = BotModeFixtureClient()
        let model = ChatModel.testBotFixture(
            draft: "@everyone check in",
            roomMemberIDs: ["finance", "research"],
            client: legacy,
            executionEnabled: false,
            conversationClient: usesUnavailableDirectClient ? NativeWorkspaceUnavailableClient() : nil
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        native.logPages = [[
            .fixture(roomID: "bot-fixture", sequence: 2, eventID: "native-answer", kind: "message.member",
                     payload: ["member_id": .string("finance"), "text": .string("Hosted room answer")]),
            .fixture(roomID: "bot-fixture", sequence: 3, eventID: "native-settled", kind: "room.activity",
                     payload: ["status": .string("settled"), "discussion_event_id": .string("pending")])
        ]]
        store.configureNativeClient(native)
        await store.refreshNativeCapabilities()

        #expect(model.botModeExecutionEnabled)
        #expect(model.canSend)
        await model.send()

        #expect(legacy.requests.isEmpty)
        #expect(native.sentPayloads.map(\.text) == ["@everyone check in"])
        #expect(model.timelineEvents.contains(where: { $0.text == "Hosted room answer" }))
        #expect(model.failureMessage == nil)
        #expect(model.isSending == false)
        #expect(model.canEditBotModeMembership == false)
    }

    @Test(arguments: [false, true])
    func recoveredNativeSendClearsItsFailureWithoutDiscardingANewerDraft(hasNewerDraft: Bool) async throws {
        let originalText = "@everyone check in "
        let model = ChatModel.testBotFixture(
            draft: originalText, roomMemberIDs: ["finance", "research"], executionEnabled: false
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        native.acceptedResponseLostRemaining = 1
        native.onSend = { native.blockGroupsState = true }
        native.logPages = [[
            .fixture(roomID: "bot-fixture", sequence: 1, eventID: "canonical-user", kind: "message.user",
                     payload: ["text": .string(originalText), "thread_id": .string("loopdy-bot-fixture")]),
            .fixture(roomID: "bot-fixture", sequence: 2, eventID: "native-answer", kind: "message.member",
                     payload: ["member_id": .string("finance"), "text": .string("Recovered answer")]),
            .fixture(roomID: "bot-fixture", sequence: 3, eventID: "native-settled", kind: "room.activity",
                     payload: ["status": .string("settled"), "discussion_event_id": .string("pending")]),
        ]]
        store.configureNativeClient(native)
        defer {
            native.blockGroupsState = false
            native.releaseNextBlockedGroupsState()
            store.configureNativeClient(nil)
        }
        await store.refreshNativeCapabilities()
        await model.send()
        let pendingID = try #require(store.room(id: "bot-fixture")?.nativePendingEventID)
        #expect(model.failureMessage == "Delivery is unconfirmed. Recovery will use this same message identity.")
        #expect(model.canRetry)
        #expect(model.draft == originalText)
        if hasNewerDraft { model.draft = "A different unsent message" }
        native.onSend = nil
        native.blockGroupsState = false
        native.releaseNextBlockedGroupsState()
        let deadline = ContinuousClock.now + .seconds(2)
        while store.room(id: "bot-fixture")?.nativePendingEventID != nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(store.room(id: "bot-fixture")?.nativePendingEventID == nil)
        #expect(store.room(id: "bot-fixture")?.nativeCompletedDiscussionEventIDs.contains("server-\(pendingID)") == true)
        #expect(native.sentEventIDs == [pendingID, pendingID])
        #expect(model.timelineEvents.filter { $0.text == "Recovered answer" }.count == 1)
        #expect(model.failureMessage == nil)
        #expect(!model.canRetry)
        #expect(model.draft == (hasNewerDraft ? "A different unsent message" : ""))
    }

    @Test func botModeStopUsesTheOfficialRoomStopWhileSendIsWaiting() async throws {
        let model = ChatModel.testBotFixture(
            draft: "@everyone check in",
            roomMemberIDs: ["finance", "research"],
            executionEnabled: false
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        store.configureNativeClient(native)
        await store.refreshNativeCapabilities()
        let sending = Task { await model.send() }
        await native.waitUntilSendStarts()

        #expect(model.canStop)
        await model.stop()
        await sending.value

        #expect(native.stopped.count == 1)
        #expect(native.stopped.first?.roomID == "bot-fixture")
        #expect(model.isSending == false)
        #expect(model.failureMessage == nil)
        #expect(store.room(id: "bot-fixture")?.isRunning == false)
    }

    /// "I cannot message a group chat while it's active." Hermes queues a
    /// message sent during a member turn behind the room's drive, so the
    /// message box stays usable and Send goes out while agents work.
    @Test func groupChatSendsWhileAgentsAreStillWorking() async throws {
        let model = ChatModel.testBotFixture(
            draft: "@everyone plan the trip",
            roomMemberIDs: ["finance", "research"],
            executionEnabled: false
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        store.configureNativeClient(native)
        defer { store.configureNativeClient(nil) }
        await store.refreshNativeCapabilities()
        let sending = Task { await model.send() }
        for _ in 0..<200 where store.room(id: "bot-fixture")?.nativePendingDiscussionEventID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.isSending)
        #expect(store.room(id: "bot-fixture")?.isRunning == true)

        model.draft = "@finance keep it under budget"
        #expect(!model.isComposerInputDisabled)
        #expect(model.canSend)
        await model.send()

        #expect(native.sentPayloads.map(\.text) == ["@everyone plan the trip", "@finance keep it under budget"])
        #expect(model.draft.isEmpty)
        #expect(model.failureMessage == nil)
        #expect(model.isSending)
        #expect(model.canStop)

        await model.stop()
        await sending.value
        #expect(store.room(id: "bot-fixture")?.nativeFollowUps.isEmpty == true)
        #expect(model.isSending == false)
    }

    @Test func nativeApprovalIsVisibleDuringSendAndOnlyTheCurrentCardCanResolve() async throws {
        let model = ChatModel.testBotFixture(
            draft: "@everyone review this task",
            roomMemberIDs: ["finance", "research"],
            executionEnabled: false
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        native.driverStatus = ["pending_actions": .array([.object([
            "kind": .string("approval"),
            "member_id": .string("finance"),
            "task_id": .string("task-review"),
            "execution_generation": .integer(1),
            "request_id": .string("request-review"),
            "approval": .object([
                "request_id": .string("request-review"),
                "command": .string("git status --short"),
                "choices": .array([.string("once"), .string("deny")])
            ])
        ])])]
        native.driverStatusAfterApproval = ["pending_actions": .array([])]
        store.configureNativeClient(native)
        await store.refreshNativeCapabilities()
        let sending = Task { await model.send() }
        let deadline = ContinuousClock.now + .seconds(2)
        while model.pendingBotModeApprovals.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let approval = try #require(model.pendingBotModeApprovals.first)
        #expect(model.isSending)
        #expect(approval.command == "git status --short")

        await model.resolveBotModeApproval(approval, choice: .deny)
        await model.resolveBotModeApproval(approval, choice: .once)

        #expect(native.approvals.count == 1)
        #expect(native.approvals.first?.choice == .deny)
        #expect(model.pendingBotModeApprovals.isEmpty)
        #expect(model.botModeApprovalSubmissions.isEmpty)
        #expect(model.botModeApprovalErrors.isEmpty)
        await model.stop()
        await sending.value
    }

    @Test func interruptedNativeTaskOffersRetryWithoutAPersistedFailureOrRetryRequest() async throws {
        let model = ChatModel.testBotFixture(
            draft: "@everyone check in",
            roomMemberIDs: ["finance", "research"],
            executionEnabled: false
        )
        let store = try #require(model.botModeRoomStore)
        let native = NativeBotModeTestClient(capabilities: .fixture())
        native.driverStatus = [
            "working": .boolean(false),
            "blocked": .boolean(true),
            "pending_actions": .array([.object([
                "kind": .string("retry"), "task_id": .string("interrupted-task")
            ])])
        ]
        store.configureNativeClient(native)
        await store.refreshNativeCapabilities()
        await model.send()

        #expect(model.memberFailures.isEmpty)
        #expect(model.hasNativeBotModeRetryActions)
        #expect(model.canRetry)
        #expect(!model.isSending)
        model.draft = "Do another thing"
        #expect(!model.canSend)
        #expect(model.canStop)
        await model.stop()
    }

    @Test func disabledDirectChatCannotCreateBotModeFromMention() throws {
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let directory = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let direct = SessionRecord(
            id: "disabled-direct",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance"
        )
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false
        )
        let model = ChatModel(
            conversationID: direct.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "Please ask @res",
            sourceSession: direct,
            botModeRoomStore: store,
            agentDirectory: directory
        )

        #expect(throws: BotModeRoomError.executionUnavailable) {
            try model.selectMention(agentID: "research", replacing: "@res")
        }
        #expect(model.isBotMode == false)
        #expect(model.draft == "Please ask @res")
    }

    @Test func removingAddedAgentFromUnsentRoomCollapsesBackToDirectChat() throws {
        let model = ChatModel.testBotFixture(
            draft: "@research ",
            roomMemberIDs: ["finance", "research"]
        )

        try model.removeMember(agentID: "research")

        #expect(model.memberIDs == ["finance"])
        #expect(!model.isBotMode)
        #expect(model.botModeMemberCountLabel == "1 agent")
        #expect(model.draft.isEmpty)
        #expect(!model.timelineEvents.contains(where: { $0.kind == .botModeStarted }))
        #expect(model.botModeRoomStore?.room(id: "bot-fixture") == nil)

        try model.addMember(agentID: "research")

        #expect(model.isBotMode)
        #expect(model.memberIDs == ["finance", "research"])
    }

    @Test func removingToOneAgentPreservesRoomAfterSharedHumanMessage() throws {
        let model = ChatModel.testBotFixture(
            roomMemberIDs: ["finance", "research"],
            sharedEvents: [.human(text: "Keep this shared turn", id: "shared-human")]
        )

        #expect(throws: BotModeRoomError.sharedHistoryRequiresBotMode) {
            try model.removeMember(agentID: "research")
        }

        #expect(model.isBotMode)
        #expect(model.memberIDs == ["finance", "research"])
        #expect(model.botModeRoomStore?.room(id: "bot-fixture")?.visibleEvents.last?.id == "shared-human")
    }

    @Test func removingToOneAgentPreservesRoomAfterSharedAgentMessage() throws {
        let model = ChatModel.testBotFixture(
            roomMemberIDs: ["finance", "research"],
            sharedEvents: [.agent(memberID: "research", text: "Keep this reply", id: "shared-agent")]
        )

        #expect(throws: BotModeRoomError.sharedHistoryRequiresBotMode) {
            try model.removeMember(agentID: "research")
        }

        #expect(model.isBotMode)
        #expect(model.memberIDs == ["finance", "research"])
        #expect(model.botModeRoomStore?.room(id: "bot-fixture")?.visibleEvents.last?.id == "shared-agent")
    }

    @Test func roomStoreRepositoryRetainsRosterAndPrivacyBoundaryAcrossRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-bot-mode-\(UUID().uuidString)")
        let direct = SessionRecord(
            id: "direct-finance",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [
                TimelineItem(
                    id: "private-finance-message",
                    role: .assistant,
                    sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                    content: .message("Private finance context"),
                    metadata: .init()
                )
            ]
        )
        let room = try BotModeRoom.fromDirect(session: direct, adding: "research")
        let repository = DemoRepository<[BotModeRoom]>(directory: directory, name: "rooms", seed: [])
        let store = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository)

        try store.persist(room: room)
        var removed = room
        _ = try removed.remove(memberID: "research")
        try store.persist(room: removed)

        let restored = BotModeRoomStore(client: BotModeFixtureClient(), repository: repository)
        try restored.load()

        #expect(restored.room(id: room.id)?.memberIDs == ["finance"])
        #expect(restored.room(id: room.id)?.privateHistory.first?.content == .message("Private finance context"))
        #expect(restored.room(id: room.id)?.visibleEvents.map(\.kind) == [.botModeStarted])
    }

    @Test func headerNewChatUsesSharedCoordinator() async throws {
        let harness = try await ChatDestinationHarness(selectedAgentID: "research")

        await harness.tapNewChat()

        #expect(harness.openedSession?.agentIDs == ["research"])
    }

    @Test func directChatRetainsItsOriginalTimelineAndDoesNotBecomeBotMode() {
        let original = TimelineItem(
            id: "direct-original",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Direct-only reply"),
            metadata: .init()
        )
        let model = ChatModel(
            conversationID: "direct-chat",
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [original]
        )

        #expect(!model.isBotMode)
        #expect(model.items == [original.ordered(1)])
        #expect(model.memberIDs == ["finance"])
    }

    @Test func roomRejectsOutsideAgentWhenRosterIsAtCapacity() throws {
        var room = BotModeRoom.fixture(id: "full-room", memberIDs: ["one", "two", "three", "four", "five", "six"])

        #expect(try room.add(memberID: "outside") == .atCapacity)
        #expect(room.memberIDs.count == BotModeRoom.maximumMembers)
    }

    @Test func directMentionStartsRoomWithoutReplayingPrivateHistoryToNewAgent() throws {
        let directItem = TimelineItem(
            id: "private-direct",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Direct-only context"),
            metadata: .init()
        )
        let direct = SessionRecord(
            id: "direct-finance",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [directItem]
        )
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient())
        let model = ChatModel(
            conversationID: direct.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: direct.items,
            initialDraft: "Please ask @res",
            sourceSession: direct,
            botModeRoomStore: rooms,
            agentDirectory: agents
        )

        try model.selectMention(agentID: "research", replacing: "@res")

        #expect(model.isBotMode)
        #expect(model.memberIDs == ["finance", "research"])
        #expect(model.items == [directItem.ordered(1)])
        #expect(model.botModeRoom?.memberContexts["research"]?.messages.isEmpty == true)
        #expect(model.draft == "Please ask @research ")
    }

    @Test func mentionSuggestionsFilterByActiveTokenAndReplaceOnlyCursorRange() throws {
        let model = ChatModel.testBotFixture(draft: "@res and @fin")
        model.setMentionCursor(offset: 4)

        #expect(model.mentionSuggestions.map(\.agentID) == ["research"])

        try model.selectMention(agentID: "research", replacing: "@res")

        #expect(model.draft == "@research and @fin")
        #expect(model.mentionToken == nil)
    }

    @Test func mentionSuggestionsLeaveCodeAndURLMentionsInert() {
        let model = ChatModel.testBotFixture(draft: "`@res` https://example.test/@res")

        #expect(model.mentionSuggestions.isEmpty)
    }

    @Test func collisionSafeMemberHandlesAreUsedForSuggestionsAndRoster() throws {
        let sameNameOne = AgentProfile.sameNameFixture(id: "same-one")
        let sameNameTwo = AgentProfile.sameNameFixture(id: "same-two")
        let model = ChatModel.testBotFixture(
            draft: "@",
            profiles: [sameNameOne, sameNameTwo],
            roomMemberIDs: [sameNameOne.id]
        )

        #expect(model.mentionSuggestions.first(where: { $0.agentID == sameNameOne.id })?.handle == "same-name")
        #expect(model.mentionSuggestions.first(where: { $0.agentID == sameNameTwo.id })?.handle == "same-name-2")

        try model.selectMention(agentID: sameNameTwo.id, replacing: "@")

        #expect(model.draft == "@same-name-2 ")
        #expect(model.memberHandle(for: sameNameOne.id) == "same-name")
        #expect(model.memberHandle(for: sameNameTwo.id) == "same-name-2")
    }

    @Test func directConversionSuggestionsUseProspectiveCollisionSafeHandles() throws {
        let sameNameOne = AgentProfile.sameNameFixture(id: "same-one")
        let sameNameTwo = AgentProfile.sameNameFixture(id: "same-two")
        let direct = SessionRecord(
            id: "same-direct",
            kind: .direct,
            agentIDs: [sameNameOne.id],
            title: "Same name"
        )
        let profiles = [sameNameOne, sameNameTwo]
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let model = ChatModel(
            conversationID: direct.id,
            client: ConversationFixtureClient(canonicalAgentID: sameNameOne.id),
            agentID: sameNameOne.id,
            initialItems: [],
            initialDraft: "@",
            sourceSession: direct,
            botModeRoomStore: BotModeRoomStore(client: BotModeFixtureClient()),
            agentDirectory: agents
        )

        #expect(model.mentionSuggestions.first(where: { $0.agentID == sameNameTwo.id })?.handle == "same-name-2")
    }

    @Test func persistenceFailureDoesNotReplaceMentionOrExposeRoom() throws {
        let persistence = ChatBotModeTestPersistence(rejectInsert: true)
        let direct = SessionRecord(
            id: "direct-persistence-failure",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance"
        )
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let model = ChatModel(
            conversationID: direct.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "Please ask @res",
            sourceSession: direct,
            botModeRoomStore: BotModeRoomStore(client: BotModeFixtureClient(), persistence: persistence),
            agentDirectory: agents
        )

        #expect(throws: BotModeRoomError.persistenceConflict) {
            try model.selectMention(agentID: "research", replacing: "@res")
        }

        #expect(model.draft == "Please ask @res")
        #expect(model.botModeRoomID == nil)
        #expect(model.failureMessage != nil)
    }

    @Test func failedRoomSendRestoresDraftAndRetryUsesRoomStoreWithoutDuplicateHuman() async throws {
        let persistence = ChatBotModeTestPersistence(compareSaveResults: [nil])
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.reply("finance reply")],
            "research": [.reply("research reply")]
        ])
        let model = ChatModel.testBotFixture(
            draft: "@everyone first",
            roomMemberIDs: ["finance", "research"],
            client: client,
            persistence: persistence
        )

        await model.send()

        #expect(model.draft == "@everyone first")
        #expect(model.canRetry)
        #expect(client.requests.isEmpty)

        await model.retry()

        #expect(client.requests.count == 2)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == BotModeEvent.Kind.human }.count == 1)
        #expect(!model.canRetry)
    }

    @Test func partialMemberFailureRetryOnlyDispatchesFailedMember() async throws {
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.failure("finance unavailable"), .reply("finance recovered")],
            "research": [.reply("research reply")]
        ])
        let model = ChatModel.testBotFixture(
            draft: "@everyone first",
            roomMemberIDs: ["finance", "research"],
            client: client
        )

        await model.send()

        #expect(model.memberFailures.map { $0.memberID } == ["finance"])
        #expect(model.memberFailures.first?.message == "finance unavailable")
        #expect(model.failureMessage != nil)
        #expect(model.canRetry)
        #expect(client.requests.map(\.memberID) == ["finance", "research"])

        await model.retry()

        #expect(client.requests.map(\.memberID) == ["finance", "research", "finance"])
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == BotModeEvent.Kind.human }.count == 1)
        #expect(model.memberFailures.isEmpty)
        #expect(model.botModeTimelineItems.contains(where: { $0.content == TimelineContent.message("finance recovered") }))
    }

    @Test func openBotModeChatRetainsHandoffWithoutShowingActivityCards() async throws {
        let client = ChatBotModeDeferredClient()
        let model = ChatModel.testBotFixture(
            draft: "Please coordinate",
            roomMemberIDs: ["finance"],
            client: client
        )

        let sending = Task { await model.send() }
        await client.waitForRequest()

        let running = try #require(model.activityTurns.flatMap(\.events).first)
        #expect(running.kind == .botHandoff)
        #expect(running.lifecycle == .running)
        #expect(running.sessionID == model.conversationID)
        #expect(running.turnID == client.requests.first?.sharedEvents.last(where: { $0.kind == .human })?.id)
        #expect(running.memberID == "finance")
        #expect(running.botRunID?.isEmpty == false)
        #expect(running.title == "Finley joined the turn")
        #expect(model.transcriptEntries.allSatisfy {
            if case .activity = $0 { return false }
            return true
        })

        client.resume(.reply("Coordinated reply"))
        await sending.value

        let settled = try #require(model.activityTurns.flatMap(\.events).first)
        #expect(settled.id == running.id)
        #expect(settled.lifecycle == .succeeded)
        #expect(settled.summary == "@finley responded to the room.")
        #expect(model.transcriptEntries.allSatisfy {
            if case .activity = $0 { return false }
            return true
        })
    }

    @Test func botModeTranscriptShowsMessagesWithoutAgentActivityCards() async throws {
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.reply("Finance final")],
            "research": [.reply("Research final")],
        ])
        let model = ChatModel.testBotFixture(
            draft: "@everyone report in",
            roomMemberIDs: ["finance", "research"],
            client: client
        )

        await model.send()

        let presentation = model.transcriptEntries.map { entry in
            switch entry {
            case .message(let item):
                guard case .message(let text) = item.content else { return "message:\(item.sender.id):other" }
                return "message:\(item.sender.id):\(text)"
            case .activity(let turn):
                return "activity:\(turn.events.map(\.memberID).compactMap { $0 }.joined(separator: ","))"
            }
        }
        #expect(presentation == [
            "message:\(UserIdentity.stableID):@everyone report in",
            "message:finance:Finance final",
            "message:research:Research final",
        ])
    }

    @Test func legacyBotModeTranscriptKeepsRepliesWithoutPersistedActivityCards() throws {
        let profiles: [AgentProfile] = [.financeFixture, .researchFixture]
        let directory = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let room = try BotModeRoom(
            id: "legacy-bot-order",
            members: [
                BotModeMember(profileID: "finance", handle: "finley", sessionID: "finance-session"),
                BotModeMember(profileID: "research", handle: "research", sessionID: "research-session"),
            ],
            visibleEvents: [
                .botModeStarted(id: "legacy-start"),
                .human(text: "@everyone report", id: "legacy-turn"),
                .agent(memberID: "finance", text: "Finance final", id: "legacy-finance-final"),
                .agent(memberID: "research", text: "Research final", id: "legacy-research-final"),
            ]
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        let activity = [
            ChatActivityEvent(
                eventID: "legacy-finance-work",
                sessionID: room.id,
                turnID: "legacy-turn",
                kind: .botHandoff,
                lifecycle: .succeeded,
                title: "Finley joined the turn",
                summary: "Finley responded",
                detail: nil,
                occurredAt: 100,
                botRunID: "legacy-run",
                memberID: "finance",
                sourceOrder: 1
            ),
            ChatActivityEvent(
                eventID: "legacy-research-work",
                sessionID: room.id,
                turnID: "legacy-turn",
                kind: .botHandoff,
                lifecycle: .succeeded,
                title: "Research joined the turn",
                summary: "Research responded",
                detail: nil,
                occurredAt: 101,
                botRunID: "legacy-run",
                memberID: "research",
                sourceOrder: 2
            ),
        ]
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialActivityEvents: activity,
            botModeRoomStore: rooms,
            agentDirectory: directory,
            botModeRoomID: room.id
        )

        let presentation = model.transcriptEntries.map { entry in
            switch entry {
            case .message(let item):
                guard case .message(let text) = item.content else { return "message:other" }
                return "message:\(item.sender.id):\(text)"
            case .activity(let turn):
                return "activity:\(turn.events.map(\.memberID).compactMap { $0 }.joined(separator: ","))"
            }
        }
        #expect(presentation == [
            "message:\(UserIdentity.stableID):@everyone report",
            "message:finance:Finance final",
            "message:research:Research final",
        ])
        #expect(model.activityLedger.allEvents == activity)
    }

    @Test func existingChatModelReprojectsWhenItsRoomStoreChangesExternally() throws {
        let profiles: [AgentProfile] = [.financeFixture, .researchFixture]
        let directory = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        var room = try BotModeRoom(
            id: "external-room-update",
            members: [
                BotModeMember(profileID: "finance", handle: "finley", sessionID: "finance-session"),
                BotModeMember(profileID: "research", handle: "research", sessionID: "research-session"),
            ],
            visibleEvents: [
                .botModeStarted(id: "external-start"),
                .human(text: "@everyone report", id: "external-turn", sourceOrder: 1),
            ]
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            botModeRoomStore: rooms,
            agentDirectory: directory,
            botModeRoomID: room.id
        )

        room.appendShared(.agent(
            memberID: "research",
            text: "Research final",
            sourceOrder: 2
        ))
        rooms.replace(room: room)

        #expect(model.transcriptEntries.compactMap { entry -> String? in
            guard case .message(let item) = entry, case .message(let text) = item.content else {
                return nil
            }
            return text
        } == ["@everyone report", "Research final"])
    }

    @Test func existingLegacyBotModelKeepsExternalActivityOutOfVisibleReplies() throws {
        let room = try BotModeRoom(
            id: "external-legacy-update",
            members: [BotModeMember(
                profileID: "finance",
                handle: "finley",
                sessionID: "finance-session"
            )],
            visibleEvents: [
                .botModeStarted(id: "legacy-external-start"),
                .human(text: "Report", id: "legacy-external-turn"),
                .agent(memberID: "finance", text: "Finance final", id: "legacy-external-final"),
            ]
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        let activity = ChatActivityEvent(
            eventID: "legacy-external-work",
            sessionID: room.id,
            turnID: "legacy-external-turn",
            kind: .botHandoff,
            lifecycle: .succeeded,
            title: "Finley joined",
            summary: "Done",
            detail: nil,
            occurredAt: 1,
            botRunID: "legacy-external-run",
            memberID: "finance",
            sourceOrder: 1
        )
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialActivityEvents: [activity],
            botModeRoomStore: rooms,
            botModeRoomID: room.id
        )

        #expect(model.transcriptEntries.map { entry in
            switch entry {
            case .message(let item): return "message:\(item.id)"
            case .activity: return "activity"
            }
        } == ["message:legacy-external-turn", "message:legacy-external-final"])
        #expect(model.activityLedger.allEvents == [activity])
    }

    @Test func roomObserversClearAtAccountBoundaryAndPruneDeadChatModelsOnRouteChurn() throws {
        let room = BotModeRoom.fixture(id: "observer-lifecycle", memberIDs: ["finance"])
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        weak var releasedModel: ChatModel?

        do {
            let model = ChatModel(
                conversationID: room.id,
                client: ConversationFixtureClient(canonicalAgentID: "finance"),
                agentID: "finance",
                initialItems: [],
                botModeRoomStore: rooms,
                botModeRoomID: room.id
            )
            releasedModel = model
            #expect(rooms.roomObserverCount == 1)
        }
        #expect(releasedModel == nil)

        let replacement = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            botModeRoomStore: rooms,
            botModeRoomID: room.id
        )
        #expect(replacement.isBotMode)
        #expect(rooms.roomObserverCount == 1)

        rooms.resetForAccountBoundary()
        #expect(rooms.roomObserverCount == 0)
    }

    @Test func failedPartialRetryPreservesRoomRetryStateWithoutDuplicateHuman() async throws {
        let persistence = ChatBotModeTestPersistence(failCompareAt: 5)
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.failure("finance unavailable"), .reply("finance recovered")],
            "research": [.reply("research reply")]
        ])
        let model = ChatModel.testBotFixture(
            draft: "@everyone first",
            roomMemberIDs: ["finance", "research"],
            client: client,
            persistence: persistence
        )

        await model.send()
        await model.retry()

        #expect(model.canRetry)
        #expect(model.draft.isEmpty)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == BotModeEvent.Kind.human }.count == 1)
    }

    @Test func postAcceptancePersistenceFailureNeverReplaysHumanEvent() async throws {
        let persistence = ChatBotModeTestPersistence(failCompareAt: 2)
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.reply("finance reply"), .reply("finance retry")]
        ])
        let model = ChatModel.testBotFixture(
            draft: "@finley first",
            roomMemberIDs: ["finance"],
            client: client,
            persistence: persistence
        )

        await model.send()
        await model.retry()

        #expect(model.draft.isEmpty)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == BotModeEvent.Kind.human }.count == 1)
        #expect(client.requests.count == 2)
    }

    @Test func unsentRosterRemovalRestoresCanonicalDirectSession() throws {
        let room = BotModeRoom.fixture(id: "bot-roster", memberIDs: ["finance", "research"])
        let session = SessionRecord(
            id: "bot-roster",
            kind: .botMode,
            agentIDs: room.memberIDs,
            title: "Shared",
            botModeRoomID: room.id
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [session]), records: [session])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room])
        let model = ChatModel(
            conversationID: session.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            sourceSession: session,
            botModeRoomStore: rooms,
            agentDirectory: agents,
            botModeRoomID: room.id,
            onBotModeChange: { roomID, memberIDs in
                catalog.convertToBotMode(sessionID: session.id, memberIDs: memberIDs, roomID: roomID)
            },
            onBotModeCollapse: { roomID, remainingAgentID, privateHistory in
                catalog.convertToDirect(
                    sessionID: session.id,
                    roomID: roomID,
                    remainingAgentID: remainingAgentID,
                    privateHistory: privateHistory
                )
            }
        )

        try model.removeMember(agentID: "research")

        #expect(rooms.room(id: room.id) == nil)
        #expect(catalog.session(id: session.id)?.agentIDs == ["finance"])
        #expect(catalog.session(id: session.id)?.kind == .direct)
        #expect(catalog.session(id: session.id)?.botModeRoomID == nil)
    }

    @Test func conversionUsesCurrentDirectItemsAndUpdatesCanonicalCatalog() async throws {
        let direct = SessionRecord(
            id: "direct-convert",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            draft: "saved draft"
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [direct]), records: [direct])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let rooms = BotModeRoomStore(client: BotModeFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog, agents: agents, botModeRooms: rooms)

        #expect(featureStore.prepare(.chat(conversationID: direct.id)))
        guard case .chat(let model)? = featureStore.preparedModel(for: .chat(conversationID: direct.id)) else {
            Issue.record("chat model was not prepared")
            return
        }
        model.draft = "private current turn"
        await model.send()
        let currentItems = model.items
        model.draft = "Please ask @res"
        try model.selectMention(agentID: "research", replacing: "@res")

        let converted = try #require(catalog.session(id: direct.id))
        #expect(converted.kind == .botMode)
        #expect(converted.agentIDs == ["finance", "research"])
        #expect(converted.botModeRoomID == "bot-\(direct.id)")
        #expect(converted.draft == "Please ask @research ")
        #expect(converted.items.isEmpty)
        #expect(converted.botModePrivateHistory == currentItems)

        featureStore.retainModels(ownedBy: [])
        #expect(featureStore.prepare(.chat(conversationID: direct.id)))
        guard case .chat(let reopened)? = featureStore.preparedModel(for: .chat(conversationID: direct.id)) else {
            Issue.record("reopened chat model was not prepared")
            return
        }
        #expect(reopened.isBotMode)
        #expect(reopened.items == currentItems)
        #expect(reopened.draft == "Please ask @research ")
    }

    @Test func mentionConversionProjectsOnlySharedRoomEventsAndObservesLaterUpdates() throws {
        let privateItem = TimelineItem(
            id: "mention-private",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Private mention history"),
            metadata: .init(sourceOrder: 1)
        )
        let direct = SessionRecord(
            id: "mention-conversion-projection",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [privateItem],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(records: [direct]),
            records: [direct]
        )
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient())
        let featureStore = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agents: agents,
            botModeRooms: rooms
        )
        let route = AppRoute.chat(conversationID: direct.id)
        #expect(featureStore.prepare(route))
        guard case .chat(let model) = featureStore.preparedModel(for: route) else {
            Issue.record("Expected direct chat model")
            return
        }
        model.draft = "Ask @res"

        try model.selectMention(agentID: "research", replacing: "@res")

        #expect(model.items.map(\.id) == [privateItem.id])
        #expect(model.transcriptEntries.isEmpty)
        var room = try #require(model.botModeRoom)
        room.appendShared(.agent(memberID: "research", text: "Shared mention reply"))
        rooms.replace(room: room)
        #expect(model.transcriptEntries.compactMap { entry -> String? in
            guard case .message(let item) = entry, case .message(let text) = item.content else { return nil }
            return text
        } == ["Shared mention reply"])
    }

    @Test func peopleAndChatConversionProjectsOnlySharedRoomEventsAndObservesLaterUpdates() throws {
        let privateItem = TimelineItem(
            id: "people-private",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Private people history"),
            metadata: .init(sourceOrder: 1)
        )
        let direct = SessionRecord(
            id: "people-conversion-projection",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [privateItem],
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(records: [direct]),
            records: [direct]
        )
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let rooms = BotModeRoomStore(client: BotModeFixtureClient())
        let featureStore = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agents: agents,
            botModeRooms: rooms
        )
        let route = AppRoute.chat(conversationID: direct.id)
        #expect(featureStore.prepare(route))
        guard case .chat(let model) = featureStore.preparedModel(for: route) else {
            Issue.record("Expected direct chat model")
            return
        }

        try model.addMember(agentID: "research")

        #expect(model.items.map(\.id) == [privateItem.id])
        #expect(model.transcriptEntries.isEmpty)
        var room = try #require(model.botModeRoom)
        room.appendShared(.agent(memberID: "research", text: "Shared people reply"))
        rooms.replace(room: room)
        #expect(model.transcriptEntries.compactMap { entry -> String? in
            guard case .message(let item) = entry, case .message(let text) = item.content else { return nil }
            return text
        } == ["Shared people reply"])
    }

    @Test func canonicalBotModeReopenDoesNotRenderPrivateEarlierDivider() throws {
        let canonicalItems = [
            TimelineItem(
                id: "shared-human",
                role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("Shared request"),
                metadata: .init()
            ),
            TimelineItem(
                id: "shared-reply",
                role: .assistant,
                sender: .agent(id: "research", snapshot: .init(name: "Research")),
                content: .message("Shared reply"),
                metadata: .init()
            )
        ]
        let session = SessionRecord(
            id: "canonical-bot",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Shared",
            items: canonicalItems,
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [session]), records: [session])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let rooms = BotModeRoomStore(client: BotModeFixtureClient())
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog, agents: agents, botModeRooms: rooms)

        #expect(featureStore.prepare(.chat(conversationID: session.id)))
        guard case .chat(let model)? = featureStore.preparedModel(for: .chat(conversationID: session.id)) else {
            Issue.record("canonical bot model was not prepared")
            return
        }
        #expect(model.items.isEmpty)
        #expect(model.timelineEvents.map(\.kind) == [.botModeStarted, .human, .agent])
        #expect(model.botModeTimelineItems.count == 2)
    }

    @Test func rootLoadFailureIsDeterministicAndRecoverable() {
        let persistence = ChatBotModeTestPersistence(loadError: BotModePersistenceError.writeFailed)
        let store = BotModeRoomStore(client: BotModeFixtureClient(), persistence: persistence)

        #expect(throws: BotModePersistenceError.writeFailed) { try store.load() }
        #expect(store.loadErrorMessage == "Group chats could not be loaded. Try again.")
    }

    @Test func botModeReconstructionNeverPromotesPrivateDirectHistoryToSharedContext() async throws {
        let privateItem = TimelineItem(
            id: "private-before-conversion",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Private direct answer"),
            metadata: .init()
        )
        let direct = SessionRecord(
            id: "relaunch-bot",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [privateItem],
            hasAcceptedMessage: true
        )
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        let catalogRepository = DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [direct])
        let catalog = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(records: [direct]),
            records: [direct],
            repository: catalogRepository
        )
        let roomRepository = DemoRepository<[BotModeRoom]>(directory: directory, name: "rooms", seed: [])
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), repository: roomRepository)
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog, agents: agents, botModeRooms: rooms)

        #expect(catalog.session(id: direct.id)?.kind == .direct)
        #expect(featureStore.prepare(.chat(conversationID: direct.id)))
        guard case .chat(let directModel)? = featureStore.preparedModel(for: .chat(conversationID: direct.id)) else {
            Issue.record("direct chat was not prepared")
            return
        }
        directModel.draft = "Please ask @res"
        try directModel.selectMention(agentID: "research", replacing: "@res")

        let reloadedCatalog = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(),
            repository: DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        )
        try await reloadedCatalog.load()
        let evictedRooms = BotModeRoomStore(client: BotModeFixtureClient())
        let relaunched = ShellFeatureStore(timing: .immediate, catalog: reloadedCatalog, agents: agents, botModeRooms: evictedRooms)

        #expect(relaunched.prepare(.chat(conversationID: direct.id)))
        guard case .chat(let model)? = relaunched.preparedModel(for: .chat(conversationID: direct.id)) else {
            Issue.record("reopened chat was not prepared")
            return
        }
        #expect(model.items == [privateItem.ordered(1)])
        #expect(model.timelineEvents.filter { $0.text == "Private direct answer" }.isEmpty)
        #expect(model.botModeRoom?.memberContexts["research"]?.messages.contains(where: { $0.text == "Private direct answer" }) == false)
    }

    @Test func postAcceptancePersistenceFailureSettlesRoomAndLeavesRetryableState() async throws {
        let persistence = ChatBotModeTestPersistence(failCompareAt: 2)
        let client = ChatBotModeRetryClient(resultsByMember: ["finance": [.reply("reply")]])
        let model = ChatModel.testBotFixture(draft: "@finley same", client: client, persistence: persistence)

        await model.send()

        #expect(model.botModeRoom?.isRunning == false)
        #expect(model.botModeRoom?.runOwner == nil)
        #expect(model.canRetry)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == .human }.count == 1)
    }

    @Test func memberFailurePersistenceThrowSettlesRoomWithoutReplayingHuman() async throws {
        let persistence = ChatBotModeTestPersistence(throwCompareAt: 2)
        let client = ChatBotModeRetryClient(resultsByMember: ["finance": [.failure("offline")]])
        let model = ChatModel.testBotFixture(draft: "@finley request", client: client, persistence: persistence)

        await model.send()

        #expect(model.botModeRoom?.isRunning == false)
        #expect(model.botModeRoom?.runOwner == nil)
        #expect(model.canRetry)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == .human }.count == 1)
    }

    @Test func finalSettlementPersistenceThrowSettlesRoomWithoutReplayingHuman() async throws {
        let persistence = ChatBotModeTestPersistence(throwCompareAt: 3)
        let client = ChatBotModeRetryClient(resultsByMember: ["finance": [.reply("reply")]])
        let model = ChatModel.testBotFixture(draft: "@finley request", client: client, persistence: persistence)

        await model.send()

        #expect(model.botModeRoom?.isRunning == false)
        #expect(model.botModeRoom?.runOwner == nil)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == .human }.count == 1)
    }

    @Test func retryPersistenceThrowPreservesSettledRecoveryAndRetryState() async throws {
        let persistence = ChatBotModeTestPersistence(throwCompareAt: 5)
        let client = ChatBotModeRetryClient(resultsByMember: [
            "finance": [.failure("offline"), .reply("recovered")]
        ])
        let model = ChatModel.testBotFixture(draft: "@finley request", client: client, persistence: persistence)

        await model.send()
        await model.retry()

        #expect(model.botModeRoom?.isRunning == false)
        #expect(model.botModeRoom?.runOwner == nil)
        #expect(model.canRetry)
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == .human }.count == 1)
    }

    @Test func failedAcceptanceDoesNotMatchAnEarlierEqualHumanEvent() async throws {
        var room = BotModeRoom.fixture(id: "bot-duplicate", memberIDs: ["finance"])
        room.appendShared(.human(text: "same message", id: "old-human"))
        let persistence = ChatBotModeTestPersistence(compareSaveResults: [nil])
        persistence.seed([room])
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], persistence: persistence)
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "@finance same message",
            botModeRoomStore: rooms,
            botModeRoomID: room.id
        )

        await model.send()

        #expect(model.draft == "@finance same message")
        #expect(model.canRetry)
    }

    @Test func unknownMentionIsRejectedWithoutBroadcastingToEveryone() async throws {
        let room = BotModeRoom.fixture(id: "bot-unknown-mention", memberIDs: ["finance"])
        let persistence = ChatBotModeTestPersistence()
        persistence.seed([room])
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room], persistence: persistence)
        let model = ChatModel(
            conversationID: room.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "@finley same message",
            botModeRoomStore: rooms,
            botModeRoomID: room.id
        )

        await model.send()

        #expect(model.draft == "@finley same message")
        #expect(model.canRetry == false)
        #expect(model.failureMessage == "No agent named @finley in this chat. Edit the mention and try again.")
        #expect(model.botModeRoom?.visibleEvents.filter { $0.kind == .human }.count == 0)
    }

    @Test func catalogCallbackFailureRollsBackRoomAndConversionMetadata() throws {
        let direct = SessionRecord(id: "callback-failure", kind: .direct, agentIDs: ["finance"], title: "Finance")
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [direct]), records: [direct])
        let persistence = ChatBotModeTestPersistence()
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), persistence: persistence)
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let model = ChatModel(
            conversationID: direct.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            initialDraft: "Ask @res",
            sourceSession: direct,
            botModeRoomStore: rooms,
            agentDirectory: agents,
            onBotModeChange: { _, _ in false }
        )

        #expect(throws: BotModeRoomError.persistenceConflict) {
            try model.selectMention(agentID: "research", replacing: "@res")
        }
        #expect(model.draft == "Ask @res")
        #expect(model.botModeRoomID == nil)
        #expect(rooms.room(id: "bot-\(direct.id)") == nil)
        #expect(catalog.session(id: direct.id)?.kind == .direct)
    }

    @Test func catalogCallbackFailureRollsBackRosterMutationAndHistory() throws {
        let room = BotModeRoom.fixture(id: "callback-roster", memberIDs: ["finance", "research", "travel"])
        var roomWithHistory = room
        roomWithHistory.appendShared(.human(text: "Preserve this shared history", id: "shared-history"))
        let session = SessionRecord(
            id: room.id,
            kind: .botMode,
            agentIDs: room.memberIDs,
            title: "Shared",
            items: [],
            botModeRoomID: room.id,
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [session]), records: [session])
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), rooms: [roomWithHistory])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let model = ChatModel(
            conversationID: session.id,
            client: ConversationFixtureClient(canonicalAgentID: "finance"),
            agentID: "finance",
            initialItems: [],
            sourceSession: session,
            botModeRoomStore: rooms,
            agentDirectory: agents,
            botModeRoomID: room.id,
            onBotModeChange: { _, _ in false }
        )

        #expect(throws: BotModeRoomError.persistenceConflict) {
            try model.removeMember(agentID: "research")
        }
        #expect(rooms.room(id: room.id)?.memberIDs == ["finance", "research", "travel"])
        #expect(rooms.room(id: room.id)?.visibleEvents.last?.id == "shared-history")
        #expect(catalog.session(id: session.id)?.agentIDs == ["finance", "research", "travel"])
    }

    @Test func failedBotRoomPreparationDoesNotOpenUsableChatRoute() {
        let session = SessionRecord(
            id: "invalid-bot-route",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Shared",
            botModeRoomID: "bot-invalid-bot-route"
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [session]), records: [session])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let persistence = ChatBotModeTestPersistence(rejectInsert: true)
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), persistence: persistence)
        let featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog, agents: agents, botModeRooms: rooms)

        #expect(featureStore.prepare(.chat(conversationID: session.id)) == false)
        #expect(featureStore.preparedModel(for: .chat(conversationID: session.id)) == nil)
    }

    @Test func readdingRetiredHandleCannotCollideWithAnActiveMember() throws {
        let first = AgentProfile.sameNameFixture(id: "same-one")
        let second = AgentProfile.sameNameFixture(id: "same-two")
        let replacement = AgentProfile.sameNameFixture(id: "same-replacement")
        let members = [
            BotModeMember(profileID: first.id, handle: "same-name", sessionID: "one"),
            BotModeMember(profileID: second.id, handle: "same-name-2", sessionID: "two")
        ]
        var room = try BotModeRoom(id: "handles", members: members)
        #expect(try room.remove(memberID: first.id) == .removed)
        #expect(try room.add(profile: replacement) == .added)
        #expect(try room.add(profile: first) == .added)
        #expect(Set(room.members.map { $0.handle.lowercased() }).count == room.members.count)
    }

    @Test func duplicateHandlesAreRejectedByMentionParserWithoutDictionaryTrap() throws {
        let room = try BotModeRoom(
            id: "duplicate-handles",
            members: [
                BotModeMember(profileID: "one", handle: "same", sessionID: "one"),
                BotModeMember(profileID: "two", handle: "same", sessionID: "two")
            ]
        )

        #expect(throws: MentionError.self) {
            try MentionParser.mentionTargets(in: "@same", room: room)
        }
    }

    @Test func suggestionPresentationIncludesExactCollisionSafeHandle() {
        let suggestion = MentionSuggestion.member(profile: .sameNameFixture(id: "same-two"), handle: "same-name-2")

        #expect(suggestion.displayLabel == "Same Name @same-name-2")
    }

    @Test func invalidBotAssistantSenderIsExcludedFromSharedProjection() throws {
        let invalid = TimelineItem(
            id: "invalid-agent",
            role: .assistant,
            sender: .agent(id: "outside", snapshot: .init(name: "Outside")),
            content: .message("Untrusted reply"),
            metadata: .init()
        )
        let session = SessionRecord(
            id: "invalid-sender",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Shared",
            items: [invalid],
            botModeRoomID: "bot-invalid-sender",
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient(records: [session]), records: [session])
        let profiles = [AgentProfile.financeFixture, AgentProfile.researchFixture]
        let agents = AgentDirectoryStore(client: ChatBotAgentDirectoryFixtureClient(profiles: profiles), profiles: profiles)
        let featureStore = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agents: agents,
            botModeRooms: BotModeRoomStore(client: BotModeFixtureClient())
        )

        #expect(featureStore.prepare(.chat(conversationID: session.id)) == true)
        guard case .chat(let model)? = featureStore.preparedModel(for: .chat(conversationID: session.id)) else { return }
        #expect(model.timelineEvents.contains(where: { $0.text == "Untrusted reply" }) == false)
    }

    @Test func roomRehydrationQuarantinesAssistantEventsOutsideRoster() throws {
        let room = try BotModeRoom(
            id: "invalid-room-event",
            members: [BotModeMember(profileID: "finance", handle: "finley", sessionID: "finance")],
            visibleEvents: [
                .botModeStarted(id: "started"),
                .agent(memberID: "outside", text: "Should not render", id: "invalid")
            ]
        )

        #expect(room.visibleEvents.contains(where: { $0.id == "invalid" }) == false)
    }

    @Test func botModePreviewNeverUsesPrivateDirectFallback() {
        let privateItem = TimelineItem(
            id: "private-preview",
            role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
            content: .message("Private answer must stay private"),
            metadata: .init()
        )
        let session = SessionRecord(
            id: "preview",
            kind: .botMode,
            agentIDs: ["finance", "research"],
            title: "Shared",
            botModePrivateHistory: [privateItem]
        )

        #expect(session.summary.preview != "Private answer must stay private")
    }

    @Test func convertedBotModeCatalogMetadataSurvivesCatalogReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        let direct = SessionRecord(
            id: "durable-conversion",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            items: [TimelineItem(
                id: "private-durable",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finance")),
                content: .message("Private durable context"),
                metadata: .init()
            )]
        )
        let repository = DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [direct])
        let catalog = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(records: [direct]),
            records: [direct],
            repository: repository
        )

        #expect(catalog.convertToBotMode(sessionID: direct.id, memberIDs: ["finance", "research"], roomID: "bot-\(direct.id)"))

        let reloaded = SessionCatalogStore(
            client: ChatBotSessionCatalogFixtureClient(),
            repository: DemoRepository<[SessionRecord]>(directory: directory, name: "sessions", seed: [])
        )
        try await reloaded.load()

        let converted = try #require(reloaded.session(id: direct.id))
        #expect(converted.kind == .botMode)
        #expect(converted.botModeRoomID == "bot-\(direct.id)")
        #expect(converted.botModePrivateHistory.count == 1)
        #expect(converted.items.isEmpty)
    }

    @Test func mentionReplacementNormalizesWhitespaceBeforePunctuation() throws {
        let model = ChatModel.testBotFixture(draft: "Ask @res ,")
        model.setMentionCursor(offset: 8)

        try model.selectMention(agentID: "research", replacing: "@res")

        #expect(model.draft == "Ask @research, ")
    }

    @Test func rosterMutationIsRejectedWhileRoomRunIsActive() async throws {
        let client = ChatBotModeDeferredClient()
        let model = ChatModel.testBotFixture(draft: "@finley run", client: client)
        let sendTask = Task { await model.send() }
        await client.waitForRequest()

        #expect(throws: BotModeRoomError.runAlreadyActive) {
            try model.removeMember(agentID: "finance")
        }

        client.resume(.reply("done"))
        await sendTask.value
    }

    @Test func legacyDraftSelectionBridgeConvertsActualUTF16CaretToCharacterOffset() {
        #expect(DraftCaretSelection.characterOffset(in: "A😀B", selectedRange: NSRange(location: 3, length: 0)) == 2)
    }

    @Test func startupDefersBotModePersistenceUntilExplicitUse() throws {
        let persistence = ChatBotModeTestPersistence(loadError: BotModePersistenceError.writeFailed)
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            persistence: persistence
        )

        try BotModeRoomLoadingPolicy.load(store, for: .startup)

        #expect(persistence.loadCount == 0)
        #expect(store.loadErrorMessage == nil)
    }

    @Test func explicitBotModeUseSurfacesPersistenceFailure() {
        let persistence = ChatBotModeTestPersistence(loadError: BotModePersistenceError.writeFailed)
        let store = BotModeRoomStore(
            client: BotModeFixtureClient(),
            persistence: persistence
        )

        #expect(throws: BotModePersistenceError.writeFailed) {
            try BotModeRoomLoadingPolicy.load(store, for: .explicitUse)
        }
        #expect(persistence.loadCount == 1)
        #expect(store.loadErrorMessage == "Group chats could not be loaded. Try again.")
    }

    @Test func rootLoadBannerIsVisibleWhenRoomLoadFails() throws {
        let banner = try #require(BotModeLoadBannerState(message: "Group chats could not be loaded. Try again."))

        #expect(banner.isVisible)
        #expect(banner.message == "Group chats could not be loaded. Try again.")
        #expect(banner.actionLabel == "Try again")
        #expect(BotModeLoadBannerState(message: nil) == nil)
    }

    @Test func clearingMemberFailureReportsPersistenceRecoveryError() throws {
        let persistence = ChatBotModeTestPersistence(failCompareAt: 1)
        let model = ChatModel.testBotFixture(persistence: persistence)
        var room = try #require(model.botModeRoom)
        room.replaceFailures(with: [BotModeMemberFailure(memberID: "finance", message: "offline")])
        persistence.seed([room])

        #expect(throws: BotModeRoomError.persistenceConflict) {
            try model.clearMemberFailure(memberID: "finance")
        }
        #expect(model.failureMessage == "Failure status could not be cleared. Try again.")
    }

    @Test func selectingCurrentDirectAgentOnlyReplacesMention() throws {
        let profile = AgentProfile.financeFixture
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: [profile]),
            profiles: [profile]
        )
        let model = ChatModel(
            conversationID: "direct-finance",
            client: ConversationFixtureClient(canonicalAgentID: profile.id),
            agentID: profile.id,
            initialItems: [],
            initialDraft: "Please ask @fin",
            agentDirectory: agents
        )

        try model.selectMention(agentID: profile.id, replacing: "@fin")

        #expect(model.draft == "Please ask @finley ")
        #expect(!model.isBotMode)
    }
}

@MainActor
private final class ChatDestinationHarness {
    let appState = AppState()
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let coordinator: NewChatCoordinator
    let headerActions: ChatHeaderActions
    private(set) var openedSession: SessionRecord?

    init(selectedAgentID: String?) async throws {
        let defaults = UserDefaults(suiteName: "ChatBotModeIntegrationTests.\(UUID().uuidString)")!
        let agents = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture, .researchFixture]),
            defaults: defaults
        )
        try await agents.load()
        if let selectedAgentID { agents.select(selectedAgentID) }

        catalog = SessionCatalogStore(client: ChatBotSessionCatalogFixtureClient())
        featureStore = ShellFeatureStore(timing: .immediate, catalog: catalog, agents: agents)
        coordinator = NewChatCoordinator(
            appState: appState,
            agents: agents,
            catalog: catalog,
            prepare: { [featureStore] route in featureStore.prepare(route) }
        )
        headerActions = ChatHeaderActions(newChat: { [coordinator] in
            Task { _ = try? await coordinator.start(explicitAgentID: nil) }
        })
    }

    func tapNewChat() async {
        headerActions.triggerNewChat()
        for _ in 0..<10 { await Task.yield() }
        openedSession = catalog.records.first(where: { $0.agentIDs == ["research"] })
    }
}

private extension AgentProfile {
    static let researchFixture = AgentProfile(
        id: "research",
        name: "Research",
        role: "Research agent",
        summary: "Research and synthesis.",
        instructions: "Help with research.",
        avatarFileName: nil,
        isDefault: false
    )

    static func sameNameFixture(id: String) -> AgentProfile {
        AgentProfile(
            id: id,
            name: "Same Name",
            role: "Same-name agent",
            summary: "Collision fixture.",
            instructions: "Help with collision testing.",
            avatarFileName: nil,
            isDefault: false
        )
    }
}

@MainActor
private final class ChatBotAgentDirectoryFixtureClient: AgentDirectoryClient {
    let profiles: [AgentProfile]

    init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    func list() async throws -> [AgentProfile] { profiles }
    func create(_ draft: AgentDraft) async throws -> AgentProfile { fatalError("unused") }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile { fatalError("unused") }
}

@MainActor
private final class ChatBotSessionCatalogFixtureClient: SessionCatalogClient {
    private var nextID = 1
    private var records: [SessionRecord]

    init(records: [SessionRecord] = []) {
        self.records = records
    }

    func list() async throws -> [SessionRecord] { records }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        defer { nextID += 1 }
        let record = SessionRecord(
            id: "session-\(nextID)",
            kind: kind,
            agentIDs: agentIDs,
            title: "New chat"
        )
        records.append(record)
        return record
    }
}

@MainActor
private extension ChatModel {
    static func testBotFixture(
        draft: String = "",
        profiles: [AgentProfile] = [.financeFixture, .researchFixture],
        roomMemberIDs: [String] = ["finance"],
        sharedEvents: [BotModeEvent] = [],
        client: any BotModeMemberTurnClient = BotModeFixtureClient(),
        persistence: ChatBotModeTestPersistence? = nil,
        executionEnabled: Bool = true,
        conversationClient: (any ConversationClient)? = nil
    ) -> ChatModel {
        let directory = AgentDirectoryStore(
            client: ChatBotAgentDirectoryFixtureClient(profiles: profiles),
            profiles: profiles
        )
        let handles = AgentHandle.directory(for: profiles)
        let members = roomMemberIDs.map { id in
            BotModeMember(
                profileID: id,
                handle: handles.first(where: { $0.profileID == id })?.handle ?? AgentHandle.normalized(id),
                sessionID: "hidden-\(id)"
            )
        }
        let room = try! BotModeRoom(
            id: "bot-fixture",
            members: members,
            visibleEvents: [.botModeStarted(id: "bot-mode-started-bot-fixture")] + sharedEvents
        )
        persistence?.seed([room])
        let rooms = BotModeRoomStore(
            client: client,
            rooms: [room],
            persistence: persistence,
            executionEnabled: executionEnabled
        )
        return ChatModel(
            conversationID: "bot-fixture",
            client: conversationClient ?? ConversationFixtureClient(canonicalAgentID: roomMemberIDs[0]),
            agentID: roomMemberIDs[0],
            initialItems: [],
            initialDraft: draft,
            sourceSession: SessionRecord(
                id: "bot-fixture",
                kind: .direct,
                agentIDs: [roomMemberIDs[0]],
                title: "Direct"
            ),
            botModeRoomStore: rooms,
            agentDirectory: directory,
            botModeRoomID: room.id
        )
    }
}

@MainActor
private final class ChatBotModeRetryClient: BotModeMemberTurnClient {
    enum Result {
        case reply(String)
        case failure(String)
    }

    private var resultsByMember: [String: [Result]]
    private(set) var requests: [BotModeMemberTurnRequest] = []

    init(resultsByMember: [String: [Result]]) {
        self.resultsByMember = resultsByMember
    }

    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        requests.append(request)
        let result = resultsByMember[request.memberID]?.isEmpty == false
            ? resultsByMember[request.memberID]!.removeFirst()
            : .reply("fallback")
        switch result {
        case .reply(let text): return .reply(text)
        case .failure(let message): throw NSError(domain: "ChatBotModeRetryClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

@MainActor
private final class ChatBotModeDeferredClient: BotModeMemberTurnClient {
    private var continuation: CheckedContinuation<BotModeMemberTurnResult, Never>?
    private(set) var requests: [BotModeMemberTurnRequest] = []

    func performMemberTurn(_ request: BotModeMemberTurnRequest) async throws -> BotModeMemberTurnResult {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForRequest() async {
        while requests.isEmpty {
            await Task.yield()
        }
    }

    func resume(_ result: BotModeMemberTurnResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class ChatBotModeTestPersistence: BotModeRoomPersistence {
    private(set) var rooms: [BotModeRoom] = []
    private var compareSaveResults: [BotModeRoom?]
    private let rejectInsert: Bool
    private let loadError: Error?
    private let failCompareAt: Int?
    private let throwCompareAt: Int?
    private var compareCount = 0
    private(set) var loadCount = 0

    init(
        compareSaveResults: [BotModeRoom?] = [],
        rejectInsert: Bool = false,
        loadError: Error? = nil,
        failCompareAt: Int? = nil,
        throwCompareAt: Int? = nil
    ) {
        self.compareSaveResults = compareSaveResults
        self.rejectInsert = rejectInsert
        self.loadError = loadError
        self.failCompareAt = failCompareAt
        self.throwCompareAt = throwCompareAt
    }

    func seed(_ rooms: [BotModeRoom]) {
        self.rooms = rooms
    }

    func load(recoveringRuns: Bool) throws -> [BotModeRoom] {
        loadCount += 1
        if let loadError { throw loadError }
        return rooms
    }

    func insert(_ room: BotModeRoom) throws -> BotModeRoom? {
        if rejectInsert { return nil }
        guard !rooms.contains(where: { $0.id == room.id }) else { return nil }
        var saved = room
        saved.markPersisted(revision: 0)
        rooms.append(saved)
        return saved
    }

    func compareAndSave(
        _ room: BotModeRoom,
        expectedRevision: Int,
        expectedOwner: BotModeRunOwnerExpectation
    ) throws -> BotModeRoom? {
        compareCount += 1
        if compareCount == throwCompareAt { throw BotModePersistenceError.writeFailed }
        if compareCount == failCompareAt { return nil }
        if !compareSaveResults.isEmpty {
            guard let result = compareSaveResults.removeFirst() else { return nil }
            var saved = result
            saved.markPersisted(revision: expectedRevision + 1)
            rooms = rooms.filter { $0.id != saved.id } + [saved]
            return saved
        }
        guard let index = rooms.firstIndex(where: { $0.id == room.id }),
              rooms[index].persistenceRevision == expectedRevision else { return nil }
        var saved = room
        saved.markPersisted(revision: expectedRevision + 1)
        rooms[index] = saved
        return saved
    }

    func remove(roomID: String) throws -> Bool {
        rooms.removeAll { $0.id == roomID }
        return true
    }
}
