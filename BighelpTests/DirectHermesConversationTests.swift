import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DirectHermesConversationTests {
    @Test func unavailableQuickActionPreservesDraftAndTimeline() async {
        let model = ChatModel(conversationID: "unprepared", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        model.draft = "Keep this draft"
        await model.perform(.weatherAndTasks)
        #expect(model.items.isEmpty)
        #expect(model.transcriptEntries.isEmpty)
        #expect(model.draft == "Keep this draft")
        #expect(model.failureMessage == nil)
        #expect(!model.isSending)
        #expect(!model.canRetry)
    }

    @Test func retiredOwnerCannotPerformQuickAction() async {
        let model = ChatModel(conversationID: "retired", client: ConversationFixtureClient(), initialItems: [])
        model.invalidateReferenceOwnership()
        await model.perform(.weatherAndTasks)
        #expect(model.items.isEmpty)
        #expect(!model.isSending)
    }

    @Test(arguments: [false, true])
    func unreadyRetryPreservesRequestUntilNativeRecovery(unknownOutcome: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            // Ordinary validation may offer Retry; stale-runtime 4001 is now
            // covered separately as a retained, non-retryable refusal.
            case "prompt.submit": throw DirectHermesError.rpcRejected(code: unknownOutcome ? 4018 : 4004)
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"),
                    "running": .boolean(false), "messages": .array([])])
            case "subagent.list": return .object(["subagents": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        await model.perform(.weatherAndTasks)
        #expect(model.canRetry == !unknownOutcome)
        #expect(client.journal.unresolved.count == (unknownOutcome ? 1 : 0))
        let originalJournalIDs = client.journal.unresolved.map(\.id)
        let failure = try #require(model.failureMessage)
        client.suspend()
        #expect(!model.canRetry)
        await model.retry()
        #expect(model.failureMessage == failure)
        client.rebind(rpc)
        #expect(!client.isReadyForSubmission)
        #expect(!model.canRetry)
        await model.retry()
        #expect(model.failureMessage == failure)
        try await client.recover(epoch: "epoch")
        #expect(client.isReadyForSubmission)
        #expect(model.canRetry == !unknownOutcome)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
        #expect(client.journal.unresolved.map(\.id) == originalJournalIDs)
    }

    @Test(arguments: [SlashCommandSource.skill, .plugin, .user, .core])
    func catalogCommandUsesItsNativeRouteAndCompletesImmediately(source: SlashCommandSource) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let name = source == .core ? "help" : "bedtime"
        rpc.handler = { method, _ in
            if method == "slash.exec", source != .core { throw DirectHermesError.rpcRejected(code: 4018) }
            return .object(["type": .string("plugin"), "output": .string("Fixture command completed")])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.selectSlashCommand(.init(name: name, description: "Fixture command", category: "Commands",
            argsHint: "", aliases: [], argumentMode: .text, source: source, requiresArguments: false))
        model.draft = "/\(name)"
        await model.send()
        let mutations = rpc.requests.filter { $0.method != "session.control.read" }
        #expect(mutations.map(\.method) == [source == .core ? "slash.exec" : "command.dispatch"])
        if source != .core {
            #expect(mutations.first?.params["name"] == .string(name))
            #expect(mutations.first?.params["arg"] == .string(""))
        }
        #expect(model.items.contains { $0.content == .message("Fixture command completed") })
        #expect(model.failureMessage == nil)
        #expect(!model.isSending)
        #expect(client.journal.unresolved.isEmpty)
        #expect(!client.needsRecovery)
    }

    /// Text that arrives already typed (a Shortcut, or a command typed out
    /// without the menu) has no catalog selection, so it goes to slash.exec.
    /// Hermes refuses skills there with 4018 and names command.dispatch; its own
    /// clients retry there, and so does bighelp. A second refusal is final.
    @Test(arguments: [false, true])
    func typedSkillCommandFallsBackToCommandDispatch(dispatchRefuses: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, params in
            switch method {
            case "slash.exec":
                #expect(params["command"] == .string("/briefing  today's news"))
                throw DirectHermesError.rpcRejected(code: 4018)
            case "command.dispatch":
                #expect(params["name"] == .string("briefing"))
                #expect(params["arg"] == .string("today's news"))
                if dispatchRefuses { throw DirectHermesError.rpcRejected(code: 4018) }
                return .object(["type": .string("skill"), "message": .string("<skill>Briefing</skill> today's news")])
            case "prompt.submit":
                return .object(["status": .string("queued")])
            default:
                return .object([:])
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.draft = "/briefing  today's news"
        await model.send()
        let methods = rpc.requests.map(\.method).filter { $0 != "session.control.read" }
        if dispatchRefuses {
            #expect(methods == ["slash.exec", "command.dispatch"])
            #expect(model.failureMessage == "Hermes did not run this command. Your text is ready to edit.")
            #expect(model.draft == "/briefing  today's news")
        } else {
            #expect(methods == ["slash.exec", "command.dispatch", "prompt.submit"])
            #expect(rpc.requests.last?.params["text"] == .string("<skill>Briefing</skill> today's news"))
            #expect(model.failureMessage == nil)
        }
        #expect(!model.isSending)
        #expect(client.journal.unresolved.isEmpty)
        #expect(!client.needsRecovery)
    }

    @Test(arguments: ["expanded", "rejected", "unknown", "expanded-rejected"])
    func commandExpansionAndRejectionPreserveAdmissionSafety(outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let original = "/bedtime cafe\u{301}\n  trailing  "
        let expansion = " \n<skill>Fixture expansion</skill>\n\nExact tail  "
        rpc.handler = { method, params in
            if method == "command.dispatch" {
                #expect(params["name"] == .string("bedtime"))
                #expect(params["arg"]?.string.map { Data($0.utf8) } == Data("cafe\u{301}\n  trailing  ".utf8))
                if outcome == "rejected" { throw DirectHermesError.rpcRejected(code: 4018) }
                if outcome == "unknown" { throw DirectHermesError.timedOut(outcomeUnknown: true) }
                return .object(["type": .string("skill"), "message": .string(expansion)])
            }
            if method == "prompt.submit" {
                #expect(params["text"]?.string.map { Data($0.utf8) } == Data(expansion.utf8))
                #expect(params["queued"] == .boolean(true))
                if outcome == "expanded-rejected" { throw DirectHermesError.rpcRejected(code: 4018) }
                return .object(["status": .string("queued")])
            }
            throw DirectHermesError.invalidResponse
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.selectSlashCommand(.init(name: "bedtime", description: "Fixture command", category: "Skills",
            argsHint: "", aliases: [], argumentMode: .text, source: .skill, requiresArguments: false))
        model.draft = original
        await model.send()
        await model.retry()
        let methods = rpc.requests.map(\.method).filter { $0 != "session.control.read" }
        #expect(methods == (outcome.hasPrefix("expanded") ? ["command.dispatch", "prompt.submit"] : ["command.dispatch"]))
        #expect(!model.canRetry)
        #expect(!model.isSending)
        #expect(!model.items.contains { $0.content == .message(expansion) })
        if outcome == "rejected" {
            #expect(Data(model.draft.utf8) == Data(original.utf8))
            #expect(model.items.isEmpty)
            #expect(model.transcriptEntries.isEmpty)
            #expect(client.journal.unresolved.isEmpty)
            #expect(!client.needsRecovery)
        } else if outcome == "expanded" {
            #expect(client.journal.unresolved.isEmpty)
            #expect(!client.needsRecovery)
            #expect(model.failureMessage == nil)
        } else {
            #expect(client.journal.unresolved.count == 1)
            #expect(client.journal.unresolved.first?.method == "command.dispatch")
            #expect(client.journal.unresolved.first?.text == original)
            #expect(client.needsRecovery)
        }
    }

    @Test(arguments: ["recovered", "readback-failed", "owner-retired", "no-live-events", "malformed-no-live"])
    func lostPromptReceiptRecoversReadinessWithoutResending(outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        weak var observedClient: DirectHermesConversationClient?
        weak var observedModel: ChatModel?
        var sends = 0
        var reads = 0
        let hasLiveEvents = outcome != "no-live-events" && outcome != "malformed-no-live"
        rpc.handler = { method, _ in
            if method == "prompt.submit" {
                sends += 1
                if sends > 1 { return .object(["status": .string("queued")]) }
                if hasLiveEvents {
                    observedClient?.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
                    observedClient?.receive(.init(type: "message.complete", sessionID: "runtime",
                        payload: ["text": .string("The reply arrived")], sequence: 2))
                    observedClient?.receive(.init(type: "session.info", sessionID: "runtime",
                        payload: ["running": .boolean(false)], sequence: 3))
                }
                observedModel?.draft = "My independent follow-up"
                if outcome == "malformed-no-live" { return .object([:]) }
                throw DirectHermesError.timedOut(outcomeUnknown: true)
            }
            if method == "session.events.since" {
                reads += 1
                if outcome == "readback-failed" { throw DirectHermesError.notConnected }
                if outcome == "owner-retired" { observedClient?.suspend() }
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(hasLiveEvents ? 3 : 0),
                    "truncated": .boolean(false), "events": .array([])])
            }
            if method == "session.activate" {
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"),
                    "running": .boolean(false), "messages": .array([])])
            }
            if method == "subagent.list" { return .object(["subagents": .array([])]) }
            throw DirectHermesError.invalidResponse
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        observedClient = client
        observedModel = model
        model.draft = "The original request"
        await model.send()
        for _ in 0..<1000 where reads == 0 || (client.connected && !client.isReadyForSubmission) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reads > 0)
        #expect(sends == 1)
        #expect(model.draft == "My independent follow-up")
        #expect(client.journal.unresolved.count == 1)
        let original = try #require(client.journal.unresolved.first)
        #expect(original.text == "The original request")
        #expect(!model.canRetry)
        if outcome == "recovered" || !hasLiveEvents {
            #expect(model.canSend)
            #expect(!client.needsRecovery)
            #expect(reads == 2)
            await model.send()
            #expect(sends == 2)
            #expect(client.journal.unresolved.map(\.id) == [original.id])
        } else {
            #expect(!model.canSend)
            #expect(client.needsRecovery)
            #expect(reads == 1)
        }
    }

    @Test func stockReplayWithoutOpenRequestsRecoversSavedChatAndDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        // Installed stock methods_session.py returns these five fields. The
        // newer open_requests extension must not become a basic-chat gate.
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([]), "count": .integer(0)])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"),
                    "running": .boolean(false), "messages": .array([
                        .object(["role": .string("user"), "text": .string("Saved question")]),
                        .object(["role": .string("assistant"), "text": .string("Saved answer")])
                    ])])
            case "subagent.list": return .object(["subagents": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let drafts = DirectHermesDraftStore(root: root)
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: drafts)
        client.saveDraft("Unsent draft")
        let model = ChatModel(conversationID: client.conversationID, client: client,
                              initialItems: [], initialDraft: client.journal.draft)
        client.model = model
        try await client.recover(epoch: "epoch")
        #expect(client.isReadyForSubmission)
        #expect(model.items.contains { $0.content == .message("Saved answer") })
        #expect(model.draft == "Unsent draft")
        let reopened = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: drafts)
        #expect(reopened.journal.draft == "Unsent draft")
        client.suspend()
    }

    @Test func canonicalReentryKeepsSameSocketReceivingLaterDeltas() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object([
                    "epoch": .string("epoch"), "latest_seq": .integer(2),
                    "truncated": .boolean(false), "events": .array([]),
                    "open_requests": .array([]),
                ])
            case "session.activate":
                return .object([
                    "session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "running": .boolean(true), "messages": .array([]),
                ])
            default:
                throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("A")], sequence: 2
        ))

        try await client.recover(epoch: client.projection.epoch)
        let connectionGeneration = client.sessionActionsConnectionGeneration
        client.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("B")], sequence: 3
        ))
        client.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("C")], sequence: 4
        ))

        #expect(client.sessionActionsConnectionGeneration == connectionGeneration)
        #expect(client.projection.lastSequence == 4)
        #expect(model.items.filter { $0.content == .message("ABC") }.count == 1)
        #expect(client.isReadyForSubmission)
        #expect(rpc.disconnectCount == 0)
        #expect(!rpc.requests.contains { $0.method == "prompt.submit" })
    }

    @Test func failedCanonicalReentryReplaysAContiguousHeldDeltaBeforeReopeningSend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var client: DirectHermesConversationClient?
        var eventReads = 0
        let failTail = true
        rpc.handler = { method, params in
            switch method {
            case "session.events.since":
                eventReads += 1
                if failTail && eventReads == 2 {
                    throw DirectHermesError.serverUnavailable
                }
                let lastSeen = params["last_seen"]?.integer ?? 0
                let events: [BighelpJSONValue] = lastSeen < 4 ? [
                    .object([
                        "type": .string("message.delta"), "session_id": .string("runtime"),
                        "seq": .integer(3), "payload": .object(["text": .string("B")]),
                    ]),
                    .object([
                        "type": .string("message.complete"), "session_id": .string("runtime"),
                        "seq": .integer(4), "payload": .object([:]),
                    ]),
                ] : []
                return .object([
                    "epoch": .string("epoch"), "latest_seq": .integer(4),
                    "truncated": .boolean(false), "events": .array(events),
                    "open_requests": .array([]),
                ])
            case "session.activate":
                if failTail {
                    client?.receive(.init(
                        type: "message.delta", sessionID: "runtime",
                        payload: ["text": .string("B")], sequence: 3
                    ))
                    client?.receive(.init(
                        type: "message.complete", sessionID: "runtime",
                        payload: [:], sequence: 4
                    ))
                }
                return .object([
                    "session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "running": .boolean(true), "messages": .array([]),
                ])
            default:
                throw DirectHermesError.invalidResponse
            }
        }
        let retained = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        client = retained
        defer { retained.suspend() }
        let model = ChatModel(conversationID: retained.conversationID, client: retained, initialItems: [])
        retained.model = model
        retained.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        retained.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("A")], sequence: 2
        ))

        await #expect(throws: DirectHermesError.self) {
            try await retained.recoverPreservingLiveTransport(epoch: retained.projection.epoch)
        }

        #expect(retained.isReadyForSubmission)
        model.draft = "Follow-up"
        #expect(model.canSend)
        #expect(retained.projection.lastSequence == 4)
        #expect(model.items.contains { $0.content == .message("AB") })

        retained.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 5))
        retained.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("Still live")], sequence: 6
        ))
        #expect(retained.projection.lastSequence == 6)
        #expect(model.items.contains { $0.content == .message("Still live") })
        retained.receive(.init(
            type: "message.complete", sessionID: "runtime", payload: [:], sequence: 7
        ))
        #expect(retained.isReadyForSubmission)
    }

    @Test func failedCanonicalReentryKeepsAGappedDeltaClosedUntilDurableCatchup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var client: DirectHermesConversationClient?
        let recovery = CanonicalTailFailureState()
        rpc.handler = { method, params in
            switch method {
            case "session.events.since":
                recovery.eventReads += 1
                if recovery.tailFails && recovery.eventReads == 2 { throw DirectHermesError.serverUnavailable }
                let lastSeen = params["last_seen"]?.integer ?? 0
                let events: [BighelpJSONValue]
                let latest: Int
                if recovery.tailFails || lastSeen >= 5 {
                    events = []
                    latest = recovery.tailFails ? 2 : 5
                } else {
                    events = [
                        .object([
                            "type": .string("message.delta"), "session_id": .string("runtime"),
                            "seq": .integer(3), "payload": .object(["text": .string(" covered")]),
                        ]),
                        .object([
                            "type": .string("message.delta"), "session_id": .string("runtime"),
                            "seq": .integer(4), "payload": .object(["text": .string("B")]),
                        ]),
                        .object([
                            "type": .string("message.complete"), "session_id": .string("runtime"),
                            "seq": .integer(5), "payload": .object([:]),
                        ]),
                    ]
                    latest = 5
                }
                return .object([
                    "epoch": .string("epoch"), "latest_seq": .integer(latest),
                    "truncated": .boolean(false), "events": .array(events),
                    "open_requests": .array([]),
                ])
            case "session.activate":
                if recovery.tailFails {
                    client?.receive(.init(
                        type: "message.delta", sessionID: "runtime",
                        payload: ["text": .string("B")], sequence: 4
                    ))
                }
                return .object([
                    "session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "running": .boolean(true), "messages": .array([]),
                ])
            default:
                throw DirectHermesError.invalidResponse
            }
        }
        let retained = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        client = retained
        defer { retained.suspend() }
        let model = ChatModel(conversationID: retained.conversationID, client: retained, initialItems: [])
        retained.model = model
        retained.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        retained.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("A")], sequence: 2
        ))

        await #expect(throws: DirectHermesError.self) {
            try await retained.recoverPreservingLiveTransport(epoch: retained.projection.epoch)
        }
        #expect(!retained.isReadyForSubmission)
        #expect(retained.projection.lastSequence == 2)

        recovery.tailFails = false
        recovery.eventReads = 0
        try await retained.recoverPreservingLiveTransport(epoch: retained.projection.epoch)
        #expect(retained.isReadyForSubmission)
        #expect(retained.projection.lastSequence == 5)
        #expect(model.items.contains { $0.content == .message("A coveredB") })
    }

    @Test func failedCanonicalReentryRestoresReadinessDraftAttachmentsAndJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "prompt.submit":
                throw DirectHermesError.timedOut(outcomeUnknown: true)
            case "session.events.since":
                return .object([
                    "epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([]),
                    "open_requests": .array([]),
                ])
            case "session.activate":
                return .object([
                    "session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "running": .boolean(false), "messages": .array([]),
                ])
            default:
                throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        defer { client.suspend() }
        let source = SessionRecord(
            id: client.conversationID, kind: .direct,
            agentIDs: ["default"], title: "Chat", remoteStoredID: "saved"
        )
        let model = ChatModel(
            conversationID: client.conversationID,
            client: client,
            initialItems: [],
            sourceSession: source
        )
        client.model = model
        await model.perform(.weatherAndTasks)
        try await client.recover(epoch: "epoch")
        model.draft = "Keep this independent draft"
        let attachment = try ChatAttachment(
            id: "failed-refresh-attachment", fileName: "draft.txt",
            mimeType: "text/plain", data: Data("attachment".utf8)
        )
        try model.addDraftAttachment(attachment)
        let journalIDs = client.journal.unresolved.map(\.id)
        let attachmentIDs = model.orderedDraftAttachments.map(\.id)
        #expect(journalIDs.count == 1)
        #expect(client.isReadyForSubmission)
        #expect(model.canSend)

        rpc.handler = { method, _ in
            if method == "session.events.since" {
                throw DirectHermesError.serverUnavailable
            }
            throw DirectHermesError.invalidResponse
        }
        await #expect(throws: DirectHermesError.self) {
            try await client.recoverPreservingLiveTransport(epoch: client.projection.epoch)
        }

        #expect(client.isReadyForSubmission)
        #expect(model.canSend)
        #expect(model.draft == "Keep this independent draft")
        #expect(model.orderedDraftAttachments.map(\.id) == attachmentIDs)
        #expect(client.journal.unresolved.map(\.id) == journalIDs)
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(
            type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("Still live")], sequence: 2
        ))
        #expect(model.items.contains { $0.content == .message("Still live") })
    }

    @Test func warmStreamRequiresRecoveredExactOwnerAndAttachedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://native.example.test", providerID: "test", userID: "warm"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let id = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "default", anchorID: "saved")
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: id,
                                                       storedSessionID: "saved", runtimeSessionID: "runtime")
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false), "events": .array([]), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"), "running": .boolean(false), "messages": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: owner.cacheScopeID,
            profile: "default", runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate)
        let record = SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Chat", remoteStoredID: "saved")
        let model = ChatModel(conversationID: id, client: client, initialItems: [], sourceSession: record)
        client.model = model
        try client.seedWorkspaceHistory(record)
        #expect(!NativeWorkspaceSessionBridge.canReturnToPreparedStream(record: record, model: model, owner: owner,
            streamOwner: owner, recoveredCoordinate: nil, client: client))
        try await client.recover(epoch: "")
        #expect(NativeWorkspaceSessionBridge.canReturnToPreparedStream(record: record, model: model, owner: owner,
            streamOwner: owner, recoveredCoordinate: coordinate, client: client))
        let replacement = WorkspaceOwner(authority: owner.authority, authenticationGeneration: owner.authenticationGeneration,
                                         connectionGeneration: UUID())
        #expect(!NativeWorkspaceSessionBridge.canReturnToPreparedStream(record: record, model: model, owner: replacement,
            streamOwner: owner, recoveredCoordinate: coordinate, client: client))
        client.model = nil
        #expect(!NativeWorkspaceSessionBridge.canReturnToPreparedStream(record: record, model: model, owner: owner,
            streamOwner: owner, recoveredCoordinate: coordinate, client: client))
        client.model = model
        client.suspend()
        #expect(!NativeWorkspaceSessionBridge.canReturnToPreparedStream(record: record, model: model, owner: owner,
            streamOwner: owner, recoveredCoordinate: coordinate, client: client))
    }

    @Test func replayOpenRequestsRemainValidatedAndUseFinalSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed: [BighelpJSONValue] = [.null, .object([:]), .string("invalid")]
        for value in malformed {
            let rpc = DirectTestRPC()
            var delivered = false
            rpc.handler = { method, _ in
                if method == "session.events.since" {
                    return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                        "truncated": .boolean(false), "events": .array([]), "open_requests": value])
                }
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"), "running": .boolean(false), "messages": .array([])])
            }
            let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
                runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
                drafts: .init(root: root), openRequestRecovery: { _, _ in delivered = true })
            await #expect(throws: DirectHermesError.self) { try await client.recover(epoch: "epoch") }
            #expect(!delivered)
            #expect(!client.isReadyForSubmission)
        }
        let rpc = DirectTestRPC()
        let request: BighelpJSONValue = .object(["id": .string("request"), "method": .string("clarify"),
            "params": .object(["session_id": .string("runtime")])])
        var reads = 0
        var delivered: [BighelpJSONValue] = []
        rpc.handler = { method, _ in
            if method == "session.events.since" {
                reads += 1
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([]),
                    "open_requests": reads == 1 ? .array([]) : .array([request])])
            }
            return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"), "running": .boolean(false), "messages": .array([])])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: .init(root: root), openRequestRecovery: { value, runtime in
                #expect(runtime == "runtime")
                delivered.append(value)
            })
        try await client.recover(epoch: "epoch")
        #expect(delivered == [.array([request])])
        #expect(client.isReadyForSubmission)
        client.suspend()
    }

    @Test(arguments: ["valid", "stored", "profile", "session", "known-source"])
    func nativeCatalogSourcePromotionPreservesLiveStateAndExactOwner(boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://native.example.test", providerID: "fixture", userID: "fixture"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let id = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "default", anchorID: "stored")
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: id, storedSessionID: "stored", runtimeSessionID: "runtime")
        let original = SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Fixture", remoteStoredID: "stored", remoteSource: boundary == "known-source" ? "existing" : nil)
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch", drafts: .init(root: root), workspaceSession: coordinate)
        try client.seedWorkspaceHistory(original)
        let model = ChatModel(conversationID: id, client: client, agentID: "default", sourceSession: original)
        client.model = model
        defer { client.suspend() }
        model.draft = "Unsent draft"
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Keep")], sequence: 2))
        let items = model.items
        let next = SessionRecord(id: boundary == "session" ? "foreign" : id, kind: .direct,
            agentIDs: [boundary == "profile" ? "foreign" : "default"], title: "Fixture",
            remoteStoredID: boundary == "stored" ? "foreign" : "stored", remoteSource: "api")
        if boundary == "valid" {
            try client.adoptVerifiedCatalogSource(previous: original, next: next)
            #expect(model.ownsReferenceSession(next))
        } else {
            #expect(throws: WorkspaceClientError.self) { try client.adoptVerifiedCatalogSource(previous: original, next: next) }
            #expect(model.ownsReferenceSession(original))
        }
        #expect(model.items == items)
        #expect(model.draft == "Unsent draft")
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string(" streaming")], sequence: 3))
        #expect(model.items.last?.content == .message("Keep streaming"))
        #expect(model.ownsReferenceSession(boundary == "valid" ? next : original))
    }

    /// Leaving mid-reply: the reply finishes on the host while the app is away,
    /// and the reconnect cannot replay the events it missed (a new event
    /// epoch). Saved history is then the only full copy of that reply.
    @Test(arguments: [false, true])
    func replyFinishedWhileAwayComesFromSavedHistoryWhenReplayIsImpossible(exactReplay: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://native.example.test", providerID: "test", userID: "away"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let id = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "default", anchorID: "saved")
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: id,
                                                       storedSessionID: "saved", runtimeSessionID: "runtime")
        let rest: [BighelpJSONValue] = [
            .object(["type": .string("message.delta"), "session_id": .string("runtime"), "seq": .integer(3),
                     "payload": .object(["text": .string(" reply, finished.")])]),
            .object(["type": .string("message.complete"), "session_id": .string("runtime"), "seq": .integer(4),
                     "payload": .object(["text": .string("Half a reply, finished.")])]),
            .object(["type": .string("session.info"), "session_id": .string("runtime"), "seq": .integer(5),
                     "payload": .object(["running": .boolean(false)])]),
        ]
        let rpc = DirectTestRPC()
        var eventReads = 0
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                eventReads += 1
                return .object(["epoch": .string(exactReplay ? "epoch" : "epoch-2"),
                                "latest_seq": .integer(exactReplay ? 5 : 0), "truncated": .boolean(false),
                                "events": .array(exactReplay && eventReads == 1 ? rest : []), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"), "session_key": .string("saved"),
                                "running": .boolean(false), "messages": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: owner.cacheScopeID,
            profile: "default", runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate)
        let empty = SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Chat", remoteStoredID: "saved")
        let model = ChatModel(conversationID: id, client: client, initialItems: [], sourceSession: empty)
        client.model = model
        defer { client.suspend() }
        try client.seedWorkspaceHistory(empty)
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Half a")], sequence: 2))
        #expect(model.items.last?.content == .message("Half a"))

        func row(_ id: String, _ role: TimelineRole, _ text: String, _ order: Int) -> TimelineItem {
            TimelineItem(id: id, role: role,
                sender: role == .human ? .user(snapshot: .init(name: "You")) : .agent(id: "default", snapshot: .init(name: "default")),
                content: .message(text), metadata: .init(delivery: "Saved", timestamp: .now, sourceOrder: order))
        }
        var saved = empty
        saved.items = [row("saved:row:1", .human, "Hello", 1), row("saved:row:2", .assistant, "Half a reply, finished.", 2)]
        // Back from the background: saved history arrives before Hermes says the turn ended.
        try client.seedWorkspaceHistory(saved)
        try await client.recover(epoch: client.projection.epoch)
        #expect(!client.projection.running)
        #expect(client.needsCatalogHistoryReseed == !exactReplay)
        if exactReplay {
            // The replay itself carried the rest of the reply.
            #expect(model.items.last?.content == .message("Half a reply, finished."))
        } else {
            #expect(model.items.last?.content == .message("Half a"))
            try client.reseedFinishedTurn(saved)
            #expect(model.items.map(\.content) == [.message("Hello"), .message("Half a reply, finished.")])
            #expect(!model.isSending)
        }
        #expect(!client.needsCatalogHistoryReseed)
    }

    @Test func staleWorkspaceSeedCannotEraseConsumedOffscreenEvents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://native.example.test", providerID: "test", userID: "offscreen-seed"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
        let id = try DirectHermesSessionIdentity.appID(owner: owner, profileID: "default", anchorID: "saved")
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: id,
                                                       storedSessionID: "saved", runtimeSessionID: "runtime")
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: owner.cacheScopeID,
            profile: "default", runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate)
        let stale = SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Chat", remoteStoredID: "saved")
        try client.seedWorkspaceHistory(stale)
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Still updating")], sequence: 2))
        client.receive(.init(type: "tool.start", sessionID: "runtime", payload: ["tool_id": .string("call"), "name": .string("read_file")], sequence: 3))
        let rows = client.projection.items.map(\.id)
        let activities = client.projection.activities.map(\.id)
        try client.seedWorkspaceHistory(stale)
        #expect(client.projection.items.map(\.id) == rows)
        #expect(client.projection.activities.map(\.id) == activities)
        #expect(client.projection.lastSequence == 3)
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string(" offscreen")], sequence: 4))
        #expect(client.projection.items.last?.content == .message("Still updating offscreen"))
    }

    @Test func idleNativeTurnStopsOrphanToolAnimationsWithoutInventingSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "tool.start", sessionID: "runtime", payload: [
            "tool_id": .string("image-call"), "name": .string("image_generate")], sequence: 2))
        let id = try #require(model.activityLedger.allEvents.first?.id)
        #expect(model.activityLedger.event(id: id)?.lifecycle == .running)
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 3))
        #expect(model.activityLedger.event(id: id)?.lifecycle == .recorded)
        #expect(model.activityLedger.allEvents.count == 1)
        #expect(!model.isSending)
    }

    @Test func reasoningStopsAtToolExecutionAndLaterReasoningKeepsItsOwnPhase() {
        var projection = DirectHermesProjection(conversationID: "chat", profile: "default", storedID: "stored", epoch: "epoch")
        _ = projection.accept(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        _ = projection.accept(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string("First thought")], sequence: 2))
        let firstID = projection.activities.first?.id
        _ = projection.accept(.init(type: "tool.start", sessionID: "runtime", payload: [
            "tool_id": .string("read"), "name": .string("vision_analyze")], sequence: 3))
        #expect(projection.activities.first(where: { $0.id == firstID })?.lifecycle == .succeeded)
        _ = projection.accept(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string("Second thought")], sequence: 4))
        let thoughts = projection.activities.filter { $0.kind == .reasoning }
        #expect(thoughts.count == 2)
        #expect(thoughts.last?.detail == "Second thought")
        #expect(thoughts.last?.lifecycle == .running)
        #expect(projection.activities.allSatisfy { GeneratedMediaProjection.kind(for: $0) == nil })
    }

    /// Regression: the live Hermes client never conformed to
    /// QueuedConversationClient, so every "don't wait" Shortcut threw
    /// ChatQueuedSubmissionError.unavailable. Fixture clients hid the gap.
    @Test func queuedSubmitReturnsOnAdmissionWithoutWaitingForTheReply() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "prompt.submit": return .object(["status": .string("streaming")])
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                                "events": .array([]), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                                "running": .boolean(false), "messages": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root))
        defer { client.suspend() }
        let queued: any QueuedConversationClient = client
        let source = SessionRecord(id: client.conversationID, kind: .direct, agentIDs: ["default"],
            title: "Chat", remoteStoredID: "saved")
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [], sourceSession: source)
        client.model = model
        try await client.recover(epoch: "epoch")
        // The turn is admitted ("streaming") but never finishes in this test.
        // A waited send would hang here; the queued path must return.
        try await queued.submit(message: "Run the nightly report", attachments: [], conversationID: client.conversationID)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
        #expect(client.admitted)
    }

    @Test func queuedSubmitSurfacesARefusalInsteadOfClaimingItWasSent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "prompt.submit": throw DirectHermesError.rpcRejected(code: 4004)
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                                "events": .array([]), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                                "running": .boolean(false), "messages": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root))
        defer { client.suspend() }
        try await client.recover(epoch: "epoch")
        await #expect(throws: (any Error).self) {
            try await client.submit(message: "Run it", attachments: [], conversationID: client.conversationID)
        }
    }

    @Test func idleAfterADriftedTurnIDStillReenablesSend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                                "events": .array([]), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                                "running": .boolean(false), "messages": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root))
        defer { client.suspend() }
        let source = SessionRecord(id: client.conversationID, kind: .direct, agentIDs: ["default"],
            title: "Chat", remoteStoredID: "saved")
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [], sourceSession: source)
        client.model = model
        try await client.recover(epoch: "epoch")
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        #expect(model.isSending)
        // A second start (replay/reconnect) moves the projection's turn without
        // the model adopting it, then the host reports idle.
        model.adoptNativeTurn(from: client, turnID: "stale-turn", running: true)
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 2))
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 3))
        #expect(!model.isSending)
        model.draft = "Follow-up"
        #expect(model.canSend)
    }

    @Test func toolGeneratingPreambleDoesNotLeaveAStuckDuplicateToolRow() {
        var projection = DirectHermesProjection(conversationID: "chat", profile: "default", storedID: "stored", epoch: "epoch")
        _ = projection.accept(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        let generating = projection.accept(.init(type: "tool.generating", sessionID: "runtime",
            payload: ["name": .string("terminal")], sequence: 2))
        #expect(generating.toolGenerating?.name == "terminal")
        #expect(generating.activities.isEmpty)
        _ = projection.accept(.init(type: "tool.start", sessionID: "runtime", payload: [
            "tool_id": .string("call_1"), "name": .string("terminal"),
            "args": .object(["command": .string("cd /tmp")])], sequence: 3))
        _ = projection.accept(.init(type: "tool.complete", sessionID: "runtime", payload: [
            "tool_id": .string("call_1"), "name": .string("terminal"),
            "result": .object(["exit_code": .number(0)])], sequence: 4))
        let tools = projection.activities.filter { $0.kind == .tool }
        #expect(tools.count == 1)
        #expect(tools.first?.toolCallID == "call_1")
        #expect(tools.first?.lifecycle == .succeeded)
        #expect(!projection.activities.contains { $0.lifecycle == .running })
    }

    /// A plain tap on Send while this chat's own turn runs a tool steers it.
    /// The running prompt kept the chat "not ready for a new turn", and Send
    /// quietly did nothing; only the hold menu's options worked.
    @Test func plainSendDuringOwnRunningTurnSteers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        // As stock Hermes answers: a prompt starts streaming; a steer is queued.
        rpc.handler = { method, _ in
            .object(["status": .string(method == "prompt.submit" ? "streaming" : "queued")])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.draft = "Run the long command"
        let turn = Task { await model.send() }
        for _ in 0..<200 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(true)], sequence: 1))
        client.receive(.init(type: "tool.start", sessionID: "runtime", payload: [
            "tool_id": .string("call_1"), "name": .string("terminal"),
            "args": .object(["command": .string("sleep 20")])], sequence: 2))
        #expect(model.isSending)
        #expect(!client.isReadyForSubmission)
        #expect(model.canSend == false) // empty draft

        model.draft = "Also check the logs"
        #expect(model.canSend)
        await model.send()

        #expect(rpc.requests.filter { $0.method == "session.steer" }.count == 1)
        #expect(rpc.requests.last(where: { $0.method == "session.steer" })?.params["text"]?.string == "Also check the logs")
        #expect(model.draft.isEmpty)
        turn.cancel()
    }

    /// An agent's reaction lands on the message you just sent while the turn
    /// runs. That message has no saved row in its ID until a reload, so the
    /// live `message.reaction` found nothing to attach to. Hermes reports the
    /// row at Send (`user_row_id`) and again when the turn ends
    /// (`persisted_turn`); without either, the app never guesses.
    @Test(arguments: [true, false])
    func agentReactionShowsOnTheJustSentMessageDuringTheTurn(rowAtSend: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { return .object(["status": .string("queued")]) }
            return .object(["status": .string("streaming")]
                .merging(rowAtSend ? ["user_row_id": .integer(8_933)] : [:]) { $1 })
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let earlier = TimelineItem(id: "\(client.conversationID):row:8931", role: .human,
                                   sender: .user(snapshot: .init(name: "You")), content: .message("Hi"),
                                   metadata: .init(source: "Hermes", delivery: "Saved", sourceOrder: 1))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [earlier])
        client.model = model
        model.draft = "React to this message with a heart."
        let turn = Task { await model.send() }
        for _ in 0..<200 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.reaction", sessionID: "runtime", payload: [
            "row_id": .integer(8_933), "role": .string("user"),
            "reactions": .array([.object(["emoji": .string("❤️"), "author": .string("agent")])]),
        ], sequence: 2))
        let sent = try #require(model.items.last { $0.role == .human })
        #expect(sent.id != earlier.id)
        func hearts(_ item: TimelineItem) -> [String] {
            model.nativeMessageReactionPresentation(for: item).reactions.map(\.emoji)
        }
        #expect(hearts(sent) == (rowAtSend ? ["❤️"] : []))
        #expect(hearts(earlier).isEmpty)
        client.receive(.init(type: "message.complete", sessionID: "runtime", payload: [
            "text": .string("Done."), "persisted_turn": .object([
                "user_row_id": .integer(8_933), "row_ids": .array([.integer(8_933), .integer(8_934)]),
                "final_assistant_row_id": .integer(8_934), "complete": .boolean(true),
            ]),
        ], sequence: 3))
        #expect(hearts(sent) == ["❤️"])
        #expect(hearts(earlier).isEmpty)
        let reply = try #require(model.items.last { $0.role == .assistant })
        #expect(model.nativeMessageReactionPresentation(for: reply).rowID == 8_934)
        turn.cancel()
    }

    /// Hermes retries a reply with no text, so an agent whose reaction says it all ends the turn
    /// with a silence marker. That answers the person: no bubble and no "silence marker" warning,
    /// whether the reaction lands before the marker or just after it. Without a reaction the
    /// person still gets Hermes' notice.
    @Test(arguments: ["before", "after", "none"])
    func aReactionThenASilenceMarkerIsTheWholeReply(reaction: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { return .object(["status": .string("queued")]) }
            return .object(["status": .string("streaming"), "user_row_id": .integer(8_933)])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.draft = "Ok"
        let turn = Task { await model.send() }
        for _ in 0..<200 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        func thumbsUp(_ sequence: Int) -> DirectHermesEvent {
            .init(type: "message.reaction", sessionID: "runtime", payload: [
                "row_id": .integer(8_933), "role": .string("user"),
                "reactions": .array([.object(["emoji": .string("👍"), "author": .string("agent")])]),
            ], sequence: sequence)
        }
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        if reaction == "before" { client.receive(thumbsUp(2)) }
        client.receive(.init(type: "message.complete", sessionID: "runtime", payload: [
            "text": .string("[SILENT]"), "persisted_turn": .object([
                "user_row_id": .integer(8_933), "row_ids": .array([.integer(8_933), .integer(8_934)]),
                "final_assistant_row_id": .integer(8_934), "complete": .boolean(true),
            ]),
        ], sequence: 3))
        if reaction == "after" { client.receive(thumbsUp(4)) }
        let shown = model.transcriptEntries.compactMap { entry -> String? in
            guard case .message(let item) = entry, case .message(let text) = item.content else { return nil }
            return text
        }
        #expect(shown == (reaction == "none" ? ["Ok", ChatSilentReply.notice] : ["Ok"]))
        turn.cancel()
    }

    @Test func reactingUsesHermesReactionsWithoutAnExtraTurn() async throws {
        // Hermes records the reaction and tells the agent at its next turn
        // (display.message_reactions). The app must not start a turn of its own.
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            guard method == "message.react" else { return .object(["status": .string("queued")]) }
            return .object(["row_id": .integer(42), "reactions": .array([
                .object(["emoji": .string("❤️"), "author": .string("user")])])])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        let reply = TimelineItem(id: "\(client.conversationID):row:42", role: .assistant,
                                 sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                 content: .message("Here you go."), metadata: .init(source: "Hermes", delivery: "Saved"))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [reply])
        client.model = model

        await model.setNativeMessageReaction("❤️", for: reply.id)
        try await Task.sleep(for: .milliseconds(200))

        #expect(rpc.requests.filter { $0.method == "message.react" }.count == 1)
        #expect(rpc.requests.last(where: { $0.method == "message.react" })?.params["emoji"]?.string == "❤️")
        #expect(!rpc.requests.contains { $0.method == "prompt.submit" })
    }

    @Test func acknowledgedSteersDoNotBecomeRetainedSubmissionAlerts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.result = .object(["status": .string("queued")])
        let drafts = DirectHermesDraftStore(root: root)
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: drafts)
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(true)], sequence: 1))
        _ = try await client.sendMidSession(message: "Use the revised scope", attachments: [],
            conversationID: client.conversationID, behavior: .steer, onDraft: { _ in })
        #expect(client.journal.unresolved.isEmpty)
        let reopened = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: drafts)
        #expect(!reopened.needsRecovery)
        #expect(reopened.journal.unresolved.isEmpty)
        #expect(rpc.requests.map(\.method) == ["session.steer"])
    }

    @Test func optionalRosterDoesNotHoldRecoveryOrIncomingText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var releaseRoster: CheckedContinuation<Void, Never>?
        var rosterStarted = false
        rpc.handler = { method, _ in
            if method == "session.events.since" {
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([]), "open_requests": .array([])])
            }
            if method == "session.activate" {
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("stored"), "session_key": .string("stored"),
                    "running": .boolean(false), "messages": .array([])])
            }
            if method == "subagent.list" {
                rosterStarted = true
                await withCheckedContinuation { releaseRoster = $0 }
                return .object(["subagents": .array([])])
            }
            throw DirectHermesError.invalidResponse
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        var recovered = false
        let recovery = Task { try await client.recover(epoch: "epoch"); recovered = true }
        for _ in 0..<100 where !rosterStarted { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rosterStarted)
        for _ in 0..<20 where !recovered { try await Task.sleep(for: .milliseconds(5)) }
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Visible before roster")], sequence: 2))
        #expect(recovered)
        #expect(model.items.contains { $0.content == .message("Visible before roster") })
        releaseRoster?.resume()
        try await recovery.value
        client.suspend()
    }

    @Test func recoveredUnknownSteerStaysLocalWithoutBlockingIndependentMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(true)], sequence: 1))
        rpc.handler = { _, _ in throw DirectHermesError.timedOut(outcomeUnknown: true) }
        await #expect(throws: DirectHermesError.self) {
            _ = try await client.sendMidSession(message: "Unconfirmed old steer", attachments: [],
                conversationID: client.conversationID, behavior: .steer, onDraft: { _ in })
        }
        let original = try #require(client.journal.unresolved.first)
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false), "events": .array([]), "open_requests": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("stored"), "session_key": .string("stored"), "running": .boolean(false), "messages": .array([])])
            case "subagent.list": return .object(["subagents": .array([])])
            case "prompt.submit": return .object(["status": .string("queued")])
            default: throw DirectHermesError.invalidResponse
            }
        }
        try await client.recover(epoch: "epoch")
        #expect(!client.needsRecovery)
        #expect(client.journal.unresolved.first?.id == original.id)
        _ = try await client.send(message: "Independent new message", conversationID: client.conversationID)
        #expect(client.journal.unresolved.map(\.id) == [original.id])
        #expect(rpc.requests.filter { $0.method == "session.steer" }.count == 1)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.map { $0.params["text"] } == [.string("Independent new message")])
        client.suspend()
    }

    @Test func growingNativeTextUsesOneLookupRegardlessOfHistorySize() {
        var projection = DirectHermesProjection(conversationID: "chat", profile: "default", storedID: "stored", epoch: "epoch")
        let history = (0..<2_000).map { index in
            TimelineItem(id: "old-\(index)", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Hermes")), content: .message("History \(index)"), metadata: .init(source: "Fixture", delivery: "Saved"))
        }
        projection.retainVisible(items: history, activities: [])
        _ = projection.accept(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        for sequence in 2...102 {
            _ = projection.accept(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("x")], sequence: sequence))
            if sequence > 2 { #expect(projection.lastTextLookupWorkCount == 1) }
        }
        #expect(projection.items.count == 2_001)
        #expect(projection.items.last?.content == .message(String(repeating: "x", count: 101)))
        // A replaced/reordered snapshot must invalidate the fast index by ID.
        projection.retainVisible(items: Array(projection.items.reversed()), activities: [])
        _ = projection.accept(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("y")], sequence: 103))
        #expect(projection.items.first?.content == .message(String(repeating: "x", count: 101) + "y"))
        #expect(projection.items.last?.id == "old-0")
    }

    @Test func nativeUsageReachesContextDisplayAndRejectsReplayedOrForeignUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let usage: [String: BighelpJSONValue] = ["model": .string("host-model"), "context_used": .integer(29100),
            "context_max": .integer(1000000), "context_percent": .integer(3), "compressions": .integer(1),
            "input": .integer(18), "prompt": .integer(155225),
            "output": .integer(439), "total": .integer(155664)]
        client.receive(.init(type: "session.usage", sessionID: "runtime", payload: ["usage": .object(usage)], sequence: 5))
        #expect(model.sessionContext?.contextUsed == 29100)
        #expect(model.sessionContext?.contextMax == 1000000)
        #expect(model.sessionContext?.inputTokens == nil)
        #expect(model.sessionContext?.sessionInputTokens == 155225)
        #expect(model.sessionContext?.sessionOutputTokens == 439)
        #expect(model.sessionContext?.sessionTotalTokens == 155664)
        #expect(model.sessionContext?.sessionIncludesSubagents == false)
        #expect(model.sessionContext?.model == "host-model")
        var stale = usage; stale["context_used"] = .integer(1)
        client.receive(.init(type: "session.usage", sessionID: "other", payload: ["usage": .object(stale)], sequence: 6))
        client.receive(.init(type: "session.usage", sessionID: "runtime", payload: ["usage": .object(stale)], sequence: 4))
        #expect(model.sessionContext?.contextUsed == 29100)
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["usage": .object(usage)], sequence: 6))
        #expect(model.sessionContext?.compressions == 1)
    }

    @Test func nativeUsageReachesTheCatalogAndSurvivesAColdReopen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "native-persisted-session",
            storedSessionID: "saved-context", runtimeSessionID: "runtime-context"
        )
        let record = SessionRecord(
            id: coordinate.sessionID, kind: .direct, agentIDs: ["default"], title: "Native",
            remoteStoredID: coordinate.storedSessionID, remoteSource: "direct-hermes"
        )
        let repository = SessionContentRepository(
            directory: root.appending(path: "catalog", directoryHint: .isDirectory),
            name: "native-sessions-v2", currentSchemaVersion: 2
        )
        try repository.save([record])
        let catalog = SessionCatalogStore(
            client: DemoSessionCatalogClient(), repository: repository,
            persistenceCheckpointDelay: .zero
        )
        var currentOwner: WorkspaceOwner? = owner
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "runtime-context", storedID: "saved-context", title: "Native", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root.appending(path: "drafts", directoryHint: .isDirectory)),
            workspaceSession: coordinate
        )
        client.onSessionContextChange = { snapshot in
            guard currentOwner == owner else { return }
            catalog.reconcileSessionContext(snapshot)
        }

        client.receive(.init(
            type: "session.usage", sessionID: "runtime-context",
            payload: ["usage": .object([
                "model": .string("host-model"), "context_used": .integer(25_000),
                "context_max": .integer(272_000), "input": .integer(24_000), "prompt": .integer(24_000),
                "output": .integer(1_000), "cached": .integer(0), "total": .integer(25_000)
            ])], sequence: 7
        ))
        catalog.flushPersistence()

        let saved = try #require(repository.load().first)
        #expect(saved.sessionContext?.contextUsed == 25_000)
        #expect(saved.sessionContext?.contextMax == 272_000)
        #expect(saved.sessionContext?.inputTokens == nil)
        #expect(saved.sessionContext?.sessionInputTokens == 24_000)
        #expect(saved.sessionContext?.sessionCachedTokens == 0)

        let reopened = SessionCatalogStore(
            client: DemoSessionCatalogClient(), repository: repository,
            persistenceCheckpointDelay: .zero
        )
        #expect(reopened.session(id: coordinate.sessionID)?.sessionContext?.contextUsed == 25_000)
        #expect(reopened.session(id: coordinate.sessionID)?.sessionContext?.contextMax == 272_000)

        // A later event from a superseded connection may update its adapter,
        // but must not write through the bridge's owner-fenced catalog sink.
        currentOwner = WorkspaceOwner(
            authority: owner.authority, authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        client.receive(.init(
            type: "session.usage", sessionID: "runtime-context",
            payload: ["usage": .object([
                "model": .string("host-model"), "context_used": .integer(26_000),
                "context_max": .integer(272_000)
            ])], sequence: 8
        ))
        #expect(catalog.session(id: coordinate.sessionID)?.sessionContext?.contextUsed == 25_000)
    }

    @Test func nativeUsageSeedRejectsAContextFromAnotherStoredSession() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "native-context-boundary",
            storedSessionID: "current-stored", runtimeSessionID: "current-runtime"
        )
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "current-runtime", storedID: "current-stored", title: "Native", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate
        )
        let foreign = SessionRecord(
            id: coordinate.sessionID, kind: .direct, agentIDs: ["default"], title: "Native",
            remoteStoredID: "foreign-stored", remoteSource: "direct-hermes",
            sessionContext: SessionContextSnapshot(
                sessionId: coordinate.sessionID, model: "foreign-model", contextUsed: 250_000,
                contextMax: 272_000, contextPercent: 92, compressions: 0,
                isCompacting: false, updatedAt: 9_000
            )
        )

        #expect(throws: WorkspaceClientError.ownerChanged) {
            try client.seedWorkspaceHistory(foreign)
        }
        #expect(client.sessionContext == nil)
    }

    @Test func consecutiveNativeTurnsKeepHumanAndStreamRowsInArrivalOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var lastSequence = 0
        rpc.handler = { method, _ in
            if method == "session.events.since" {
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(lastSequence),
                                "truncated": .boolean(false), "events": .array([]),
                                "open_requests": .array([])])
            }
            if method == "subagent.list" { return .object(["subagents": .array([])]) }
            return .object(["status": .string("streaming")])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        defer { client.suspend() }
        for turn in 0..<3 {
            model.draft = "Question \(turn)"
            let send = Task { await model.send() }
            defer { send.cancel() }
            for _ in 0..<1000 where rpc.requests.filter({ $0.method == "prompt.submit" }).count <= turn {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(rpc.requests.filter { $0.method == "prompt.submit" }.count == turn + 1)
            let base = turn * 6
            client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: base + 1))
            client.receive(.init(type: "tool.start", sessionID: "runtime", payload: ["tool_id": .string("tool-\(turn)"), "name": .string("terminal")], sequence: base + 2))
            client.receive(.init(type: "tool.complete", sessionID: "runtime", payload: ["tool_id": .string("tool-\(turn)")], sequence: base + 3))
            client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Answer \(turn)")], sequence: base + 4))
            client.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string("Answer \(turn)")], sequence: base + 5))
            lastSequence = base + 6
            client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: base + 6))
            await send.value
        }
        #expect(model.items.map(\.content) == (0..<3).flatMap { [TimelineContent.message("Question \($0)"), .message("Answer \($0)")] })
        let orders = model.items.compactMap(\.metadata.sourceOrder)
        #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 })
        #expect(model.transcriptEntries.compactMap { entry -> String? in
            if case .message(let item) = entry, case .message(let text) = item.content { return text }
            return nil
        } == (0..<3).flatMap { ["Question \($0)", "Answer \($0)"] })
    }

    @Test func voiceGetsOnlyTheVerifiedNativeTurnFinalWithoutDuplicatingItsTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { _, _ in .object(["status": .string("streaming")]) }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "native-host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [], initialDraft: "Keep draft")
        client.model = model
        let task = Task { try await model.sendNativeVoiceMessage("Read my calendar") }
        defer { task.cancel(); client.suspend() }
        for _ in 0..<1000 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(rpc.requests.filter { $0.method != "session.control.read" }.map(\.method) == ["prompt.submit"])
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("Three")], sequence: 2))
        client.receive(.init(type: "message.complete", sessionID: "runtime", payload: ["text": .string("Three events tomorrow.")], sequence: 3))
        #expect(model.isSending)
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 4))
        let result = try await task.value
        #expect(result.items.map(\.content) == [.message("Three events tomorrow.")])
        #expect(model.items.filter { $0.role == .assistant }.count == 1)
        #expect(model.draft == "Keep draft")
        #expect(client.journal.unresolved.isEmpty)
    }

    @Test func successiveToolTurnsReturnTheirAnswersToTheSameLiveVoiceCall() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { _, _ in .object(["status": .string("streaming")]) }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "native-host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let chat = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = chat
        var results: [String] = []
        let voice = NativeLiveVoiceSession(
            owner: .init(hostID: "native-host", authorizationID: "auth", agentID: "default", sessionID: "stored"),
            operation: { operation, fields in
                switch operation {
                case .nativeVoiceOffer: return ["voiceId": fields["voiceId"]!]
                case .nativeVoicePoll: return ["voiceId": fields["voiceId"]!, "events": .array([]),
                                               "next": fields["after"]!, "closed": .boolean(false)]
                case .nativeVoiceResult:
                    results.append(try #require(fields["text"]?.string))
                    return ["voiceId": fields["voiceId"]!, "appended": .boolean(true)]
                case .nativeVoiceClose: return ["closed": .boolean(true)]
                default: throw LiveVoiceControlError.unavailable
                }
            }, isCurrent: { true }, submit: { text in
                let reply = try await chat.sendNativeVoiceMessage(text)
                return reply.items.compactMap { item in
                    if item.role == .assistant, case .message(let text) = item.content { return text }
                    return nil
                }.joined(separator: "\n\n")
            })
        let voiceModel = voice.makeModel(agentName: "Example")
        defer { voiceModel.invalidateOwner(); client.suspend() }
        _ = try await voice.perform("voice.live.offer", fields: ["voiceId": .string("call")])
        for turn in 0..<3 {
            voice.receiveEvent(["kind": .string("delegation"), "id": .string("request-\(turn)"),
                                "text": .string("Check schedule \(turn)")], voiceID: "call")
            for _ in 0..<1_000 where rpc.requests.filter({ $0.method == "prompt.submit" }).count <= turn {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(rpc.requests.filter { $0.method == "prompt.submit" }.count == turn + 1)
            let base = turn * 5
            client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: base + 1))
            client.receive(.init(type: "tool.start", sessionID: "runtime",
                                 payload: ["tool_id": .string("tool-\(turn)"), "name": .string("calendar")], sequence: base + 2))
            try await Task.sleep(for: .milliseconds(50))
            #expect(results.count == turn)
            client.receive(.init(type: "tool.complete", sessionID: "runtime",
                                 payload: ["tool_id": .string("tool-\(turn)")], sequence: base + 3))
            client.receive(.init(type: "message.complete", sessionID: "runtime",
                                 payload: ["text": .string("Schedule answer \(turn)")], sequence: base + 4))
            client.receive(.init(type: "session.info", sessionID: "runtime",
                                 payload: ["running": .boolean(false)], sequence: base + 5))
            for _ in 0..<1_000 where results.count <= turn { try await Task.sleep(for: .milliseconds(1)) }
            try #require(results == (0...turn).map { "Schedule answer \($0)" })
        }
        #expect(chat.items.filter { $0.role == .assistant }.count == 3)
        #expect(client.journal.unresolved.isEmpty)
    }

    @Test func createdNativeSessionCannotBeRetargetedByLocalAgentSelection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: "host-a", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client,
                              agentID: "default", initialItems: [], initialDraft: "Keep draft")
        #expect(!model.canReassignDirectAgent)
        model.reassignDirectAgent(to: "other", client: ConversationFixtureClient(),
                                  runtimeControls: nil, slashCommandCatalog: nil)
        #expect(model.nativeConversationClient === client)
        #expect(model.memberIDs == ["default"])
        #expect(model.draft == "Keep draft")
    }

    @Test func workspaceRecoveryRetainsCatalogHistoryAndOmitsLossyRPCHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "catalog-session",
            storedSessionID: "saved-a", runtimeSessionID: "runtime-a"
        )
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            if method == "session.events.since" {
                return .object(["epoch": .string("new-epoch"), "latest_seq": .integer(0),
                                "truncated": .boolean(true), "events": .array([]), "open_requests": .array([])])
            }
            if method == "subagent.list" { return .object(["subagents": .array([])]) }
            #expect(method == "session.activate")
            return .object([
                "session_id": .string("runtime-a"), "stored_session_id": .string("saved-a"), "session_key": .string("saved-a"),
                "running": .boolean(false),
                "messages": .array([.object(["role": .string("assistant"), "text": .string("Lossy RPC row")])])
            ])
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: owner.cacheScopeID, profile: "default", runtimeID: "runtime-a",
            storedID: "saved-a", title: "Native", epoch: "old-epoch",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate
        )
        let row = TimelineItem(
            id: "rest-row-42", role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Hermes")),
            content: .message("REST display content"), metadata: .init(sourceOrder: 1)
        )
        let evidence = ChatActivityEvent(
            eventID: "rest-tool-43", sessionID: coordinate.sessionID, turnID: "saved-turn",
            kind: .tool, lifecycle: .recorded, title: "Recorded tool", summary: nil, detail: nil,
            occurredAt: 123, toolCallID: "actual-call", result: "Original result", sourceOrder: 2
        )
        let model = ChatModel(conversationID: coordinate.sessionID, client: client,
                              initialItems: [row], initialDraft: "Retained draft",
                              initialActivityEvents: [evidence])
        client.model = model
        try await client.recover(epoch: "new-epoch")
        #expect(rpc.requests.first(where: { $0.method == "session.activate" })?.params["omit_messages"] == .boolean(true))
        #expect(model.items == [row])
        #expect(model.activityLedger.allEvents == [evidence])
        #expect(model.draft == "Retained draft")
        #expect(rpc.requests.allSatisfy { $0.method != "prompt.submit" && $0.method != "session.create" })
    }

    @Test(arguments: ["authority", "authentication", "connection"])
    func nativeRPCLeaseRejectsChangedOwnerBeforeDispatch(boundary: String) async throws {
        let original = try workspaceOwner()
        let replacement = WorkspaceOwner(
            authority: boundary == "authority"
                ? try .direct(endpointIdentity: "https://other.example", providerID: "basic", userID: "person")
                : original.authority,
            authenticationGeneration: boundary == "authentication" ? UUID() : original.authenticationGeneration,
            connectionGeneration: boundary == "connection" ? UUID() : original.connectionGeneration
        )
        let rpc = DirectTestRPC()
        let lease = try DirectHermesOwnedRPC(base: rpc, owner: original, currentOwner: { replacement })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await lease.request("prompt.submit", params: ["session_id": .string("runtime-a"), "text": .string("hello")])
        }
        #expect(rpc.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func nativeRPCLeaseRejectsLateResultsAndErrors(rejected: Bool) async throws {
        let original = try workspaceOwner()
        var current: WorkspaceOwner? = original
        let rpc = DirectTestRPC()
        rpc.handler = { _, _ in
            current = nil
            if rejected { throw DirectHermesError.rpcRejected(code: 4017) }
            return .object(["status": .string("streaming")])
        }
        let lease = try DirectHermesOwnedRPC(base: rpc, owner: original, currentOwner: { current })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await lease.request("prompt.submit", params: ["session_id": .string("runtime-a"), "text": .string("hello")])
        }
        #expect(rpc.requests.count == 1)
    }

    @Test func retiringNativeRPCLeaseDoesNotCloseOrStealTheSharedSocket() async throws {
        let owner = try workspaceOwner()
        var current: WorkspaceOwner? = owner
        let rpc = DirectTestRPC()
        var sharedEvents = 0
        rpc.onEvent = { _ in sharedEvents += 1 }
        let lease = try DirectHermesOwnedRPC(base: rpc, owner: owner, currentOwner: { current })
        var leasedEvents = 0
        lease.onEvent = { _ in leasedEvents += 1 }
        let event = DirectHermesEvent(type: "message.start", sessionID: "runtime-a", payload: [:], sequence: 1)
        lease.receive(event)
        #expect(leasedEvents == 1)
        current = nil
        lease.receive(event)
        #expect(leasedEvents == 1)
        current = owner
        await lease.disconnect()
        lease.onEvent = { _ in leasedEvents += 1 }
        lease.receive(event)
        #expect(leasedEvents == 1)
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await lease.request("session.activate", params: ["session_id": .string("runtime-a")])
        }
        rpc.onEvent?(event)
        #expect(sharedEvents == 1)
        #expect(rpc.disconnectCount == 0)
        #expect(rpc.requests.isEmpty)
    }

    @Test func commonShellBindsNativeEventsToItsOneRetainedChatModel() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "native-visible-session",
            storedSessionID: "saved-a", runtimeSessionID: "runtime-a"
        )
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "runtime-a", storedID: "saved-a", title: "Native", epoch: "epoch-a",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate
        )
        let record = SessionRecord(
            id: coordinate.sessionID, kind: .direct, agentIDs: ["default"], title: "Native",
            remoteStoredID: "saved-a", draft: "Retained draft"
        )
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [record])
        var bindingCount = 0
        let features = ShellFeatureStore(
            timing: .immediate, catalog: catalog, conversationClient: { _, _ in client },
            conversationPrepared: { model, receivedClient in
                #expect((receivedClient as? DirectHermesConversationClient) === client)
                bindingCount += 1
                client.model = model
            }
        )
        let route = AppRoute.chat(conversationID: coordinate.sessionID)
        #expect(features.prepare(route))
        guard case .chat(let model) = features.preparedModel(for: route) else {
            Issue.record("The common shell did not prepare its native chat.")
            return
        }
        #expect(client.model === model)
        #expect(model.draft == "Retained draft")
        client.receive(DirectHermesEvent(type: "message.start", sessionID: "runtime-a", payload: [:], sequence: 1))
        client.receive(DirectHermesEvent(type: "message.delta", sessionID: "runtime-a",
                                        payload: ["text": .string("Native reply")], sequence: 2))
        #expect(model.isSending)
        #expect(model.items.first?.content == .message("Native reply"))
        #expect(model.conversationID == coordinate.sessionID)
        #expect(features.prepare(route))
        #expect(bindingCount == 1)
        if case .chat(let retained) = features.preparedModel(for: route) {
            #expect(retained === model)
        } else { Issue.record("The prepared native model was lost.") }
        client.suspend()
        #expect(client.model === model)
        #expect(model.draft == "Retained draft")
    }

    @Test func workspaceVisibleIdentityNeverReplacesTheNativeRPCSessionID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "native-visible-session",
            storedSessionID: "saved-a", runtimeSessionID: "runtime-a"
        )
        let rpc = DirectTestRPC()
        rpc.result = .object(["status": .string("interrupted")])
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: owner.cacheScopeID, profile: "default",
            runtimeID: "runtime-a", storedID: "saved-a", title: "Native", epoch: "epoch-a",
            drafts: DirectHermesDraftStore(root: root), workspaceSession: coordinate
        )
        try await client.stop(conversationID: coordinate.sessionID)
        #expect(rpc.requests.count == 1)
        #expect(rpc.requests.first?.method == "session.interrupt")
        #expect(rpc.requests.first?.params["session_id"]?.string == "runtime-a")
        #expect(!rpc.requests.flatMap { $0.params.values }.contains(.string(coordinate.sessionID)))
    }

    @Test(arguments: ["host", "profile", "runtime", "stored"])
    func workspaceCoordinateMismatchCannotCreateAnAdapter(mismatch: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try workspaceOwner()
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner, profileID: "default", sessionID: "native-visible-session",
            storedSessionID: "saved-a", runtimeSessionID: "runtime-a"
        )
        #expect(throws: WorkspaceClientError.ownerChanged) {
            try DirectHermesConversationClient(
                rpc: DirectTestRPC(), hostIdentity: mismatch == "host" ? "another-host" : owner.cacheScopeID,
                profile: mismatch == "profile" ? "another-profile" : "default",
                runtimeID: mismatch == "runtime" ? "another-runtime" : "runtime-a",
                storedID: mismatch == "stored" ? "another-stored" : "saved-a",
                title: "Native", epoch: "epoch-a", drafts: DirectHermesDraftStore(root: root),
                workspaceSession: coordinate
            )
        }
    }

    private func workspaceOwner() throws -> WorkspaceOwner {
        WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://native.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
    }

    @Test func idleSnapshotDoesNotInventQueueActivity() {
        var projection = DirectHermesProjection(conversationID: "native", profile: "default", storedID: "stored", epoch: "epoch")
        projection.seedSnapshot(["session_id": .string("runtime"), "running": .boolean(false), "inflight": .null, "queued": .null], epoch: "epoch")
        #expect(projection.items.isEmpty)
        #expect(projection.activities.isEmpty)
    }

    @Test func nativeSubagentStreamFeedsTheSessionAgentsRail() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model

        client.receive(.init(
            type: "subagent.start", sessionID: "runtime",
            payload: [
                "subagent_id": .string("sa-1"),
                "child_session_id": .string("child-runtime-1"),
                "parent_id": .string("root"),
                "goal": .string("Inspect the delegated task")
            ], sequence: 1
        ))

        #expect(model.nativeSubagents.count == 1)
        #expect(model.nativeSubagents.first?.id == "sa-1")
        #expect(model.nativeSubagents.first?.childSessionID == "child-runtime-1")
        #expect(SessionStatusRailPresentation.items(
            goal: nil, subagents: [], nativeSubagents: model.nativeSubagents, tasks: nil
        ).map(\.kind) == [.subagents])

        client.receive(.init(
            type: "subagent.start", sessionID: "runtime",
            payload: [
                "subagent_id": .string("sa-2"),
                "goal": .string("Status before a child session is assigned")
            ], sequence: 2
        ))
        #expect(model.nativeSubagents.count == 2)
        #expect(model.nativeSubagents.first(where: { $0.id == "sa-2" })?.childSessionID == nil)

        client.receive(.init(
            type: "subagent.complete", sessionID: "runtime",
            payload: ["subagent_id": .string("sa-1"), "status": .string("completed")], sequence: 3
        ))
        #expect(model.nativeSubagents.map(\.id) == ["sa-2"])
    }

    @Test func nativeSubagentRosterRehydratesFromTheOwnedSessionLease() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object([
                    "epoch": .string("epoch"),
                    "latest_seq": .integer(0),
                    "open_requests": .array([]),
                    "truncated": .boolean(false),
                    "events": .array([])
                ])
            case "session.activate":
                return .object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"), "session_key": .string("stored"),
                    "running": .boolean(false),
                    "messages": .array([])
                ])
            case "subagent.list":
                return .object(["subagents": .array([.object([
                    "subagent_id": .string("sa-recovered"),
                    "parent_id": .string("root"),
                    "goal": .string("Continue the recovered task"),
                    "status": .string("running"),
                    "model": .string("gpt-native"),
                    "tool_count": .integer(2),
                    "started_at": .number(1234)
                ])])])
            default:
                Issue.record("Unexpected native recovery RPC: \(method)")
                return .object([:])
            }
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model

        try await client.recover(epoch: "epoch")
        for _ in 0..<100 where model.nativeSubagents.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        #expect(model.nativeSubagents.count == 1)
        #expect(model.nativeSubagents.first?.id == "sa-recovered")
        #expect(model.nativeSubagents.first?.childSessionID == nil)
        #expect(rpc.requests.contains { $0.method == "subagent.list" && $0.params["session_id"]?.string == "runtime" })

        // A live progress event may omit the goal that was present in the
        // recovered roster. Preserve that authoritative goal while updating
        // the status card from the stream.
        client.receive(.init(
            type: "subagent.thinking", sessionID: "runtime",
            payload: ["subagent_id": .string("sa-recovered"), "text": .string("Still working")], sequence: 1
        ))
        #expect(model.nativeSubagents.first?.goal == "Continue the recovered task")
    }

    @Test func emptyRecoveryBoundaryDoesNotCreateACompletedTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var eventsSinceCount = 0
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                eventsSinceCount += 1
                if eventsSinceCount == 1 {
                    return .object(["epoch": .string("new-epoch"), "latest_seq": .integer(1),
                                    "truncated": .boolean(true), "events": .array([]), "open_requests": .array([])])
                }
                return .object(["epoch": .string("new-epoch"), "latest_seq": .integer(2),
                                "open_requests": .array([]),
                                "truncated": .boolean(true), "events": .array([.object([
                                    "type": .string("session.info"), "session_id": .string("runtime-a"),
                                    "seq": .integer(2), "payload": .object(["running": .boolean(false)])
                                ])])])
            case "session.activate":
                return .object([
                    "session_id": .string("runtime-a"), "stored_session_id": .string("saved-a"), "session_key": .string("saved-a"),
                    "running": .boolean(false), "messages": .array([])
                ])
            case "subagent.list":
                return .object(["subagents": .array([])])
            default:
                Issue.record("Unexpected recovery RPC: \(method)")
                return .object([:])
            }
        }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host-a", profile: "default", runtimeID: "runtime-a",
            storedID: "saved-a", title: "New chat", epoch: "old-epoch",
            drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model

        try await client.recover(epoch: "new-epoch")

        #expect(model.items.isEmpty)
        #expect(model.activityLedger.allEvents.isEmpty)
        let rows = ChatCompletedTurnProjection.rows(
            from: model.transcriptEntries,
            isSending: model.isSending,
            enabled: true,
            activityEvents: model.activityLedger.allEvents
        )
        #expect(rows.isEmpty)
    }

    @Test func stockReplayParametersPreserveSessionAndSequence() {
        let events = DirectHermesConversationClient.replayEvents(.array([.object([
            "type": .string("message.delta"), "session_id": .string("runtime"), "seq": .integer(12),
            "payload": .object(["text": .string("piece")])
        ])]))
        #expect(events.count == 1)
        #expect(events.first?.sessionID == "runtime")
        #expect(events.first?.sequence == 12)
        #expect(events.first?.payload["text"]?.string == "piece")
    }

    @Test func externalNativeTurnActivatesExistingModelWithoutInventingUserRow() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: "host-a", profile: "default",
            runtimeID: "runtime-a", storedID: "saved-a", title: "Native", epoch: "epoch-a", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(DirectHermesEvent(type: "message.start", sessionID: "runtime-a", payload: [:], sequence: 1))
        #expect(model.isSending)
        #expect(model.items.isEmpty)
        client.receive(DirectHermesEvent(type: "message.delta", sessionID: "runtime-a", payload: ["text": .string("Hello")], sequence: 2))
        #expect(model.items.count == 1)
        #expect(model.items.first?.role == .assistant)
        client.receive(DirectHermesEvent(type: "message.complete", sessionID: "runtime-a", payload: ["text": .string("Hello")], sequence: 3))
        #expect(model.isSending)
        client.receive(DirectHermesEvent(type: "session.info", sessionID: "runtime-a", payload: ["running": .boolean(false)], sequence: 4))
        #expect(!model.isSending)
        #expect(model.items.count == 1)
    }

    @Test func nativeReasoningClosesAtToolPhaseAndNewReasoningKeepsItsOwnIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [],
                              initialActivityVisibility: .init(showReasoning: true, showToolCalls: true))
        client.model = model
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        client.receive(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string("Visible ")], sequence: 2))
        let firstID = try #require(model.activityLedger.allEvents.first?.id)
        client.receive(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string("reasoning token")], sequence: 3))
        let liveReasoning = try #require(model.activityLedger.allEvents.first { $0.kind == .reasoning })
        #expect(model.activityDisclosures.isExpanded(liveReasoning))
        client.receive(.init(type: "tool.start", sessionID: "runtime", payload: [
            "tool_id": .string("call-1"), "name": .string("read_file")
        ], sequence: 4))
        let reasoning = try #require(model.activityLedger.allEvents.first { $0.kind == .reasoning })
        #expect(reasoning.id == firstID)
        #expect(reasoning.detail == "Visible reasoning token")
        #expect(reasoning.presentationTitle == "Thinking")
        #expect(model.isSending)
        let rows = ChatCanvasTranscriptProjection.rows(from: ChatCompletedTurnProjection.rows(
            from: model.transcriptEntries, isSending: model.isSending, enabled: true
        ), disclosures: model.activityDisclosures)
        let independentReasoning = rows.compactMap { row -> ChatActivityEvent? in
            guard case .transcript(.entry(.activity(let turn))) = row,
                  turn.events.count == 1, turn.events.first?.kind == .reasoning else { return nil }
            return turn.events.first
        }
        #expect(independentReasoning.map(\.id) == [reasoning.id])
        #expect(reasoning.lifecycle == .succeeded)
        #expect(!model.activityDisclosures.isExpanded(reasoning))
        let trails = rows.compactMap { row -> ChatActivityTurn? in
            guard case .workTrailHeader(let turn, _) = row else { return nil }
            return turn
        }
        #expect(trails.flatMap(\.events).map(\.kind) == [.tool])
        #expect(trails.allSatisfy { !model.activityDisclosures.isExpanded($0) })
        model.activityDisclosures.setExpanded(false, for: reasoning)
        client.receive(.init(type: "reasoning.delta", sessionID: "runtime", payload: ["text": .string(" continues")], sequence: 5))
        let updated = try #require(model.activityLedger.allEvents.first { $0.kind == .reasoning })
        #expect(updated.id == firstID)
        #expect(updated.detail == "Visible reasoning token")
        #expect(!model.activityDisclosures.isExpanded(updated))
        let nextPhase = try #require(model.activityLedger.allEvents.last { $0.kind == .reasoning })
        #expect(nextPhase.id != firstID)
        #expect(nextPhase.detail == " continues")
        #expect(nextPhase.lifecycle == .running)
        #expect(model.activityDisclosures.isExpanded(nextPhase))
    }

    /// Claude's thinking arrives blank, so with tool calls hidden the agent's
    /// notes are the only thinking on screen. They turn quiet the moment a
    /// hidden tool starts, and fold with the finished turn.
    @Test func notesBeforeHiddenToolsReadAsThinkingAndFold() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [],
                              initialActivityVisibility: .init(showReasoning: true, showToolCalls: false))
        client.model = model
        var sequence = 0
        func receive(_ type: String, _ payload: [String: BighelpJSONValue] = [:]) {
            sequence += 1
            client.receive(.init(type: type, sessionID: "runtime", payload: payload, sequence: sequence))
        }
        func rows() -> [ChatTurnDisplayRow] {
            ChatCompletedTurnProjection.rows(
                from: ChatInterimReplies.marking(model.transcriptEntries, isSending: model.isSending,
                                                 isBotMode: false, activityEvents: model.activityLedger.allEvents),
                isSending: model.isSending, enabled: true, activityEvents: model.activityLedger.allEvents,
                interimReplies: .following(model.activityVisibility))
        }
        func interimTexts() -> [String] {
            rows().compactMap { row in
                guard case .entry(.message(let item)) = row, item.metadata.isInterimReply,
                      case .message(let text) = item.content else { return nil }
                return text
            }
        }
        receive("message.start")
        receive("message.interim", ["text": .string("Checking the lights.")])
        receive("tool.start", ["tool_id": .string("t1"), "name": .string("terminal")])
        #expect(interimTexts() == ["Checking the lights."])
        receive("tool.complete", ["tool_id": .string("t1"), "name": .string("terminal")])
        receive("message.interim", ["text": .string("That failed, trying Google Home.")])
        receive("tool.start", ["tool_id": .string("t2"), "name": .string("list_homes")])
        receive("tool.complete", ["tool_id": .string("t2"), "name": .string("list_homes")])
        receive("message.delta", ["text": .string("The lights are off.")])
        receive("message.complete", ["text": .string("The lights are off.")])
        receive("session.info", ["running": .boolean(false)])
        #expect(!model.isSending)
        let finished = rows()
        #expect(finished.count == 2)
        guard case .completed(let fold) = try #require(finished.first) else {
            Issue.record("Expected the notes to fold")
            return
        }
        #expect(fold.expandedEntries.count == 2)
        guard case .entry(.message(let answer)) = try #require(finished.last) else {
            Issue.record("Expected the answer after the fold")
            return
        }
        #expect(answer.content == .message("The lights are off."))
        #expect(!answer.metadata.isInterimReply)
    }

    @Test(arguments: [false, true])
    func nativeFinalOnlyReasoningIsAdoptedBeforeHistoryWithoutEndingTheTurn(hasInterim: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: DirectTestRPC(), hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "stored", title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root)
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [],
                              initialActivityVisibility: .init(showReasoning: true, showToolCalls: true))
        client.model = model
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        if hasInterim {
            client.receive(.init(type: "message.interim", sessionID: "runtime", payload: ["text": .string("Progress")], sequence: 2))
        }
        client.receive(.init(type: "message.complete", sessionID: "runtime", payload: [
            "text": .string("Answer"), "reasoning": .string("Provider-recorded reasoning")
        ], sequence: 3))
        #expect(model.activityLedger.allEvents.filter { $0.kind == .reasoning }.map(\.detail) == ["Provider-recorded reasoning"])
        #expect(model.isSending)
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(false)], sequence: 4))
        #expect(!model.isSending)
        #expect(model.activityLedger.allEvents.filter { $0.kind == .reasoning }.map(\.detail) == ["Provider-recorded reasoning"])
    }

    @Test func projectionKeepsDeltaOrderAndDoesNotFinishOnSegmentFinal() {
        var projection = DirectHermesProjection(conversationID: "a", profile: "default", storedID: "saved", epoch: "epoch")
        _ = projection.accept(DirectHermesEvent(type: "message.start", sessionID: "a", payload: [:], sequence: 1))
        _ = projection.accept(DirectHermesEvent(type: "message.delta", sessionID: "a", payload: ["text": .string("First ")], sequence: 2))
        let firstID = projection.items.first?.id
        _ = projection.accept(DirectHermesEvent(type: "message.delta", sessionID: "a", payload: ["text": .string("answer")], sequence: 3))
        let final = projection.accept(DirectHermesEvent(type: "message.complete", sessionID: "a", payload: ["text": .string("First answer")], sequence: 4))
        #expect(projection.items.count == 1)
        #expect(projection.items.first?.id == firstID)
        #expect(projection.items.first?.content == .message("First answer"))
        #expect(projection.running)
        #expect(!final.terminal)
        let terminal = projection.accept(DirectHermesEvent(type: "session.info", sessionID: "a", payload: ["running": .boolean(false)], sequence: 5))
        #expect(terminal.terminal)
        #expect(!projection.running)
    }

    @Test func liveCompletionKeepsAuthoritativeFinalTimestampForFoldFallback() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var projection = DirectHermesProjection(
            conversationID: "chat", profile: "default", storedID: "saved", epoch: "epoch"
        )
        projection.retainVisible(
            items: [
                TimelineItem(
                    id: "chat-human", role: .human,
                    sender: .user(snapshot: .init(name: "You")), content: .message("Work"),
                    metadata: .init(delivery: "Sent", timestamp: start, sourceOrder: 1)
                ),
                TimelineItem(
                    id: "live-reply", role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Hermes")), content: .message("Done"),
                    metadata: .init(delivery: "Received", sourceOrder: 3)
                ),
            ],
            activities: [ChatActivityEvent(
                eventID: "turn:reasoning", sessionID: "chat", turnID: "turn",
                kind: .reasoning, lifecycle: .succeeded, title: "Reasoning", summary: nil, detail: nil,
                occurredAt: 1_010_000, sourceOrder: 2
            )]
        )

        // The final history row is the host's persisted completion timestamp.
        // A live event has no end timestamp of its own, so this is the only
        // source that may enable the legacy timestamp-difference fallback.
        projection.reconcileHistory([
            .object([
                "row_id": .integer(1), "session_id": .string("saved"), "role": .string("user"),
                "text": .string("Work"), "timestamp": .number(start.timeIntervalSince1970)
            ]),
            .object([
                "row_id": .integer(2), "session_id": .string("saved"), "role": .string("assistant"),
                "text": .string("Done"), "timestamp": .number(1_020),
                "reasoning_content": .string("Reasoning")
            ]),
        ])

        let final = try #require(projection.items.first { $0.role == .assistant })
        #expect(final.metadata.timestamp == Date(timeIntervalSince1970: 1_020))
        #expect(final.id == "live-reply")
        #expect(final.metadata.sourceOrder == 3)
        let human = try #require(projection.items.first { $0.role == .human })
        #expect(human.metadata.timestamp == start)
        #expect(human.id == "chat-human")
        #expect(human.metadata.sourceOrder == 1)
        // Persisted reasoning stays recorded rather than acquiring an invented
        // terminal lifecycle. Fold policy is independently covered by the
        // authoritative turn-duration projection tests.

    }

    @Test func nonReplayTerminalUsesObservedMonotonicTurnDuration() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var clock: UInt64 = 10_000_000_000
        let human = TimelineItem(
            id: "chat-human", role: .human,
            sender: .user(snapshot: .init(name: "You")), content: .message("Work"),
            metadata: .init(delivery: "Sent", timestamp: Date(timeIntervalSince1970: 1_000), sourceOrder: 1)
        )
        let rpc = DirectTestRPC()
        rpc.handler = { _, _ in .object(["status": .string("streaming")]) }
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default", runtimeID: "runtime", storedID: "stored",
            title: "Native", epoch: "epoch", drafts: DirectHermesDraftStore(root: root),
            monotonicNow: { clock }
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [human])
        client.model = model

        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        clock += 20_125_000_000
        client.receive(.init(type: "message.delta", sessionID: "runtime",
            payload: ["text": .string("Done")], sequence: 2))
        client.receive(.init(type: "message.complete", sessionID: "runtime",
            payload: ["text": .string("Done")], sequence: 3))
        clock += 2_000_000
        client.receive(.init(type: "session.info", sessionID: "runtime",
            payload: ["running": .boolean(false)], sequence: 4))

        let final = try #require(model.items.first { $0.role == .assistant })
        #expect(final.metadata.turnDurationMilliseconds == 20_127)
        #expect(rpc.requests.allSatisfy { $0.method != "session.history" })
    }
}

@MainActor
struct NativeMidSessionTests {
    @Test(arguments: [4001, 4007, 4090])
    func runtimeRefusalRevokesWarmAdmissionWithoutMakingDeliveryUncertain(code: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            throw DirectHermesError.rpcRejected(code: code)
        }
        model.draft = "Original refused intent"
        await model.send()
        #expect(client.isReadyForSubmission == (code == 4090), "Only definite missing-runtime evidence revokes warm admission")
        #expect(client.hasAuthoritativeEventCoverage == (code == 4090))
        #expect(!client.needsRecovery, "Known refusal is distinct from uncertain delivery")
        #expect(client.journal.unresolved.first?.rejectionCode == code)
        #expect(model.draft == "Original refused intent")
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
    }

    @Test(arguments: [4001, 4007, 4090], [false, true])
    func queuedRefusalRetainsOriginalWithoutOverwritingNewerComposer(code: Int, withFile: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        #expect(model.isSending)
        let attachment = try ChatAttachment(id: "newer_queued_fixture", fileName: "newer.txt",
            mimeType: "text/plain", data: Data("Newer attachment".utf8))
        let original = try ChatAttachment(id: "original_queued_fixture", fileName: "a.txt",
            mimeType: "text/plain", data: Data("Original attachment".utf8))
        rpc.handler = { method, params in
            if method == "file.attach" {
                return .object(["attached": .boolean(true), "uploaded": .boolean(true),
                    "name": .string("a.txt"), "path": .string("/staged/a.txt"),
                    "ref_path": .string("/staged/a.txt"), "ref_text": .string("@file:/staged/a.txt")])
            }
            #expect(method == "prompt.submit")
            #expect(params["queued"] == .boolean(true))
            model.draft = "Newer draft B"
            try model.addDraftAttachment(attachment)
            throw DirectHermesError.rpcRejected(code: code)
        }
        model.draft = "Queued original A"
        if withFile { try model.addDraftAttachment(original) }
        await model.sendMidSession(using: .queued)
        #expect(model.draft == "Newer draft B")
        #expect(model.draftAttachments == [attachment])
        #expect(model.orderedDraftAttachments == [.attachment(attachment)])
        #expect(model.items.allSatisfy { $0.role != .human })
        #expect(model.retainedUnsentSubmissions.map(\.text) == ["Queued original A"])
        #expect(client.journal.unresolved.first?.rejectionCode == code)
        #expect(model.failureMessage?.contains("unconfirmed") == false)
        #expect(!model.canRetry)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
        let restored = try makeClient(rpc, root: root)
        defer { restored.suspend() }
        #expect(restored.journal.unresolved.map(\.text) == ["Queued original A"])
        #expect(restored.journal.unresolved.first?.attachments == (withFile ? [original] : nil))
        #expect(restored.journal.unresolved.first?.method == "prompt.submit")
    }

    @Test(arguments: [4090, 4007, 4001])
    func definiteAdmissionRefusalKeepsEditableDraftWithoutUncertainDelivery(code: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            throw DirectHermesError.rpcRejected(code: code)
        }
        model.draft = "Keep the refused message"

        await model.send()

        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
        #expect(client.journal.unresolved.map(\.text) == ["Keep the refused message"])
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(client.journal)) as? [String: Any]
        let retained = (stored?["unresolved"] as? [[String: Any]])?.first
        #expect(retained?["rejectionCode"] as? Int == code, "Known refusal must be durably distinct from uncertain delivery")
        #expect(!client.needsRecovery)
        #expect(model.draft == "Keep the refused message")
        #expect(model.failureMessage != nil)
        #expect(model.failureMessage?.contains("unconfirmed") == false)
        #expect(!model.canRetry, "A lease or stale-session refusal must not invite automatic replay")
        #expect(model.items.allSatisfy { $0.role != .human }, "A refused message is an editable draft, not accepted history")
    }

    @Test(arguments: [4090, 4007, 4001], ["Review this", ""])
    func refusedAttachmentRestoresOriginalDraftNotUploadedWireText(code: Int, message: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let attachment = try ChatAttachment(id: "refused_attachment_fixture", fileName: "a.txt",
            mimeType: "text/plain", data: Data("Original file".utf8))
        rpc.handler = { method, _ in
            if method == "file.attach" {
                return .object(["attached": .boolean(true), "uploaded": .boolean(true),
                    "name": .string("a.txt"), "path": .string("/staged/a.txt"),
                    "ref_path": .string("/staged/a.txt"), "ref_text": .string("@file:/staged/a.txt")])
            }
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            throw DirectHermesError.rpcRejected(code: code)
        }
        model.draft = message
        try model.addDraftAttachment(attachment)

        await model.send()

        #expect(model.draft == message)
        #expect(model.draftAttachments == [attachment])
        #expect(model.orderedDraftAttachments == [.attachment(attachment)])
        #expect(model.items.allSatisfy { $0.role != .human })
        #expect(!model.canRetry)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
        let reopened = try makeClient(rpc, root: root)
        defer { reopened.suspend() }
        let record = try #require(reopened.journal.unresolved.first)
        #expect(record.text == message)
        let raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(raw["rejectionCode"] as? Int == code)
        let encodedAttachments = try #require(raw["attachments"] as? [[String: Any]])
        let recovered = try JSONDecoder().decode([ChatAttachment].self,
            from: JSONSerialization.data(withJSONObject: encodedAttachments))
        #expect(recovered == [attachment])
    }

    @Test(arguments: [4090, 4007, 4001])
    func refusalPreservesBothOriginalIntentAndNewerComposerDraft(code: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            model.draft = "Newer unsent draft"
            throw DirectHermesError.rpcRejected(code: code)
        }
        model.draft = "Original refused intent"

        await model.send()

        #expect(model.draft == "Newer unsent draft")
        #expect(model.items.allSatisfy { $0.role != .human })
        model.reconcileHydratedSession(SessionRecord(id: client.conversationID, kind: .direct,
            agentIDs: ["default"], title: "Chat", remoteStoredID: "saved"))
        let reopened = try makeClient(rpc, root: root)
        defer { reopened.suspend() }
        #expect(reopened.journal.unresolved.map(\.text) == ["Original refused intent"])
        #expect(model.draft == "Newer unsent draft")
        #expect(!model.canRetry)
        #expect(model.retainedUnsentSubmissions.map(\.text) == ["Original refused intent"])
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
    }

    @Test func refusalPersistenceFailureRetainsThePriorJournalWithoutRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            client.drafts.invalidate()
            throw DirectHermesError.rpcRejected(code: 4007)
        }
        model.draft = "Keep the durable original"
        await model.send()
        #expect(client.needsRecovery)
        #expect(!model.canRetry)
        let reopened = try makeClient(rpc, root: root)
        defer { reopened.suspend() }
        #expect(reopened.journal.unresolved.map(\.text) == ["Keep the durable original"])
        #expect(reopened.journal.unresolved.first?.rejectionCode == nil)
        #expect(rpc.requests.filter { $0.method == "prompt.submit" }.count == 1)
    }

    @Test func oldJournalEntriesRemainUncertainAndAttachmentBytesAreOnlyStoredOnRefusal() throws {
        let id = UUID()
        let legacy = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "text": "Legacy intent", "method": "prompt.submit", "createdAt": 0
        ])
        let decoded = try JSONDecoder().decode(DirectHermesDraftStore.Submission.self, from: legacy)
        #expect(decoded.id == id)
        #expect(decoded.rejectionCode == nil)
        #expect(decoded.attachments == nil)
        let attachment = try ChatAttachment(id: "journal_file_fixture", fileName: "a.txt",
            mimeType: "text/plain", data: Data("fixture".utf8))
        var entry = decoded
        entry.attachments = [attachment]
        let before = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(before["attachments"] == nil, "Successful sends must not rewrite attachment bytes after every staging receipt")
        entry.rejectionCode = 4001
        let after = try JSONDecoder().decode(DirectHermesDraftStore.Submission.self, from: JSONEncoder().encode(entry))
        #expect(after.attachments == [attachment])
        #expect(after.rejectionCode == 4001)
    }

    @Test func liveNativeTurnKeepsSendEnabledWhileOriginalSubmissionWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        var promptStarted = false
        rpc.handler = { method, _ in
            guard method == "prompt.submit" else { throw DirectHermesError.invalidResponse }
            client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
            client.receive(.init(type: "message.delta", sessionID: "runtime",
                                 payload: ["text": .string("Working")], sequence: 2))
            promptStarted = true
            return .object(["status": .string("streaming")])
        }

        model.draft = "Start"
        let owner = Task { await model.send() }
        for _ in 0..<100 where !promptStarted { await Task.yield() }
        model.draft = "Steer this now"

        #expect(model.isSending)
        #expect(client.hasAuthoritativeEventCoverage)
        #expect(!client.isReadyForSubmission)
        #expect(model.canSend, "A live native turn must keep the Send action available for steering")

        client.receive(.init(type: "message.complete", sessionID: "runtime",
                             payload: ["text": .string("Done")], sequence: 3))
        client.receive(.init(type: "session.info", sessionID: "runtime",
                             payload: ["running": .boolean(false)], sequence: 4))
        await owner.value
    }

    @Test func interruptAndSendPersistsThenStopsThenQueuesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        rpc.handler = { method, _ in
            #expect(client.journal.unresolved.count == 1)
            #expect(client.journal.unresolved.first?.method == method)
            return .object(["status": .string(method == "session.interrupt" ? "interrupted" : "queued")])
        }
        _ = try await client.sendMidSession(message: "Replacement plan", attachments: [],
            conversationID: client.conversationID, behavior: .interruptAndSend, onDraft: { _ in })
        #expect(rpc.requests.map(\.method) == ["session.interrupt", "prompt.submit"])
        #expect(rpc.requests.last?.params["queued"]?.boolean == true)
        #expect(rpc.requests.last?.params["text"]?.string == "Replacement plan")
        #expect(client.journal.unresolved.isEmpty)
        #expect(!client.needsRecovery)
    }

    @Test(arguments: ["session.interrupt", "prompt.submit"])
    func unknownInterruptOrSendNeverRetriesOrDropsItsOriginalIntent(failedMethod: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        rpc.handler = { method, _ in
            if method == failedMethod { throw DirectHermesError.timedOut(outcomeUnknown: true) }
            return .object(["status": .string("interrupted")])
        }
        await #expect(throws: DirectHermesError.timedOut(outcomeUnknown: true)) {
            _ = try await client.sendMidSession(message: "Original intent", attachments: [],
                conversationID: client.conversationID, behavior: .interruptAndSend, onDraft: { _ in })
        }
        #expect(rpc.requests.map(\.method) == (failedMethod == "session.interrupt" ? ["session.interrupt"] : ["session.interrupt", "prompt.submit"]))
        #expect(client.journal.unresolved.map(\.text) == ["Original intent"])
        #expect(client.journal.unresolved.first?.method == failedMethod)
        #expect(client.needsRecovery)
    }

    @Test func explicitSteerRejectionIsNotAnUncertainSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.result = .object(["status": .string("rejected"), "text": .string("Try this instead")])
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        client.receive(.init(type: "session.info", sessionID: "runtime", payload: ["running": .boolean(true)], sequence: 1))
        await #expect(throws: (any Error).self) {
            _ = try await client.sendMidSession(message: "Try this instead", attachments: [],
                conversationID: client.conversationID, behavior: .steer, onDraft: { _ in })
        }
        #expect(rpc.requests.map(\.method) == ["session.steer"])
        #expect(client.journal.unresolved.isEmpty)
        #expect(!client.needsRecovery)
    }

    @Test func sameSocketDeliversMultipleDeltasAfterRecoveryWithoutResend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since": return .object(["epoch": .string("epoch"), "latest_seq": .integer(2),
                "truncated": .boolean(false), "events": .array([])])
            case "session.activate": return .object(["session_id": .string("runtime"), "session_key": .string("saved"),
                "stored_session_id": .string("saved"), "running": .boolean(true), "messages": .array([])])
            case "subagent.list": return .object(["subagents": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        rpc.onEvent = { client.receive($0) }
        rpc.onEvent?(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        rpc.onEvent?(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("A")], sequence: 2))
        let priorIDs = model.items.map(\.id)
        model.draft = "Keep the unsent draft"
        try await client.prepareTransportForAuthoritativeRecovery()
        try await client.recover(epoch: client.projection.epoch)
        #expect(client.projection.running)
        #expect(client.isReadyForSubmission)
        rpc.onEvent?(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("B")], sequence: 3))
        rpc.onEvent?(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("C")], sequence: 4))
        rpc.onEvent?(.init(type: "message.delta", sessionID: "runtime", payload: ["text": .string("C")], sequence: 4))
        #expect(model.items.filter { $0.content == .message("ABC") }.count == 1)
        #expect(model.items.map(\.id) == priorIDs)
        #expect(model.draft == "Keep the unsent draft")
        #expect(client.projection.lastSequence == 4)
        #expect(rpc.disconnectCount == 0)
        #expect(!rpc.requests.contains { ["prompt.submit", "session.steer", "session.interrupt", "session.history"].contains($0.method) })
    }

    @Test func validatedNewEpochActivationReplacesRetainedNativeTodoSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            switch method {
            case "session.events.since":
                return .object(["epoch": .string("new-epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([])])
            case "session.activate":
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "session_key": .string("saved"), "running": .boolean(false), "messages": .array([]),
                    "todo_state": .object(["revision": .integer(1), "updated_at": .integer(200),
                        "todos": .array([.object(["id": .string("current"), "content": .string("Current state"),
                            "status": .string("in_progress")])])])])
            case "subagent.list": return .object(["subagents": .array([])])
            default: throw DirectHermesError.invalidResponse
            }
        }
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(.init(type: "todo.updated", sessionID: "runtime", payload: [
            "revision": .integer(9), "todos": .array([.object(["id": .string("retained"),
                "content": .string("Retained old epoch"), "status": .string("completed")])])], sequence: 1))
        #expect(model.taskDrawer?.items.map(\.id) == ["retained"])

        try await client.recover(epoch: "epoch")

        #expect(client.projection.epoch == "new-epoch")
        #expect(client.projection.todoSnapshot?.nativeObservation?.epoch == "new-epoch")
        #expect(model.taskDrawer?.items.map(\.id) == ["current"])
    }

    @Test func failedRecoveryTailCannotPublishActivationTodoSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        var replayRequests = 0
        rpc.handler = { method, _ in
            if method == "session.events.since" {
                replayRequests += 1
                if replayRequests > 1 { throw DirectHermesError.notConnected }
                return .object(["epoch": .string("epoch"), "latest_seq": .integer(0),
                    "truncated": .boolean(false), "events": .array([])])
            }
            if method == "session.activate" {
                return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                    "session_key": .string("saved"), "running": .boolean(true), "messages": .array([]),
                    "todo_state": .object(["revision": .integer(2), "updated_at": .integer(100),
                        "todos": .array([.object(["id": .string("one"), "content": .string("Do not publish"),
                            "status": .string("in_progress")])])])])
            }
            throw DirectHermesError.invalidResponse
        }
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        await #expect(throws: (any Error).self) { try await client.recover(epoch: "epoch") }
        #expect(replayRequests == 2)
        #expect(client.projection.todoSnapshot == nil)
        #expect(!client.isReadyForSubmission)
        #expect(!client.projection.running)
    }

    @Test func unusedTodoReadDoesNotSuppressLiveTasksAndCanonicalUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        func emit(_ type: String, _ payload: String, sequence: Int) throws {
            let object = try JSONDecoder().decode(BighelpJSONValue.self, from: Data(payload.utf8)).object!
            client.receive(.init(type: type, sessionID: "runtime", payload: object, sequence: sequence))
        }
        // Exact current tool_complete_callback shape: an unused read has no
        // copied top-level state and does not cause a todo.updated event.
        try emit("tool.complete", #"{"tool_id":"read","name":"todo_list","result":{"todos":[],"revision":0,"summary":{"total":0,"pending":0,"in_progress":0,"completed":0,"cancelled":0}}}"#, sequence: 1)
        #expect(client.projection.todoSnapshot == nil)
        #expect(model.sessionTodos == nil)
        try emit("tool.start", #"{"tool_id":"write","name":"todo_list","args":{"todos":[{"id":"inspect","content":"Inspect","status":"in_progress"}],"merge":false}}"#, sequence: 2)
        #expect(model.taskDrawer?.items.map(\.id) == ["inspect"])
        #expect(model.taskDrawer?.items.first?.status == .inProgress)
        try emit("tool.complete", #"{"tool_id":"write","name":"todo_list","args":{"todos":[{"id":"inspect","content":"Inspect","status":"in_progress"}],"merge":false},"result":{"todos":[{"id":"inspect","content":"Inspect","status":"in_progress"}],"revision":1,"summary":{"total":1,"pending":0,"in_progress":1,"completed":0,"cancelled":0}},"todos":[{"id":"inspect","content":"Inspect","status":"in_progress"}],"revision":1}"#, sequence: 3)
        #expect(model.sessionTodos?.revision == 1)
        let accepted = model.taskDrawer
        try emit("todo.updated", #"{"todos":[{"id":"inspect","content":"Inspect","status":"in_progress"}],"revision":1}"#, sequence: 4)
        #expect(model.taskDrawer == accepted)
        try emit("todo.updated", #"{"todos":[{"id":"inspect","content":"Inspect","status":"completed"},{"id":"ship","content":"Ship","status":"in_progress"}],"revision":2}"#, sequence: 5)
        #expect(model.sessionTodos?.revision == 2)
        #expect(model.taskDrawer?.items.map(\.status) == [.completed, .inProgress])
        try emit("todo.updated", #"{"todos":[],"revision":3}"#, sequence: 6)
        #expect(model.sessionTodos?.revision == 3)
        #expect(model.taskDrawer == nil)
        try emit("todo.updated", #"{"todos":[{"id":"stale","content":"Old","status":"pending"}],"revision":2}"#, sequence: 7)
        #expect(model.taskDrawer == nil)
    }

    @Test func liveTodoRevisionRestartReplacesPriorTurnWithoutRevivingStaleHistory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        let client = try makeClient(rpc, root: root)
        defer { client.suspend() }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let old = SessionTodoSnapshot(sessionID: client.conversationID, revision: 4,
            todos: [.init(id: "old", content: "Previous turn", status: .completed)], updatedAt: 4)
        model.reconcileTodos(old)
        client.receive(.init(type: "todo.updated", sessionID: "runtime", payload: [
            "revision": .integer(4), "todos": .array([.object(["id": .string("old"),
                "content": .string("Previous turn"), "status": .string("completed")])])], sequence: 10))
        client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 11))
        #expect(model.taskDrawer == nil, "A new turn must not display the previous turn's completed tasks")
        // Hermes constructs a new agent per message. Current native hydration
        // recognizes legacy `todo` history, but not deferred `tool_call`, so a
        // real later todo_list completion can restart its store revision at 1.
        client.receive(.init(type: "tool.complete", sessionID: "runtime", payload: [
            "tool_id": .string("new-todo-write"), "name": .string("todo_list"),
            "revision": .integer(1), "todos": .array([.object(["id": .string("new"),
                "content": .string("Current turn"), "status": .string("in_progress")])])], sequence: 12))
        #expect(model.taskDrawer?.items.map(\.id) == ["new"])
        model.reconcileTodos(old)
        #expect(model.taskDrawer?.items.map(\.id) == ["new"], "Delayed older catalog hydration cannot overwrite witnessed live tasks")
        client.receive(.init(type: "todo.updated", sessionID: "runtime", payload: [
            "revision": .integer(4), "todos": .array([.object(["id": .string("old"),
                "content": .string("Previous turn"), "status": .string("completed")])])], sequence: 10))
        #expect(model.taskDrawer?.items.map(\.id) == ["new"])
    }

    /// Before each new turn the host learns who is sending, so the agent knows
    /// who it's talking with. The message itself goes exactly as typed.
    @Test func sendSaysWhoIsSendingFirstAndSendsTheTextAsTyped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = SpeakerLog()
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in
            log.events.append(method)
            return .object(["status": .string(method == "prompt.submit" ? "streaming" : "queued")])
        }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        client.speakerNote = RecordingSpeakerNote(log: log)
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.draft = "What's on my calendar?"
        let turn = Task { await model.send() }
        for _ in 0..<200 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.events.filter { ["speaker:default/stored", "prompt.submit"].contains($0) }
                == ["speaker:default/stored", "prompt.submit"])
        let submit = try #require(rpc.requests.last(where: { $0.method == "prompt.submit" }))
        #expect(submit.params["text"]?.string == "What's on my calendar?")
        turn.cancel()
    }

    /// A slow or unreachable host never holds a message: it goes without a name.
    @Test func aSlowSpeakerNoteNeverHoldsTheMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = DirectTestRPC()
        rpc.handler = { method, _ in .object(["status": .string(method == "prompt.submit" ? "streaming" : "queued")]) }
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Native", epoch: "epoch", drafts: .init(root: root))
        defer { client.suspend() }
        client.speakerNote = RecordingSpeakerNote(log: SpeakerLog(), delay: .seconds(30))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        model.draft = "Hello"
        let started = ContinuousClock.now
        let turn = Task { await model.send() }
        for _ in 0..<500 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rpc.requests.contains(where: { $0.method == "prompt.submit" }))
        #expect(ContinuousClock.now - started < .seconds(4))
        turn.cancel()
    }

    /// The chat's model sheet read "Reasoning: unknown" while the agent worked:
    /// its own read waits for an idle chat, and the one made when the chat opened
    /// can fail before the chat is attached. Hermes reports the level in every
    /// `session.info`, including the one that starts the turn.
    @Test func reasoningLevelShowsDuringATurnFromSessionInfo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try makeClient(DirectTestRPC(), root: root)
        defer { client.suspend() }
        let messaging = UnattachedSessionControlMessaging()
        let controls = SessionRuntimeControlModel(sessionID: client.conversationID, agentID: "default",
                                                  messaging: messaging, allowsAgentDefaults: false)
        await controls.loadReasoningPickerIfNeeded()
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [],
                              runtimeControls: controls)
        client.model = model

        client.receive(.init(type: "session.info", sessionID: "runtime", payload: [
            "running": .boolean(true), "model": .string("hermes-test"), "provider": .string("nous"),
            "reasoning_effort": .string("high")
        ], sequence: 1))
        controls.setTurnActive(true)
        await controls.loadSummaryIfNeeded()

        #expect(controls.isTurnActive)
        #expect(messaging.openedCount == 1, "Nothing is read from the host while the agent is replying")
        #expect(ChatModelSummaryPresentation(controls: controls).reasoning == "Reasoning: High")
    }

    private func makeClient(_ rpc: DirectTestRPC, root: URL) throws -> DirectHermesConversationClient {
        try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default", runtimeID: "runtime",
            storedID: "saved", title: "Chat", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
    }
}

/// Answers like the host does before the chat's live session is attached.
@MainActor private final class UnattachedSessionControlMessaging: BighelpLinkSessionControlMessaging {
    private(set) var openedCount = 0

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        openedCount += 1
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}

@MainActor private final class CanonicalTailFailureState {
    var eventReads = 0
    var tailFails = true
}

@MainActor private final class DirectTestRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var result: BighelpJSONValue?
    var handler: (@MainActor (String, [String: BighelpJSONValue]) async throws -> BighelpJSONValue)?
    var requests: [(method: String, params: [String: BighelpJSONValue])] = []
    var disconnectCount = 0
    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        requests.append((method, params))
        // Mounted native models refresh optional goal state independently of
        // recovery/send. Keep that read visible without feeding it to a
        // mutation-specific fixture handler.
        if method == "session.control.read" {
            return .object(["control": .object([
                "goal": .null, "loop": .null, "heartbeat": .null,
                "revision": .string("fixture-empty"), "updated_at": .integer(0)
            ])])
        }
        if let handler { return try await handler(method, params) }
        if let result { return result }
        throw DirectHermesError.notConnected
    }
    func disconnect() async { disconnectCount += 1 }
}

@MainActor private final class SpeakerLog {
    var events: [String] = []
}

@MainActor private final class RecordingSpeakerNote: ChatSpeakerNoting {
    let log: SpeakerLog
    let delay: Duration?
    init(log: SpeakerLog, delay: Duration? = nil) {
        self.log = log
        self.delay = delay
    }
    func note(agentID: String, storedSessionID: String) async {
        if let delay { try? await Task.sleep(for: delay) }
        log.events.append("speaker:\(agentID)/\(storedSessionID)")
    }
}
